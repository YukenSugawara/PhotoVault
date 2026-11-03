import Foundation

/// PIN自体は保存せず、試行回数と待機期限だけを保持します。
struct PINAttemptState: Codable, Sendable {
    var failures = 0
    var blockedUntil: Date?
    var automaticChecks: Int?

    func remainingSeconds(at now: Date = .now) -> Int {
        max(0, Int(ceil((blockedUntil ?? .distantPast).timeIntervalSince(now))))
    }

    mutating func recordFailure(at now: Date = .now) {
        failures = min(failures + 1, 10)
        if failures >= 5 {
            let delay = min(300.0, 30.0 * pow(2, Double(failures - 5)))
            blockedUntil = now.addingTimeInterval(delay)
        }
    }
}

struct PINAttemptLimiter {
    private var account: String { LocalRestartState.account("pin-attempt-state-v1") }
    private let keychain = KeychainStore()

    func state() throws -> PINAttemptState {
        guard let data = try keychain.read(account: account, synchronizable: false) else { return PINAttemptState() }
        return try JSONDecoder().decode(PINAttemptState.self, from: data)
    }

    /// 検証前に試行を記録し、検証途中の強制終了でも待機制限を回避できないようにします。
    func beginAttempt(now: Date = .now) throws {
        var current = try state()
        guard current.remainingSeconds(at: now) == 0 else {
            throw PINAttemptError.waitUntil(current.blockedUntil!)
        }
        current.recordFailure(at: now)
        try keychain.save(JSONEncoder().encode(current), account: account, synchronizable: false)
    }

    /// 入力途中の不一致は通常の失敗に数えず、自動照合にも永続化した上限を設けます。
    func beginAutomaticCheck(now: Date = .now) throws {
        var current = try state()
        guard current.remainingSeconds(at: now) == 0 else {
            throw PINAttemptError.waitUntil(current.blockedUntil!)
        }
        if (current.automaticChecks ?? 0) >= 30 {
            current.automaticChecks = 0
            current.failures = max(current.failures, 4)
            current.recordFailure(at: now)
            try keychain.save(JSONEncoder().encode(current), account: account, synchronizable: false)
            throw PINAttemptError.waitUntil(current.blockedUntil!)
        }
        current.automaticChecks = (current.automaticChecks ?? 0) + 1
        try keychain.save(JSONEncoder().encode(current), account: account, synchronizable: false)
    }

    func reset() throws {
        try keychain.save(JSONEncoder().encode(PINAttemptState()), account: account, synchronizable: false)
    }
}

enum PINAttemptError: LocalizedError {
    case waitUntil(Date)
    var errorDescription: String? {
        switch self {
        case .waitUntil(let date): "入力回数の上限に達しました。\(date.formatted(date: .omitted, time: .standard))以降にもう一度お試しください。"
        }
    }
}
