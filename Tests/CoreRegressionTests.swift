import Foundation
import ImageIO
import UniformTypeIdentifiers

// 試行制限の永続化境界を差し替え、ユーザーのKeychainは読み書きしません。
struct KeychainStore {
    static var values: [String: Data] = [:]
    static var failWrites = false
    func read(account: String, synchronizable: Bool) throws -> Data? { Self.values[account] }
    func delete(account: String) { Self.values.removeValue(forKey: account) }
    func save(_ data: Data, account: String, synchronizable: Bool) throws {
        if Self.failWrites { throw CocoaError(.fileWriteNoPermission) }
        Self.values[account] = data
    }
}

@main struct CoreRegressionTests {
    static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    static func main() async throws {
        let permissionError = NSError(domain: NSCocoaErrorDomain, code: 257, userInfo: [
            NSLocalizedDescriptionKey: "アクセスが拒否されました。",
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 1),
            NSFilePathErrorKey: "/private/test-vault"
        ])
        let report = CloudRestoreDiagnostics.message(for: permissionError)
        expect(report.contains("NSCocoaErrorDomain / 257") && report.contains("NSPOSIXErrorDomain / 1"), "Permission error preserves diagnostic codes")
        expect(!report.contains("/private/test-vault"), "Diagnostics do not append file paths")
        do {
            let _: Data = try CloudRestoreDiagnostics.atStage("metadata") { throw permissionError }
            preconditionFailure("Read failure swallowed")
        } catch {
            let staged = error as NSError
            expect(staged.domain == NSCocoaErrorDomain && staged.code == 257, "Stage preserves error code")
            let text = CloudRestoreDiagnostics.message(for: staged)
            expect(text.contains("metadata") && text.contains("NSPOSIXErrorDomain / 1"), "Stage and nested error remain visible")
        }
        var stagedReads = 0
        let stagedResult = try await ICloudAccountGuard.waitForDownloadedIndex(timeout: .seconds(1), interval: .milliseconds(1)) {
            try CloudRestoreDiagnostics.atStage("metadata") {
                stagedReads += 1
                if stagedReads < 3 { throw CocoaError(.fileReadNoSuchFile) }
                return Data([1])
            }
        }
        expect(stagedResult == Data([1]) && stagedReads == 3, "Stage annotation preserves missing-file retries")
        try testCloudDatabaseErrors()
        try await testCloudDeadline()
        try testDownloadedReadWithOldError()
        try await testDelayedRecoveryFile()
        try testVerifiedReconnection()
        try testAccountAndRecovery()
        try testSimilarFingerprints()
        try testCloudState()
        try testPINPolicy()
        try testAuthenticationThrottle()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoVault-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try testCompleteResetSafety(root: root)
        try testLocalRestartIsolation(root: root)
        try await testSeparateLocalRecovery(root: root)
        try await testDailyDataProtection(root: root.appendingPathComponent("daily-protection"))
        try testPrivateBackupSettings()
        try testDailyBackupSchedule()
        try testAutomaticBackupCompression()
        try await testAutomaticBackup(root: root.appendingPathComponent("auto-backup"))
        try await testRepository(root: root)
        print("PASS: cloud status, PIN persistence/backoff, legacy data, trash, backup, duplicates, storage and rollback")
    }

    static func testCloudDatabaseErrors() throws {
        let key = Data(repeating: 9, count: 32)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encrypted = try CryptoBox.seal(encoder.encode(VaultDatabase.empty), using: key)
        let restored = try VaultRepository.decodeCloudDatabase(encrypted, key: key)
        expect(restored.photos.isEmpty, "Valid cloud database decodes")
        do {
            _ = try VaultRepository.decodeCloudDatabase(encrypted, key: Data(repeating: 8, count: 32))
            preconditionFailure("Wrong cloud key accepted")
        } catch CloudRestoreReadError.cannotDecrypt { }
        let malformed = try CryptoBox.seal(Data("invalid database".utf8), using: key)
        do {
            _ = try VaultRepository.decodeCloudDatabase(malformed, key: key)
            preconditionFailure("Malformed cloud database accepted")
        } catch CloudRestoreReadError.cannotDecode { }
    }

    // 同期I/Oがキャンセルを無視して戻ってくるケースを再現します。
    static func delayedCloudData() -> Data {
        Thread.sleep(forTimeInterval: 0.4)
        return Data("late".utf8)
    }

    static func testCloudDeadline() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await CloudDownloadDeadline.run(seconds: 0.02) { delayedCloudData() }
            preconditionFailure("Blocking cloud read must time out")
        } catch is CloudDownloadTimeout { }
        expect(start.duration(to: clock.now) < .milliseconds(350), "Timeout does not wait for blocked worker")
        let success = try await CloudDownloadDeadline.run(seconds: 1) { Data("ready".utf8) }
        expect(success == Data("ready".utf8), "Retry can complete after timeout")
        let snapshot = try await CloudDownloadDeadline.run(seconds: 1) {
            DownloadedVaultIndex(data: Data("downloaded".utf8), isCurrent: false)
        }
        expect(!snapshot.isCurrent && !snapshot.data.isEmpty, "Downloaded snapshot preserves read-only state")
        let cancelled = Task { try await CloudDownloadDeadline.run(seconds: 1) { delayedCloudData() } }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancelled read returned data") }
        catch is CancellationError { }
        // 遅い結果が到着しても、継続の二重再開や正常な次回結果の上書きがないことを確認します。
        try await Task.sleep(for: .milliseconds(450))
    }

    static func testDownloadedReadWithOldError() throws {
        let staleError = CocoaError(.fileReadNoPermission)
        try CloudReadAvailability.requireReadable(status: .downloaded, requiresCurrent: false, downloadError: staleError)
        try CloudReadAvailability.requireReadable(status: .current, requiresCurrent: true, downloadError: staleError)
        do {
            try CloudReadAvailability.requireReadable(status: .downloaded, requiresCurrent: true, downloadError: staleError)
            preconditionFailure("Old content accepted for editing")
        } catch CocoaError.fileReadNoPermission { }
        var requested = false
        let data = try CloudReadAvailability.readBeforeRequestingDownload(read: { Data("available".utf8) }, requestDownload: {
            requested = true
            throw staleError
        })
        expect(!requested && data == Data("available".utf8), "Readable data never requires a download request")
        do {
            _ = try CloudReadAvailability.readBeforeRequestingDownload(read: { throw CocoaError(.fileReadNoSuchFile) }, requestDownload: {
                requested = true
                throw staleError
            })
            preconditionFailure("Missing file should remain unavailable")
        } catch CocoaError.fileReadNoSuchFile { }
        expect(requested, "Missing content triggers download")
        let denied = CloudReadAvailability.preferredError(readError: staleError, downloadError: CocoaError(.fileReadNoSuchFile)) as NSError
        expect(denied.code == NSFileReadNoPermissionError, "Actual read permission failures remain visible")
        let absent = CloudReadAvailability.preferredError(readError: NSError(domain: NSPOSIXErrorDomain, code: 2), downloadError: staleError) as NSError
        expect(absent.domain == NSPOSIXErrorDomain && absent.code == 2, "Missing POSIX path is not mislabeled as permission failure")
        let pending = CloudReadAvailability.preferredError(readError: PhotoVaultError.iCloudDownloadPending, downloadError: staleError) as NSError
        expect(pending.code == NSFileReadNoPermissionError, "Download failures remain visible when file absence is not confirmed")
        let combined = CloudRestoreDiagnostics.message(for: pending)
        expect(combined.contains("【ダウンロード要求前の読み取り】") && combined.contains(PhotoVaultError.iCloudDownloadPending.localizedDescription),
               "Pending read remains visible alongside download denial")
        expect(combined.contains("【ダウンロード開始要求】") && combined.contains("NSCocoaErrorDomain / 257"),
               "Download denial is retained separately")
        let absentReport = CloudRestoreDiagnostics.message(for: absent)
        expect(absentReport.contains("NSPOSIXErrorDomain / 2") && absentReport.contains("NSCocoaErrorDomain / 257"),
               "Missing file and download denial both survive diagnostic selection")
    }

    static func testDelayedRecoveryFile() async throws {
        var reads = 0
        let data = try await ICloudAccountGuard.waitForDownloadedIndex(timeout: .seconds(1), interval: .milliseconds(1)) {
            reads += 1
            if reads < 3 { throw CocoaError(.fileReadNoSuchFile) }
            return Data("arrived".utf8)
        }
        expect(reads == 3 && data == Data("arrived".utf8), "New-device missing file is retried until it arrives")
        reads = 0
        do {
            _ = try await ICloudAccountGuard.waitForDownloadedIndex {
                reads += 1
                throw CocoaError(.fileReadNoPermission)
            }
            preconditionFailure("Permission error swallowed")
        } catch CocoaError.fileReadNoPermission { }
        expect(reads == 1, "Permission errors are not treated as download progress")
        do {
            _ = try await ICloudAccountGuard.waitForDownloadedIndex(timeout: .milliseconds(2), interval: .milliseconds(1)) {
                throw CocoaError(.fileReadNoSuchFile)
            }
            preconditionFailure("Missing file accepted")
        } catch CocoaError.fileReadNoSuchFile { }
    }

    static func testVerifiedReconnection() throws {
        KeychainStore.values = [:]
        let auth = AuthenticationService()
        let vaults = try auth.createProfiles(mainPassword: "1234", subPassword: "5678")
        let previous = try NSKeyedArchiver.archivedData(withRootObject: "old-token" as NSString, requiringSecureCoding: false)
        let expected = try NSKeyedArchiver.archivedData(withRootObject: "new-token" as NSString, requiringSecureCoding: false)
        let ownerKey = "icloud-vault-owner-token-v1"
        KeychainStore.values[ownerKey] = previous
        do { _ = try auth.unlock(password: "9999", forAccountRecovery: true); preconditionFailure("Recovery bypassed PIN") }
        catch PhotoVaultError.invalidPassword { }
        let unlocked = try auth.unlock(password: "1234", forAccountRecovery: true)
        expect(unlocked.masterKey == vaults[0].masterKey, "Recovery verifies existing local credential")
        expect(KeychainStore.values[ownerKey] == previous, "PIN alone must not rebind account")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encrypted = try CryptoBox.seal(encoder.encode(VaultDatabase.empty), using: unlocked.masterKey)
        let guardService = ICloudAccountGuard()
        do {
            try guardService.confirmReconnection(encrypted, key: Data(repeating: 0, count: 32), expectedIdentity: expected,
                                                 currentIdentity: { "new-token" as NSString })
            preconditionFailure("Wrong cloud key rebound account")
        } catch CloudRestoreReadError.cannotDecrypt { }
        expect(KeychainStore.values[ownerKey] == previous, "Failed cloud proof preserves binding")
        do {
            try guardService.confirmReconnection(encrypted, key: unlocked.masterKey, expectedIdentity: expected,
                                                 currentIdentity: { "another-token" as NSString })
            preconditionFailure("Changed identity accepted")
        } catch CloudAccountError.changed { }
        try guardService.confirmReconnection(encrypted, key: unlocked.masterKey, expectedIdentity: expected,
                                             currentIdentity: { "new-token" as NSString })
        expect(KeychainStore.values[ownerKey] == expected, "Matching cloud data permits reconnection")
        KeychainStore.values = [:]
    }

    static func testAccountAndRecovery() throws {
        let saved = try NSKeyedArchiver.archivedData(withRootObject: "account-A" as NSString, requiringSecureCoding: false)
        try ICloudAccountGuard.validate(saved: saved, current: "account-A" as NSString)
        do {
            try ICloudAccountGuard.validate(saved: saved, current: "account-B" as NSString)
            preconditionFailure("Different account accepted")
        } catch CloudAccountError.changed { }
        do {
            try ICloudAccountGuard.validate(saved: saved, current: nil)
            preconditionFailure("Signed-out account accepted")
        } catch CloudAccountError.signedOut { }
        KeychainStore.values = [:]
        let auth = AuthenticationService()
        _ = try auth.createProfiles(mainPassword: "1234", subPassword: "5678")
        expect(KeychainStore.values["vault-profiles-v1"] == nil, "New setup must not overwrite cloud credentials")
        let candidate = KeychainStore.values.removeValue(forKey: "vault-profiles-local-v1")!
        KeychainStore.values["vault-profiles-v1"] = candidate
        expect(!auth.hasProfiles, "Startup checks only local credentials")
        expect(try auth.findRecoveryProfiles() == candidate, "Explicit lookup finds recovery candidate")
        expect(!auth.hasProfiles, "Lookup alone cannot overwrite local setup")
        try auth.acceptRecoveryProfiles(candidate)
        expect(auth.hasProfiles, "Accepted recovery stores credentials")
        KeychainStore.values = [:]
    }

    static func testSimilarFingerprints() throws {
        let gradient = (0..<72).map { UInt8(30 + ($0 % 9) * 20) }
        let brighter = gradient.map { $0 + 10 }
        let reversed = (0..<72).map { UInt8(190 - ($0 % 9) * 20) }
        let original = SimilarImageFingerprint(pixels: gradient)
        expect(original.resembles(SimilarImageFingerprint(pixels: brighter)), "Small brightness changes stay similar")
        expect(!original.resembles(SimilarImageFingerprint(pixels: reversed)), "Opposite spatial structure is not similar")
        expect(!SimilarImageFingerprint(pixels: [UInt8](repeating: 0, count: 72))
            .resembles(SimilarImageFingerprint(pixels: [UInt8](repeating: 255, count: 72))), "Flat dark and bright images differ")
        let image = try SimilarImageFingerprint(data: imageBytes())
        expect(image.resembles(try SimilarImageFingerprint(data: imageBytes())), "ImageIO decoding is deterministic")
        do {
            _ = try SimilarImageFingerprint(data: Data("not an image".utf8))
            preconditionFailure("Invalid image accepted")
        } catch is CocoaError { }
    }

    static func testCloudState() throws {
        expect(CloudFileState.evaluate(isUbiquitous: true, uploaded: true, uploading: false,
                                      hasError: false, hasConflict: false) == .uploaded, "Uploaded metadata")
        expect(CloudFileState.evaluate(isUbiquitous: nil, uploaded: true, uploading: false,
                                      hasError: false, hasConflict: false) == .unknown, "Unknown never marked uploaded")
        expect(CloudFileState.evaluate(isUbiquitous: true, uploaded: true, uploading: true,
                                      hasError: false, hasConflict: false) == .pending, "Ongoing upload beats cached uploaded flag")
        expect(CloudFileState.evaluate(isUbiquitous: true, uploaded: true, uploading: false,
                                      hasError: true, hasConflict: false) == .failed, "Upload error")
        expect(CloudFileState.evaluate(isUbiquitous: true, uploaded: true, uploading: false,
                                      hasError: false, hasConflict: true) == .failed, "Conflict")
    }

    static func testPINPolicy() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var state = PINAttemptState()
        for _ in 0..<4 { state.recordFailure(at: now) }
        expect(state.remainingSeconds(at: now) == 0, "First four attempts")
        state.recordFailure(at: now)
        expect(state.remainingSeconds(at: now) == 30, "Fifth failure waits 30 seconds")
        state = try JSONDecoder().decode(PINAttemptState.self, from: JSONEncoder().encode(state))
        expect(state.remainingSeconds(at: now.addingTimeInterval(10)) == 20, "Wait survives serialization")
        for expected in [60, 120, 240, 300, 300] {
            state.recordFailure(at: now)
            expect(state.remainingSeconds(at: now) == expected, "Backoff cap")
        }
        let limiter = PINAttemptLimiter()
        for _ in 0..<5 { try limiter.beginAttempt(now: now) }
        let loaded = try PINAttemptLimiter().state()
        expect(loaded.failures == 5, "Independent limiter instance loads state")
        do { try limiter.beginAttempt(now: now); preconditionFailure("Cooldown bypass") }
        catch is PINAttemptError { }
        try limiter.beginAttempt(now: now.addingTimeInterval(31))
        try limiter.reset()
        expect(try limiter.state().failures == 0, "Successful authentication resets state")
        KeychainStore.failWrites = true
        do { try limiter.beginAttempt(now: now); preconditionFailure("Failed state persistence must deny attempt") }
        catch is CocoaError { }
        KeychainStore.failWrites = false
    }

    static func testAuthenticationThrottle() throws {
        KeychainStore.values = [:]
        let auth = AuthenticationService()
        _ = try auth.createProfiles(mainPassword: "1234", subPassword: "5678")
        for prefix in ["1", "12", "123"] {
            do { _ = try auth.unlock(password: prefix, automatically: true); preconditionFailure("Prefix accepted") }
            catch PhotoVaultError.invalidPassword { }
        }
        expect(try PINAttemptLimiter().state().failures == 0, "Typing prefixes does not count as submitted failures")
        expect(try auth.unlock(password: "1234", automatically: true).kind == .main, "Matching input unlocks automatically")
        for _ in 0..<30 {
            do { _ = try auth.unlock(password: "0000", automatically: true) }
            catch PhotoVaultError.invalidPassword { }
        }
        do { _ = try auth.unlock(password: "1234", automatically: true); preconditionFailure("Automatic budget bypass") }
        catch is PINAttemptError { }
        try PINAttemptLimiter().reset()
        for _ in 0..<5 {
            do { _ = try auth.unlock(password: "0000"); preconditionFailure("Wrong PIN accepted") }
            catch PhotoVaultError.invalidPassword { }
        }
        expect(try PINAttemptLimiter().state().remainingSeconds() > 0, "Real authentication failure enters cooldown")
        do { _ = try auth.unlock(password: "1234"); preconditionFailure("Cooldown bypass through correct PIN") }
        catch is PINAttemptError { }
        // 経過済みの待機期限をテスト用ストアへ作り、正しい認証による解除を確認。
        try PINAttemptLimiter().reset()
        for _ in 0..<5 { try PINAttemptLimiter().beginAttempt(now: .now.addingTimeInterval(-60)) }
        let main = try auth.unlock(password: "1234")
        expect(main.kind == .main, "Correct main PIN unlocks only main vault")
        expect(try PINAttemptLimiter().state().failures == 0, "Successful authentication clears failures")
        let sub = try auth.unlock(password: "5678")
        expect(sub.kind == .sub && sub.masterKey != main.masterKey, "Separate vault PIN and key preserved")
    }

    static func fixturePhoto(id: UUID, folder: UUID, bytes: Data) -> PhotoRecord {
        PhotoRecord(id: id, folderID: folder, originalFilename: "test.png", encryptedFilename: "\(id).pvimg",
                    encryptedThumbnailFilename: "\(id).pvthumb", contentTypeIdentifier: UTType.png.identifier,
                    addedAt: .now, pixelWidth: 2, pixelHeight: 2, originalByteCount: Int64(bytes.count))
    }

    static func imageBytes() -> Data {
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func testPrivateBackupSettings() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "PhotoVault/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        expect(plist["UIFileSharingEnabled"] as? Bool == false, "Files sharing is disabled")
        expect(plist["LSSupportsOpeningDocumentsInPlace"] as? Bool == false, "Documents are not exposed in place")
    }

    static func testDailyBackupSchedule() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 5, day: day, hour: hour, minute: minute))!
        }
        let before = date(12, 1, 0)
        expect(DailyBackupSchedule.nextRun(now: before, lastSuccess: nil, minuteOfDay: 120, calendar: calendar) == date(12, 2, 0),
               "Wait for today's configured time")
        let after = date(12, 3, 0)
        expect(DailyBackupSchedule.nextRun(now: after, lastSuccess: date(11, 2, 0), minuteOfDay: 120, calendar: calendar) == after,
               "Run overdue backup after reopening")
        expect(DailyBackupSchedule.nextRun(now: after, lastSuccess: date(12, 2, 30), minuteOfDay: 120, calendar: calendar) == date(13, 2, 0),
               "Successful backup runs at most once per local day")
        expect(DailyBackupSchedule.nextRun(now: date(12, 1, 0), lastSuccess: date(12, 0, 30), minuteOfDay: 120, calendar: calendar) == date(13, 2, 0),
               "Changing the time does not repeat a completed day")
        let suite = UserDefaults(suiteName: "PhotoVault-schedule-test-\(UUID().uuidString)")!
        expect(DailyBackupSchedule.isEnabled(defaults: suite), "Automatic backup remains enabled by default")
        suite.set(false, forKey: DailyBackupSchedule.enabledKey)
        expect(!DailyBackupSchedule.isEnabled(defaults: suite), "The off setting is respected")
        suite.set(1440, forKey: DailyBackupSchedule.minuteKey)
        expect(DailyBackupSchedule.minuteOfDay(defaults: suite) == DailyBackupSchedule.defaultMinute, "Invalid settings fall back safely")
    }

    static func testAutomaticBackupCompression() throws {
        let data = Data(repeating: 42, count: 10_000)
        let encoded = AutomaticBackupCompression.encode(data)
        expect(encoded.count < data.count, "Repetitive backup data is compressed")
        let decoded = try AutomaticBackupCompression.decode(encoded, expectedSize: Int64(data.count))
        expect(decoded == data, "Compressed backup round trips")
        let compressedManifest = AutomaticBackupCompression.encodeManifest(data)
        expect(compressedManifest.count < data.count, "Backup manifest is compressed")
        let decodedManifest = try AutomaticBackupCompression.decodeManifest(compressedManifest)
        expect(decodedManifest == data, "Compressed manifest round trips")
        let oldManifest = try AutomaticBackupCompression.decodeManifest(data)
        expect(oldManifest == data, "Previous uncompressed manifest stays readable")
        let old = try AutomaticBackupCompression.decode(data, expectedSize: Int64(data.count))
        expect(old == data, "Previous uncompressed backup stays readable")
        do {
            _ = try AutomaticBackupCompression.decode(encoded, expectedSize: 99)
            preconditionFailure("Truncated decompression accepted")
        } catch PhotoVaultError.invalidBackup { }
    }

    static func testAutomaticBackup(root: URL) async throws {
        let defaults = UserDefaults.standard
        let oldEnabled = defaults.object(forKey: DailyBackupSchedule.enabledKey)
        let oldMinute = defaults.object(forKey: DailyBackupSchedule.minuteKey)
        defer {
            if let oldEnabled { defaults.set(oldEnabled, forKey: DailyBackupSchedule.enabledKey) }
            else { defaults.removeObject(forKey: DailyBackupSchedule.enabledKey) }
            if let oldMinute { defaults.set(oldMinute, forKey: DailyBackupSchedule.minuteKey) }
            else { defaults.removeObject(forKey: DailyBackupSchedule.minuteKey) }
        }
        defaults.set(true, forKey: DailyBackupSchedule.enabledKey)
        let parts = Calendar.current.dateComponents([.hour, .minute], from: .now)
        defaults.set((parts.hour ?? 0) * 60 + (parts.minute ?? 0), forKey: DailyBackupSchedule.minuteKey)
        let key = Data(repeating: 51, count: 32)
        let repository = try VaultRepository(kind: .main, masterKey: key, location: .local, isolatedStorageRoot: root)
        _ = try await repository.open()
        let folder = AlbumFolder(name: "自動保存")
        let bytes = imageBytes()
        let photo = fixturePhoto(id: UUID(), folder: folder.id, bytes: bytes)
        var database = VaultDatabase()
        database.folders = [folder]
        database.photos = [photo]
        let payload = VaultBackupPayload(formatVersion: 2, createdAt: .now, sourceVaultKind: .main,
            database: database, photos: [VaultBackupPhoto(record: photo, originalData: bytes)])
        _ = try await repository.restoreBackup(payload)
        // 手動実行せず、変更後に自動で保存されることを確認します。
        for _ in 0..<20 {
            let status = await repository.automaticBackupStatus
            if status.hasPrefix("保存済み") || status.hasPrefix("前回：") { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        let initialStatus = await repository.automaticBackupStatus
        expect(initialStatus.hasPrefix("保存済み") || initialStatus.hasPrefix("前回："), initialStatus)
        let first = try await repository.automaticBackupPayload()
        expect(first.photos.count == 1 && first.photos[0].originalData == bytes, "Automatic backup restores original bytes")
        let folderRoot = root.appendingPathComponent("AutomaticBackups/main")
        let keyRoot = try FileManager.default.contentsOfDirectory(at: folderRoot, includingPropertiesForKeys: nil)[0]
        let objectsBefore = try FileManager.default.contentsOfDirectory(at: keyRoot, includingPropertiesForKeys: nil).filter { $0.pathExtension == "pvobject" }
        let timestamp = try objectsBefore[0].resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let manifestBeforeEdit = try Data(contentsOf: keyRoot.appendingPathComponent("manifest.pvauto"))
        _ = try await repository.renameFolder(id: folder.id, to: "編集後")
        try await Task.sleep(for: .seconds(3))
        let manifestAfterEdit = try Data(contentsOf: keyRoot.appendingPathComponent("manifest.pvauto"))
        expect(manifestAfterEdit == manifestBeforeEdit, "Edits do not trigger a second backup on the same day")
        defaults.set(false, forKey: DailyBackupSchedule.enabledKey)
        await repository.refreshAutomaticBackupSchedule()
        let offStatus = await repository.automaticBackupStatus
        expect(offStatus.contains("オフ"), "Disabling stops automatic backup")
        defaults.set(true, forKey: DailyBackupSchedule.enabledKey)
        await repository.refreshAutomaticBackupSchedule()
        await repository.runAutomaticBackupNow()
        let edited = try await repository.automaticBackupPayload()
        expect(edited.database.folders[0].name == "編集後", "Automatic backup captures metadata edits")
        let timestampAfter = try objectsBefore[0].resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        expect(timestamp == timestampAfter, "Unchanged photo is not rewritten")
        let manifestURL = keyRoot.appendingPathComponent("manifest.pvauto")
        let previousManifest = try Data(contentsOf: manifestURL)
        let damagedManifest = Data("damaged-backup".utf8)
        try damagedManifest.write(to: manifestURL)
        await repository.runAutomaticBackupNow()
        let afterDamagedAttempt = try Data(contentsOf: manifestURL)
        expect(afterDamagedAttempt == damagedManifest, "Unreadable prior backup is never overwritten")
        try previousManifest.write(to: manifestURL)
        let second = fixturePhoto(id: UUID(), folder: folder.id, bytes: bytes)
        database.photos.append(second)
        let extended = VaultBackupPayload(formatVersion: 2, createdAt: .now, sourceVaultKind: .main, database: database,
            photos: [VaultBackupPhoto(record: photo, originalData: bytes), VaultBackupPhoto(record: second, originalData: bytes)])
        _ = try await repository.restoreBackup(extended)
        let missing = root.appendingPathComponent("main/Files/" + second.encryptedFilename)
        let saved = try Data(contentsOf: missing)
        try FileManager.default.removeItem(at: missing)
        await repository.runAutomaticBackupNow()
        let unchanged = try Data(contentsOf: manifestURL)
        expect(previousManifest == unchanged, "Failed backup keeps previous complete manifest")
        let previous = try await repository.automaticBackupPayload()
        expect(previous.photos.count == 1, "Previous backup remains usable after failure")
        try saved.write(to: missing)
        await repository.runAutomaticBackupNow()
        let retried = try await repository.automaticBackupPayload()
        expect(retried.photos.count == 2, "Retry completes pending backup")
        let beforeRetention = Set(try await repository.retainedAutomaticBackups().map(\.id))
        _ = try await repository.deletePhoto(id: second.id)
        await repository.runAutomaticBackupNow()
        let retained = try await repository.retainedAutomaticBackups()
        let newRetention = retained.filter { !beforeRetention.contains($0.id) }
        expect(!newRetention.isEmpty, "Removing a photo archives the previous completed snapshot")
        let preservedID = newRetention[0].id
        _ = try await repository.permanentlyDelete(ids: [second.id])
        await repository.runAutomaticBackupNow()
        let latest = try await repository.automaticBackupPayload()
        expect(latest.photos.count == 1, "Latest backup reflects permanent deletion")
        let recovered = try await repository.automaticBackupPayload(retainedID: preservedID)
        expect(recovered.photos.count == 2 && recovered.photos.allSatisfy { $0.originalData == bytes },
               "Retained snapshot keeps deleted originals after cleanup")
        let archiveIDsBefore = Set(try await repository.retainedAutomaticBackups().map(\.id))
        try await repository.retainCurrentAutomaticBackup()
        try await repository.retainCurrentAutomaticBackup()
        let archiveIDsAfter = Set(try await repository.retainedAutomaticBackups().map(\.id))
        expect(archiveIDsAfter.count <= archiveIDsBefore.count + 1, "Manual retention of same snapshot is idempotent")
        do {
            _ = try await repository.automaticBackupPayload(retainedID: "../manifest")
            preconditionFailure("Unsafe archive ID accepted")
        } catch PhotoVaultError.invalidBackup { }
        await repository.cancelAutomaticBackup()
        // 管理データだけが壊れた場合でも、独立バックアップから別フォルダに復元します。
        let originalIndex = root.appendingPathComponent("main/vault-index.pvdb")
        let damaged = Data("broken-index".utf8)
        try damaged.write(to: originalIndex)
        let damagedRepository = try VaultRepository(kind: .main, masterKey: key, location: .local, isolatedStorageRoot: root)
        do {
            _ = try await damagedRepository.open()
            preconditionFailure("Damaged index was accepted")
        } catch PhotoVaultError.databaseCorrupted { }
        let recoveryRoot = root.appendingPathComponent("separate-recovery")
        try await damagedRepository.recoverAutomaticBackupToLocal(root: recoveryRoot, photoLimit: nil)
        let recoveredRepo = try VaultRepository(kind: .main, masterKey: key, location: .local, isolatedStorageRoot: recoveryRoot)
        let recoveredDatabase = try await recoveredRepo.open()
        expect(recoveredDatabase.photos.count == 1, "Backup restores a separate usable vault")
        let recoveredImage = try await recoveredRepo.imageData(for: photo.id, thumbnail: false)
        expect(recoveredImage == bytes, "Separate recovery contains the original photo")
        let stillDamaged = try Data(contentsOf: originalIndex)
        expect(stillDamaged == damaged, "Recovery does not overwrite the original damaged index")
        await recoveredRepo.cancelAutomaticBackup()
        try FileManager.default.removeItem(at: originalIndex)
        let missingRepository = try VaultRepository(kind: .main, masterKey: key, location: .local, isolatedStorageRoot: root)
        do {
            _ = try await missingRepository.open()
            preconditionFailure("Missing index masked by a new empty vault")
        } catch PhotoVaultError.databaseCorrupted { }
        expect(!FileManager.default.fileExists(atPath: originalIndex.path), "Missing index is not replaced")
        try VaultFileStore(kind: .main, location: .local, isolatedStorageRoot: root).removeAllVaultData(recreateDirectories: false)
        expect(!FileManager.default.fileExists(atPath: keyRoot.path), "Explicit full deletion removes automatic backups")
    }

    static func testDailyDataProtection(root: URL) async throws {
        let key = Data(repeating: 19, count: 32)
        let first = try VaultRepository(kind: .main, masterKey: key, location: .local, isolatedStorageRoot: root)
        _ = try await first.open()
        let stale = try VaultRepository(kind: .main, masterKey: key, location: .local, isolatedStorageRoot: root)
        _ = try await stale.open()
        _ = try await first.createFolder(named: "最新の更新")
        let index = root.appendingPathComponent("main/vault-index.pvdb")
        let latestBytes = try Data(contentsOf: index)
        do {
            _ = try await stale.createFolder(named: "古い一覧からの更新")
            preconditionFailure("Stale database overwrote the latest update")
        } catch MaintenanceError.databaseChanged { }
        let afterFailure = try Data(contentsOf: index)
        expect(latestBytes == afterFailure, "Conflict leaves the latest encrypted database unchanged")
        let fresh = try VaultRepository(kind: .main, masterKey: key, location: .local, isolatedStorageRoot: root)
        let current = try await fresh.open()
        expect(current.folders.contains { $0.name == "最新の更新" }, "Latest folder survives conflict")
        _ = try await fresh.createFolder(named: "開き直した後の更新")
        let source = root.appendingPathComponent("main")
        let photo = source.appendingPathComponent("Files/protection-test.enc")
        let originalPhoto = Data("encrypted-photo-placeholder".utf8)
        try originalPhoto.write(to: photo)
        let beforeMove = try Data(contentsOf: index)
        let retained = try VaultFileStore.retainLocalMigrationSource(source)
        let retainedIndex = try Data(contentsOf: retained.appendingPathComponent("vault-index.pvdb"))
        let retainedPhoto = try Data(contentsOf: retained.appendingPathComponent("Files/protection-test.enc"))
        expect(retainedIndex == beforeMove && retainedPhoto == originalPhoto, "Migration preserves encrypted index and original photo bytes")
    }

    static func testCompleteResetSafety(root: URL) throws {
        var stages: [String] = []
        do {
            try CompleteVaultReset.perform(validateIdentity: {}, deleteCloud: {
                stages.append("cloud")
                throw CocoaError(.fileWriteNoPermission)
            }, deleteLocal: { stages.append("local") }, deleteCredentials: { stages.append("keys") })
            preconditionFailure("Failed deletion reported as successful")
        } catch CocoaError.fileWriteNoPermission { }
        expect(stages == ["cloud"], "Cloud deletion failure preserves local data and keys")
        stages = []
        do {
            try CompleteVaultReset.perform(validateIdentity: {}, deleteCloud: { stages.append("cloud") },
                deleteLocal: { stages.append("local"); throw CocoaError(.fileWriteNoPermission) },
                deleteCredentials: { stages.append("keys") })
            preconditionFailure("Failed local deletion reported as successful")
        } catch CocoaError.fileWriteNoPermission { }
        expect(stages == ["cloud", "local"], "Local deletion failure preserves keys")
        stages = []
        var validationCount = 0
        do {
            try CompleteVaultReset.perform(validateIdentity: {
                validationCount += 1
                if validationCount == 2 { throw CloudAccountError.changed }
            }, deleteCloud: { stages.append("cloud") }, deleteLocal: { stages.append("local") },
               deleteCredentials: { stages.append("keys") })
            preconditionFailure("Reset continued after account changed")
        } catch CloudAccountError.changed { }
        expect(stages == ["cloud"], "Account switch stops further deletion")
        stages = []
        try CompleteVaultReset.perform(validateIdentity: {}, deleteCloud: { stages.append("cloud") },
            deleteLocal: { stages.append("local") }, deleteCredentials: { stages.append("keys") })
        expect(stages == ["cloud", "local", "keys"], "Keys deleted only after files")
        let oldStore = VaultFileStore(kind: .main, location: .local, isolatedStorageRoot: root)
        CompleteVaultReset.begin()
        do {
            _ = try oldStore.vaultDirectory
            preconditionFailure("Storage remained writable during reset")
        } catch is CancellationError { }
        CompleteVaultReset.end()
        do {
            _ = try oldStore.vaultDirectory
            preconditionFailure("Old storage operation survived complete reset")
        } catch is CancellationError { }
        _ = try VaultFileStore(kind: .main, location: .local, isolatedStorageRoot: root).vaultDirectory
    }

    static func testLocalRestartIsolation(root: URL) throws {
        let defaults = UserDefaults.standard
        let previousNamespace = defaults.object(forKey: LocalRestartState.namespaceKey)
        let previousKeychain = KeychainStore.values
        defer {
            if let previousNamespace { defaults.set(previousNamespace, forKey: LocalRestartState.namespaceKey) }
            else { defaults.removeObject(forKey: LocalRestartState.namespaceKey) }
            KeychainStore.values = previousKeychain
        }
        defaults.removeObject(forKey: LocalRestartState.namespaceKey)
        KeychainStore.values = [:]
        let authentication = AuthenticationService()
        _ = try authentication.createProfiles(mainPassword: "1111", subPassword: "2222")
        let originalCredentials = KeychainStore.values
        let oldStore = VaultFileStore(kind: .main, location: .local, isolatedStorageRoot: root)
        let oldDirectory = LocalRestartState.directory
        defaults.set(UUID().uuidString, forKey: LocalRestartState.namespaceKey)
        expect(!authentication.hasLocalProfiles, "Reset does not adopt old authentication")
        expect(LocalRestartState.directory != oldDirectory, "Reset uses a separate local directory")
        _ = try authentication.createProfiles(mainPassword: "3333", subPassword: "4444")
        for (account, value) in originalCredentials {
            expect(KeychainStore.values[account] == value, "Original credentials preserved during new setup")
        }
        do {
            try authentication.publishProfilesToICloud()
            preconditionFailure("Fresh local credentials published over original cloud profile")
        } catch LocalRestartError.localOnly { }
        do {
            _ = try VaultFileStore(kind: .main, location: .iCloud).vaultDirectory
            preconditionFailure("Cloud storage permitted after isolated reset")
        } catch LocalRestartError.localOnly { }
        do {
            _ = try oldStore.vaultDirectory
            preconditionFailure("Old storage operation survived namespace change")
        } catch is CancellationError { }
        authentication.deleteAllCredentials()
        for (account, value) in originalCredentials {
            expect(KeychainStore.values[account] == value, "Deleting fresh credentials preserves original credentials")
        }
        for state in [CloudFileState.pending, .unknown, .failed] {
            let status = VaultCloudStatus(checkedAt: .now, location: .iCloud, index: state,
                                          uploadedPhotos: 1, pendingPhotos: 0, unknownPhotos: 0, failedPhotos: 0)
            expect(!status.allowsOriginalDeletion, "Unconfirmed index prevents original photo deletion")
        }
        let pendingPhoto = VaultCloudStatus(checkedAt: .now, location: .iCloud, index: .uploaded,
                                            uploadedPhotos: 0, pendingPhotos: 1, unknownPhotos: 0, failedPhotos: 0)
        expect(!pendingPhoto.allowsOriginalDeletion, "Pending photo prevents original deletion")
        let uploaded = VaultCloudStatus(checkedAt: .now, location: .iCloud, index: .uploaded,
                                       uploadedPhotos: 1, pendingPhotos: 0, unknownPhotos: 0, failedPhotos: 0)
        expect(uploaded.allowsOriginalDeletion, "Confirmed uploads permit original deletion")
    }

    static func testSeparateLocalRecovery(root: URL) async throws {
        let key = Data(repeating: 42, count: 32)
        let originalRoot = root.appendingPathComponent("original")
        let localRoot = root.appendingPathComponent("recovery-local")
        let original = try VaultRepository(kind: .main, masterKey: key, location: .local, isolatedStorageRoot: originalRoot)
        _ = try await original.open()
        _ = try await original.createFolder(named: "以前のアルバム")
        let originalURL = originalRoot.appendingPathComponent("main/vault-index.pvdb")
        let originalBytes = try Data(contentsOf: originalURL)
        let fallback = try VaultRepository(kind: .main, masterKey: key, location: .local, isolatedStorageRoot: localRoot)
        let empty = try await fallback.open()
        expect(empty.folders.isEmpty, "Separate local album starts empty")
        _ = try await fallback.createFolder(named: "新しい端末アルバム")
        let reopened = try VaultRepository(kind: .main, masterKey: key, location: .local, isolatedStorageRoot: localRoot)
        let retained = try await reopened.open()
        expect(retained.folders.contains { $0.name == "新しい端末アルバム" }, "Returning to local retains added content")
        let unchangedOriginal = try Data(contentsOf: originalURL)
        expect(unchangedOriginal == originalBytes, "Local creation and reopening never overwrite original encrypted index")
        let restored = try VaultRepository.decodeCloudDatabase(originalBytes, key: key)
        expect(restored.folders.contains { $0.name == "以前のアルバム" }, "Original remains decryptable with the retained key")
    }

    static func testRepository(root: URL) async throws {
        let key = Data(repeating: 7, count: 32)
        let folder = AlbumFolder(name: "元フォルダ")
        let bytes = imageBytes()
        let first = fixturePhoto(id: UUID(), folder: folder.id, bytes: bytes)
        let second = fixturePhoto(id: UUID(), folder: folder.id, bytes: bytes)
        var original = VaultDatabase()
        original.folders = [folder]
        original.photos = [first, second]
        original.schemaVersion = 7
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        // ゴミ箱フィールドが存在しない旧DBを実際に復号・読み込みします。
        var oldJSON = try JSONSerialization.jsonObject(with: encoder.encode(original)) as! [String: Any]
        oldJSON.removeValue(forKey: "trash")
        let store = VaultFileStore(kind: .main, location: .local, isolatedStorageRoot: root)
        try store.writeDatabase(CryptoBox.seal(JSONSerialization.data(withJSONObject: oldJSON), using: key))
        for photo in original.photos {
            try store.writePhoto(CryptoBox.seal(bytes, using: key), named: photo.encryptedFilename)
            try store.writeThumbnail(CryptoBox.seal(bytes, using: key), named: photo.encryptedThumbnailFilename)
        }
        let repo = try VaultRepository(kind: .main, masterKey: key, location: .local, isolatedStorageRoot: root)
        var db = try await repo.open()
        expect(db.photos.count == 2 && (db.trash ?? []).isEmpty, "Old DB migration")
        let status = try await repo.cloudStatus()
        expect(status.uploadedPhotos == 0 && status.location == .local, "Local is not cloud backup")
        let similar = try await repo.scanSimilarPhotos()
        expect(similar.groups.count == 1 && similar.inspectedCount == 2 && similar.failedCount == 0, "Similar scan reads encrypted originals")
        expect(similar.groups[0].photos.count == 2, "Similar scan includes both candidates")
        let scan = try await repo.scanDuplicates()
        expect(scan.groups.count == 1 && scan.failedCount == 0, "Legacy photos without digest are scanned")
        // 同じグループでも、検査後に内容が変われば削除を拒否します。
        try store.writePhoto(CryptoBox.seal(Data("changed".utf8), using: key), named: second.encryptedFilename)
        do {
            _ = try await repo.trashDuplicates(group: scan.groups[0], keeping: first.id)
            preconditionFailure("Changed content must not be deleted")
        } catch MaintenanceError.databaseChanged { }
        expect(await repo.snapshot().photos.count == 2, "Rejected cleanup retains both records")
        try store.writePhoto(CryptoBox.seal(bytes, using: key), named: second.encryptedFilename)
        db = try await repo.trashDuplicates(group: scan.groups[0], keeping: first.id)
        expect(db.photos.map(\.id) == [first.id] && db.trash?.count == 1, "Keep selected photo")
        expect(try store.readPhoto(named: second.encryptedFilename).count > 0, "Trash retains encrypted original")
        do { _ = try await repo.restoreTrashedPhoto(id: second.id, photoLimit: 1); preconditionFailure("Free limit bypass") }
        catch MaintenanceError.photoLimit { }
        db = try await repo.restoreTrashedPhoto(id: second.id, photoLimit: nil)
        expect(db.photos.count == 2 && db.trash?.count == 0, "Restore trash")
        db = try await repo.deleteFolder(id: folder.id)
        expect(db.folders.isEmpty && db.photos.isEmpty && db.trash?.count == 2, "Folder deletion retains photos")
        let backup = try await repo.backupPayload()
        expect(backup.formatVersion == 2 && backup.photos.count == 2, "Backup includes trash")
        let sealed = try VaultBackupCodec.seal(backup, password: "test-password")
        let decoded = try VaultBackupCodec.open(sealed, password: "test-password")
        expect(decoded.database.trash?.count == 2, "Encrypted backup round trip")
        db = try await repo.restoreTrashedPhoto(id: first.id, photoLimit: nil)
        expect(db.folders.first?.name == folder.name && db.photos.count == 1, "Deleted folder recreated")
        let storage = await repo.storageStatus()
        expect(storage.originalBytes == Int64(bytes.count) && storage.trashBytes == Int64(bytes.count), "Storage separates trash")
        expect((storage.encryptedFileBytes ?? 0) > storage.originalBytes && storage.cacheBytes == 0, "Encrypted and cache sizes")
        try await repo.clearReadCache()
        expect(try store.readPhoto(named: first.encryptedFilename).count > 0, "Cache clear preserves photos")
        // 元画像削除後にサムネイルの削除が失敗する状況を再現します。
        let thumbnails = try store.thumbnailsDirectory
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: thumbnails.path)
        do {
            _ = try await repo.permanentlyDelete(ids: [second.id])
            preconditionFailure("Expected thumbnail deletion failure")
        } catch { }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: thumbnails.path)
        db = await repo.snapshot()
        expect(db.trash?.first?.deletionRequested == true, "Failed deletion retains durable intent")
        do {
            _ = try await repo.restoreTrashedPhoto(id: second.id, photoLimit: nil)
            preconditionFailure("Cannot restore partly deleted photo")
        } catch MaintenanceError.trashUnavailable { }
        let reopened = try VaultRepository(kind: .main, masterKey: key, location: .local, isolatedStorageRoot: root)
        _ = try await reopened.open()
        db = try await reopened.purgeExpiredTrash()
        expect(db.trash?.isEmpty == true, "Deletion intent retried after reopening")
        // 別インスタンスで更新された一覧を、旧インスタンスでは上書きしません。
        do {
            _ = try await repo.permanentlyDelete(ids: [second.id])
            preconditionFailure("Stale deletion overwrote updated index")
        } catch MaintenanceError.databaseChanged { }
        _ = try await repo.open()
        db = try await repo.permanentlyDelete(ids: [second.id])
        expect(db.trash?.isEmpty == true, "Permanent delete removes record")
        expect(!FileManager.default.fileExists(atPath: try store.filesDirectory.appendingPathComponent(second.encryptedFilename).path), "Permanent delete removes original")
        db = try await repo.restoreBackup(decoded)
        expect(db.trash?.count == 2 && db.photos.isEmpty, "Backup restores trash")
        db = try await repo.restoreTrashedPhoto(id: first.id, photoLimit: nil)
        db = try await repo.restoreTrashedPhoto(id: second.id, photoLimit: nil)
        expect(db.folders.count == 1 && Set(db.photos.compactMap(\.folderID)).count == 1,
               "Photos from same deleted folder restore to one folder")
        _ = try await repo.restoreBackup(decoded)
        db = try await repo.purgeExpiredTrash(now: .now.addingTimeInterval(31 * 24 * 60 * 60))
        expect(db.trash?.isEmpty == true, "30-day expiry cleanup")
        // Version 1 remains supported.
        let legacy = VaultBackupPayload(formatVersion: 1, createdAt: .now, sourceVaultKind: .main,
                                        database: original, photos: original.photos.map { VaultBackupPhoto(record: $0, originalData: bytes) })
        _ = try VaultBackupCodec.open(VaultBackupCodec.seal(legacy, password: "test-password"), password: "test-password")
        db = try await repo.restoreBackup(legacy)
        expect(db.photos.count == 2, "Legacy backup restore")
        try FileManager.default.removeItem(at: try store.filesDirectory.appendingPathComponent(second.encryptedFilename))
        let partialSimilar = try await repo.scanSimilarPhotos()
        expect(partialSimilar.failedCount == 1 && partialSimilar.inspectedCount == 1 && partialSimilar.groups.isEmpty,
               "Similar scan reports missing originals without inventing candidates")
        let incomplete = try await repo.scanDuplicates()
        expect(incomplete.failedCount == 1 && incomplete.inspectedCount == 1, "Missing photo reported as unchecked")
        try store.writePhoto(CryptoBox.seal(bytes, using: key), named: second.encryptedFilename)

        // 保存失敗でもメモリ上・元画像の両方が残ることを確認。
        let index = try store.databaseURL
        let savedIndex = try Data(contentsOf: index)
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        do { _ = try await repo.deletePhoto(id: first.id); preconditionFailure("Expected index write failure") }
        catch { }
        db = await repo.snapshot()
        expect(db.photos.count == 2 && (db.trash ?? []).isEmpty, "Failed write rolls back in-memory DB")
        expect(try store.readPhoto(named: first.encryptedFilename).count > 0, "Failed write retains photo")
        try FileManager.default.removeItem(at: index)
        try savedIndex.write(to: index)
        // 不正なパスを含むバックアップを拒否。
        var invalid = original
        let alias = PhotoRecord(id: UUID(), folderID: folder.id, originalFilename: "bad.png", encryptedFilename: "../bad",
                                encryptedThumbnailFilename: "bad.pvthumb", contentTypeIdentifier: UTType.png.identifier,
                                addedAt: .now, pixelWidth: 2, pixelHeight: 2, originalByteCount: Int64(bytes.count))
        invalid.photos = [alias]
        do {
            _ = try await repo.restoreBackup(VaultBackupPayload(formatVersion: 2, createdAt: .now, sourceVaultKind: .main,
                database: invalid, photos: [VaultBackupPhoto(record: alias, originalData: bytes)]))
            preconditionFailure("Unsafe backup path accepted")
        } catch PhotoVaultError.invalidBackup { }
    }
}
