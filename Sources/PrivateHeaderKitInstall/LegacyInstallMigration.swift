import Foundation

#if canImport(Darwin)
import Darwin
#endif

struct LegacyFileIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let linkCount: UInt64
    let size: UInt64
    let permissions: UInt16
    let sha256: String

    func validate(label: String) throws {
        guard sha256.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil else {
            throw InstallError.message("invalid SHA-256 in \(label)")
        }
        guard permissions <= 0o7777,
              permissions & 0o111 != 0
        else {
            throw InstallError.message("invalid executable permissions in \(label)")
        }
    }
}

enum LegacyDirectLayoutClassification: Equatable, Sendable {
    case absent
    case complete(LegacyLayoutSnapshot)
    case malformed(String)
}

struct LegacyLayoutSnapshot: Codable, Equatable, Sendable {
    let publicCommand: LegacyFileIdentity
    let rawDumpHelper: LegacyFileIdentity
    let simulatorHelper: LegacyFileIdentity

    func validate() throws {
        try publicCommand.validate(label: "legacy public command identity")
        try rawDumpHelper.validate(label: "legacy raw-helper identity")
        try simulatorHelper.validate(label: "legacy simulator-helper identity")
    }
}

struct LegacyMigrationIntent: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let targetManifest: ReleaseManifest
    let legacyLayout: LegacyLayoutSnapshot
    let publicBackupName: String
    let publicBackup: LegacyFileIdentity

    init(
        targetManifest: ReleaseManifest,
        legacyLayout: LegacyLayoutSnapshot,
        publicBackupName: String,
        publicBackup: LegacyFileIdentity
    ) {
        self.schemaVersion = Self.schemaVersion
        self.targetManifest = targetManifest
        self.legacyLayout = legacyLayout
        self.publicBackupName = publicBackupName
        self.publicBackup = publicBackup
    }

    func replacingPublicBackup(_ identity: LegacyFileIdentity) -> Self {
        Self(
            targetManifest: targetManifest,
            legacyLayout: legacyLayout,
            publicBackupName: publicBackupName,
            publicBackup: identity
        )
    }

    func validate() throws {
        guard schemaVersion == Self.schemaVersion else {
            throw InstallError.message(
                "unsupported legacy migration intent schema: \(schemaVersion)"
            )
        }
        try targetManifest.validate()
        try legacyLayout.validate()
        try publicBackup.validate(label: "legacy public-command backup identity")
        guard publicBackupName.hasPrefix(".legacy-public-"),
              publicBackupName != ".",
              publicBackupName != "..",
              !publicBackupName.contains("/")
        else {
            throw InstallError.message(
                "legacy migration intent has an unsafe backup name"
            )
        }
    }
}

extension VersionCohortInstaller {
    func classifyLegacyDirectLayout(
        current: ManagedPathSnapshot
    ) throws -> LegacyDirectLayoutClassification {
        let paths: [(label: String, url: URL)] = [
            ("public command", layout.publicCommandURL),
            ("raw helper", layout.rawDumpHelperURL),
            ("simulator helper", layout.simulatorHelperURL),
        ]
        let kinds = try paths.map { path in
            try fileSystemItemKind(
                at: path.url,
                fileManager: fileManager
            )
        }
        if kinds.allSatisfy({ kind in
            if case .absent = kind { return true }
            return false
        }) {
            return .absent
        }

        if case .symbolicLink(
            "../libexec/privateheaderkit/current/privateheaderkit"
        ) = kinds[0],
           case .symbolicLink = current,
           case .absent = kinds[1],
           case .absent = kinds[2]
        {
            return .absent
        }

        guard kinds.allSatisfy({ kind in
            if case .regularFile = kind { return true }
            return false
        }) else {
            return .malformed(
                "legacy direct install is partial or mixed with managed paths"
            )
        }

        let snapshot = LegacyLayoutSnapshot(
            publicCommand: try legacyFileIdentity(at: layout.publicCommandURL),
            rawDumpHelper: try legacyFileIdentity(at: layout.rawDumpHelperURL),
            simulatorHelper: try legacyFileIdentity(at: layout.simulatorHelperURL)
        )
        let identities = [
            snapshot.publicCommand,
            snapshot.rawDumpHelper,
            snapshot.simulatorHelper,
        ]
        guard identities.allSatisfy({ $0.permissions & 0o111 != 0 }),
              paths.allSatisfy({
                  fileManager.isExecutableFile(atPath: $0.url.path)
              })
        else {
            return .malformed(
                "legacy direct install contains a non-executable binary"
            )
        }
        return .complete(snapshot)
    }

    func migrationBackupURL(_ intent: LegacyMigrationIntent) -> URL {
        layout.binDir.appendingPathComponent(
            intent.publicBackupName,
            isDirectory: false
        )
    }

    func prepareLegacyMigration(
        targetManifest: ReleaseManifest,
        legacyLayout: LegacyLayoutSnapshot
    ) throws -> LegacyMigrationIntent {
        guard case .absent = try fileSystemItemKind(
            at: layout.legacyMigrationIntentURL,
            fileManager: fileManager
        ) else {
            throw InstallError.message(
                "legacy migration intent already exists: \(layout.legacyMigrationIntentURL.path)"
            )
        }
        try requireLegacyIdentity(
            legacyLayout.publicCommand,
            at: layout.publicCommandURL,
            label: "legacy public command"
        )

        let backupName = ".legacy-public-\(UUID().uuidString)"
        let backupURL = layout.binDir.appendingPathComponent(
            backupName,
            isDirectory: false
        )
        guard case .absent = try fileSystemItemKind(
            at: backupURL,
            fileManager: fileManager
        ) else {
            throw InstallError.message(
                "legacy public-command backup already exists: \(backupURL.path)"
            )
        }

        var shouldRemoveBackup = false
        defer {
            if shouldRemoveBackup {
                do {
                    try fileManager.removeItem(at: backupURL)
                } catch {
                    outputLogger(
                        "warning: failed to remove incomplete legacy public-command backup at \(backupURL.path): \(error)"
                    )
                }
            }
        }
        try fileManager.copyItem(at: layout.publicCommandURL, to: backupURL)
        shouldRemoveBackup = true
        let backupIdentity = try legacyFileIdentity(at: backupURL)
        guard backupIdentity.sha256 == legacyLayout.publicCommand.sha256,
              backupIdentity.size == legacyLayout.publicCommand.size,
              backupIdentity.permissions == legacyLayout.publicCommand.permissions,
              fileManager.isExecutableFile(atPath: backupURL.path)
        else {
            throw InstallError.message(
                "legacy public-command backup does not match its source"
            )
        }
        let intent = LegacyMigrationIntent(
            targetManifest: targetManifest,
            legacyLayout: legacyLayout,
            publicBackupName: backupName,
            publicBackup: backupIdentity
        )
        try persistLegacyMigrationIntent(intent, requireAbsent: true)
        shouldRemoveBackup = false
        return intent
    }

    func persistLegacyMigrationIntent(
        _ intent: LegacyMigrationIntent,
        requireAbsent: Bool
    ) throws {
        try intent.validate()
        let existingKind = try fileSystemItemKind(
            at: layout.legacyMigrationIntentURL,
            fileManager: fileManager
        )
        if requireAbsent {
            guard case .absent = existingKind else {
                throw InstallError.message(
                    "refusing to replace an existing legacy migration intent"
                )
            }
        } else {
            guard case .regularFile = existingKind else {
                throw InstallError.message(
                    "legacy migration intent changed while updating it"
                )
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(intent).write(
            to: layout.legacyMigrationIntentURL,
            options: [.atomic]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: layout.legacyMigrationIntentURL.path
        )
    }

    func readLegacyMigrationIntent() throws -> LegacyMigrationIntent? {
        switch try fileSystemItemKind(
            at: layout.legacyMigrationIntentURL,
            fileManager: fileManager
        ) {
        case .absent:
            return nil
        case .regularFile:
            break
        case .directory, .symbolicLink, .other:
            throw InstallError.message(
                "legacy migration intent is not a regular file: \(layout.legacyMigrationIntentURL.path)"
            )
        }

        do {
            let data = try Data(contentsOf: layout.legacyMigrationIntentURL)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == Set([
                      "schemaVersion",
                      "targetManifest",
                      "legacyLayout",
                      "publicBackupName",
                      "publicBackup",
                  ])
            else {
                throw InstallError.message(
                    "legacy migration intent has an unknown field set"
                )
            }
            let intent = try JSONDecoder().decode(LegacyMigrationIntent.self, from: data)
            try intent.validate()
            return intent
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.message(
                "failed to read legacy migration intent: \(error)"
            )
        }
    }

    func removeLegacyMigrationIntent() throws {
        switch try fileSystemItemKind(
            at: layout.legacyMigrationIntentURL,
            fileManager: fileManager
        ) {
        case .absent:
            return
        case .regularFile:
            try fileManager.removeItem(at: layout.legacyMigrationIntentURL)
        case .directory, .symbolicLink, .other:
            throw InstallError.message(
                "refusing to remove an invalid legacy migration intent"
            )
        }
    }

    func recoverInterruptedLegacyMigration() async throws {
        try Task.checkCancellation()
        guard var intent = try readLegacyMigrationIntent() else {
            return
        }
        try await validateDirectory(
            layout.cohortDirectory(for: intent.targetManifest),
            expectedManifest: intent.targetManifest
        )
        try Task.checkCancellation()

        let expectedCurrent = "versions/\(intent.targetManifest.cohort)"
        let current = try await currentPathSnapshot()
        switch current {
        case .absent:
            break
        case .symbolicLink(let destination) where destination == expectedCurrent:
            break
        case .symbolicLink, .regularFile:
            throw InstallError.message(
                "legacy migration intent conflicts with the active current cohort"
            )
        }

        switch try fileSystemItemKind(
            at: layout.publicCommandURL,
            fileManager: fileManager
        ) {
        case .regularFile:
            let publicIdentity = try legacyFileIdentity(at: layout.publicCommandURL)
            guard publicIdentity == intent.legacyLayout.publicCommand
                    || publicIdentity == intent.publicBackup
            else {
                throw InstallError.message(
                    "legacy public command no longer matches the interrupted migration intent"
                )
            }
            intent = try ensureLegacyPublicBackup(
                intent,
                ownedPublicIdentity: publicIdentity
            )
            if case .absent = current {
                try Task.checkCancellation()
                try atomicReplaceSymlink(
                    at: layout.currentURL,
                    destination: expectedCurrent
                )
            }
            try requireLegacyIdentity(
                publicIdentity,
                at: layout.publicCommandURL,
                label: "legacy public command during recovery"
            )
            try Task.checkCancellation()
            try atomicReplaceSymlink(
                at: layout.publicCommandURL,
                destination: "../libexec/privateheaderkit/current/privateheaderkit"
            )
        case .symbolicLink(let destination)
            where destination == "../libexec/privateheaderkit/current/privateheaderkit":
            if case .absent = current {
                try Task.checkCancellation()
                try atomicReplaceSymlink(
                    at: layout.currentURL,
                    destination: expectedCurrent
                )
            }
        case .absent, .directory, .symbolicLink, .other:
            throw InstallError.message(
                "legacy migration intent conflicts with the public command path"
            )
        }

        try await verifyActiveCohort(intent.targetManifest)
        try Task.checkCancellation()
        let warnings = try finalizeLegacyMigration(intent)
        for warning in warnings {
            outputLogger("warning: recovered interrupted legacy migration; \(warning)")
        }
        outputLogger(
            "Recovered interrupted PrivateHeaderKit migration to \(intent.targetManifest.cohort)"
        )
    }

    func ensureLegacyPublicBackup(
        _ intent: LegacyMigrationIntent,
        ownedPublicIdentity: LegacyFileIdentity
    ) throws -> LegacyMigrationIntent {
        let backupURL = migrationBackupURL(intent)
        switch try fileSystemItemKind(at: backupURL, fileManager: fileManager) {
        case .regularFile:
            try requireLegacyIdentity(
                intent.publicBackup,
                at: backupURL,
                label: "legacy public-command backup"
            )
            return intent
        case .absent:
            try requireLegacyIdentity(
                ownedPublicIdentity,
                at: layout.publicCommandURL,
                label: "legacy public command during backup recovery"
            )
            var shouldRemoveBackup = false
            defer {
                if shouldRemoveBackup {
                    do {
                        try fileManager.removeItem(at: backupURL)
                    } catch {
                        outputLogger(
                            "warning: failed to remove incomplete recovered public-command backup at \(backupURL.path): \(error)"
                        )
                    }
                }
            }
            try fileManager.copyItem(at: layout.publicCommandURL, to: backupURL)
            shouldRemoveBackup = true
            let newBackupIdentity = try legacyFileIdentity(at: backupURL)
            guard newBackupIdentity.sha256 == ownedPublicIdentity.sha256,
                  newBackupIdentity.size == ownedPublicIdentity.size,
                  newBackupIdentity.permissions == ownedPublicIdentity.permissions,
                  fileManager.isExecutableFile(atPath: backupURL.path)
            else {
                let primaryMessage =
                    "recovered legacy public-command backup does not match its source"
                do {
                    try fileManager.removeItem(at: backupURL)
                    shouldRemoveBackup = false
                } catch {
                    throw InstallError.message(
                        "\(primaryMessage); removing the invalid backup also failed: \(error)"
                    )
                }
                throw InstallError.message(primaryMessage)
            }
            let updated = intent.replacingPublicBackup(newBackupIdentity)
            try persistLegacyMigrationIntent(updated, requireAbsent: false)
            shouldRemoveBackup = false
            return updated
        case .directory, .symbolicLink, .other:
            throw InstallError.message(
                "legacy public-command backup changed during recovery"
            )
        }
    }

    func finalizeLegacyMigration(
        _ intent: LegacyMigrationIntent
    ) throws -> [String] {
        var warnings: [String] = []
        if let warning = cleanupLegacyFile(
            at: layout.rawDumpHelperURL,
            expected: intent.legacyLayout.rawDumpHelper,
            label: "legacy raw helper"
        ) {
            warnings.append(warning)
        }
        if let warning = cleanupLegacyFile(
            at: layout.simulatorHelperURL,
            expected: intent.legacyLayout.simulatorHelper,
            label: "legacy simulator helper"
        ) {
            warnings.append(warning)
        }
        if let warning = cleanupLegacyFile(
            at: migrationBackupURL(intent),
            expected: intent.publicBackup,
            label: "legacy public-command backup"
        ) {
            warnings.append(warning)
        }
        try removeLegacyMigrationIntent()
        return warnings
    }

    func cleanupLegacyFile(
        at url: URL,
        expected: LegacyFileIdentity,
        label: String
    ) -> String? {
        do {
            switch try fileSystemItemKind(at: url, fileManager: fileManager) {
            case .absent:
                return nil
            case .regularFile:
                let actual = try legacyFileIdentity(at: url)
                guard actual == expected else {
                    return "\(label) changed before cleanup; left untouched at \(url.path)"
                }
                try fileManager.removeItem(at: url)
                return nil
            case .directory, .symbolicLink, .other:
                return "\(label) changed before cleanup; left untouched at \(url.path)"
            }
        } catch {
            return "failed to clean up \(label) at \(url.path): \(error)"
        }
    }

    func requireLegacyIdentity(
        _ expected: LegacyFileIdentity,
        at url: URL,
        label: String
    ) throws {
        guard case .regularFile = try fileSystemItemKind(
            at: url,
            fileManager: fileManager
        ) else {
            throw InstallError.message("\(label) changed: \(url.path)")
        }
        let actual = try legacyFileIdentity(at: url)
        guard actual == expected,
              fileManager.isExecutableFile(atPath: url.path)
        else {
            throw InstallError.message("\(label) changed: \(url.path)")
        }
    }

    func restoreAfterActivationFailure(
        previousCurrent: ManagedPathSnapshot,
        previousPublicCommand: ManagedPathSnapshot,
        migrationIntent: LegacyMigrationIntent?
    ) -> Error? {
        do {
            try faultInjector(.publicRestorationStarted)
            try restorePublicCommand(
                previousPublicCommand,
                migrationIntent: migrationIntent
            )
            try faultInjector(.currentRestorationStarted)
            try restore(previousCurrent, at: layout.currentURL)
            if migrationIntent != nil {
                try removeLegacyMigrationIntent()
            }
            return nil
        } catch {
            return error
        }
    }

    func restorePublicCommand(
        _ snapshot: ManagedPathSnapshot,
        migrationIntent: LegacyMigrationIntent?
    ) throws {
        guard case .regularFile = snapshot else {
            try restore(snapshot, at: layout.publicCommandURL)
            return
        }
        guard let migrationIntent else {
            throw InstallError.message(
                "missing legacy migration intent while restoring the public command"
            )
        }
        let backupURL = migrationBackupURL(migrationIntent)
        switch try fileSystemItemKind(
            at: layout.publicCommandURL,
            fileManager: fileManager
        ) {
        case .absent:
            try restoreLegacyPublicBackup(migrationIntent, from: backupURL)
        case .symbolicLink(let destination)
            where destination == "../libexec/privateheaderkit/current/privateheaderkit":
            try restoreLegacyPublicBackup(migrationIntent, from: backupURL)
        case .regularFile:
            let actual = try legacyFileIdentity(at: layout.publicCommandURL)
            guard actual == migrationIntent.legacyLayout.publicCommand
                    || actual == migrationIntent.publicBackup
            else {
                throw InstallError.message(
                    "public command changed while restoring; refusing to replace it"
                )
            }
            if case .regularFile = try fileSystemItemKind(
                at: backupURL,
                fileManager: fileManager
            ) {
                try requireLegacyIdentity(
                    migrationIntent.publicBackup,
                    at: backupURL,
                    label: "legacy public-command backup"
                )
                try fileManager.removeItem(at: backupURL)
            }
        case .directory, .symbolicLink, .other:
            throw InstallError.message(
                "public command changed while restoring; refusing to replace it"
            )
        }
    }

    func restore(
        _ snapshot: ManagedPathSnapshot,
        at url: URL
    ) throws {
        switch snapshot {
        case .absent:
            switch try fileSystemItemKind(at: url, fileManager: fileManager) {
            case .absent:
                return
            case .symbolicLink(let destination)
                where isManagedRestorationDestination(destination, at: url):
                try fileManager.removeItem(at: url)
            case .regularFile, .directory, .symbolicLink, .other:
                throw InstallError.message(
                    "refusing to remove an unexpected path while restoring: \(url.path)"
                )
            }
        case .symbolicLink(let destination):
            switch try fileSystemItemKind(at: url, fileManager: fileManager) {
            case .absent:
                try atomicReplaceSymlink(at: url, destination: destination)
            case .symbolicLink(let currentDestination)
                where isManagedRestorationDestination(currentDestination, at: url):
                try atomicReplaceSymlink(at: url, destination: destination)
            case .regularFile, .directory, .symbolicLink, .other:
                throw InstallError.message(
                    "refusing to replace an unexpected path while restoring: \(url.path)"
                )
            }
        case .regularFile:
            throw InstallError.message(
                "regular-file restoration requires a legacy migration intent"
            )
        }
    }

    private func isManagedRestorationDestination(
        _ destination: String,
        at url: URL
    ) -> Bool {
        if url == layout.currentURL {
            return isManagedCurrentDestination(destination)
        }
        if url == layout.publicCommandURL {
            return destination == "../libexec/privateheaderkit/current/privateheaderkit"
        }
        return false
    }

    private func restoreLegacyPublicBackup(
        _ intent: LegacyMigrationIntent,
        from backupURL: URL
    ) throws {
        try requireLegacyIdentity(
            intent.publicBackup,
            at: backupURL,
            label: "legacy public-command backup"
        )
        try atomicRename(source: backupURL, destination: layout.publicCommandURL)
    }
}

private func legacyFileIdentity(at url: URL) throws -> LegacyFileIdentity {
#if canImport(Darwin)
    func readMetadata() throws -> stat {
        var metadata = stat()
        let result = url.path.withCString { path in
            Darwin.lstat(path, &metadata)
        }
        guard result == 0 else {
            throw InstallError.message(
                "failed to inspect legacy install path at \(url.path): errno \(errno)"
            )
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw InstallError.message(
                "legacy install path is not a regular file: \(url.path)"
            )
        }
        return metadata
    }

    let before = try readMetadata()
    let beforePermissions = UInt16(before.st_mode & mode_t(0o7777))
    let digest = try LiveReleaseArtifactInspector.sha256(of: url)
    let after = try readMetadata()
    let afterPermissions = UInt16(after.st_mode & mode_t(0o7777))
    guard before.st_dev == after.st_dev,
          before.st_ino == after.st_ino,
          before.st_nlink == after.st_nlink,
          before.st_size == after.st_size,
          beforePermissions == afterPermissions
    else {
        throw InstallError.message(
            "legacy install path changed during inspection: \(url.path)"
        )
    }
    return LegacyFileIdentity(
        device: UInt64(before.st_dev),
        inode: UInt64(before.st_ino),
        linkCount: UInt64(before.st_nlink),
        size: UInt64(before.st_size),
        permissions: beforePermissions,
        sha256: digest
    )
#else
    throw InstallError.message(
        "legacy install identity is unavailable on this platform: \(url.path)"
    )
#endif
}
