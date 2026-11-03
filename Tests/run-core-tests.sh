#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
test_dir=$(mktemp -d /tmp/PhotoVault-CoreTests.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -parse-as-library -D DEBUG -module-cache-path "$test_dir/modules" \
    PhotoVault/Models/VaultModels.swift \
    PhotoVault/Models/VaultMaintenanceModels.swift \
    PhotoVault/Storage/VaultFileStore.swift \
    PhotoVault/Storage/VaultRepository.swift \
    PhotoVault/Security/CryptoBox.swift \
    PhotoVault/Security/KeyDerivation.swift \
    PhotoVault/Security/ICloudAccountGuard.swift \
    PhotoVault/Security/PINAttemptLimiter.swift \
    PhotoVault/Security/AuthenticationService.swift \
    PhotoVault/Services/ImportExportServices.swift \
    PhotoVault/Services/ZipArchive.swift \
    Tests/CoreRegressionTests.swift -o "$test_dir/tests"
"$test_dir/tests"
