import Foundation

public struct ScanExclusionRule: Codable, Identifiable, Equatable, Sendable {
    public enum MatchKind: Codable, Equatable, Sendable {
        /// Matches an exact standardized directory path (e.g. `/Users/<username>/Library/CloudStorage`).
        case exactPath(String)
        /// Matches any directory whose standardized path ends with this suffix (e.g. `/Library/CloudStorage`).
        case pathSuffix(String)
        /// Matches any directory with this exact folder name anywhere in the tree (e.g. `.git` or `node_modules`).
        case folderName(String)
    }

    public var id: String
    public var title: String
    public var subtitle: String
    public var match: MatchKind
    public var isEnabled: Bool
    public var isBuiltIn: Bool

    public init(
        id: String = UUID().uuidString,
        title: String,
        subtitle: String,
        match: MatchKind,
        isEnabled: Bool,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.match = match
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
    }

    public var displayPattern: String {
        switch match {
        case .exactPath(let path):
            return path
        case .pathSuffix(let suffix):
            return "*\(suffix)"
        case .folderName(let name):
            return "Folder named “\(name)”"
        }
    }
}

public struct ScanExclusionConfig: Codable, Equatable, Sendable {
    public var rules: [ScanExclusionRule]

    public init(rules: [ScanExclusionRule] = Self.defaultRules()) {
        self.rules = rules
    }

    public static func defaultRules(homeDirectory: String = NSHomeDirectory()) -> [ScanExclusionRule] {
        let home = (homeDirectory as NSString).standardizingPath
        return [
            ScanExclusionRule(
                id: "builtin.cloudstorage",
                title: "Cloud Storage (Google Drive, OneDrive, Dropbox, Box)",
                subtitle: "\(home)/Library/CloudStorage — prevents slow remote FileProvider enumeration",
                match: .pathSuffix("/Library/CloudStorage"),
                isEnabled: true,
                isBuiltIn: true
            ),
            ScanExclusionRule(
                id: "builtin.iclouddrive",
                title: "iCloud Drive (Mobile Documents)",
                subtitle: "\(home)/Library/Mobile Documents",
                match: .pathSuffix("/Library/Mobile Documents"),
                isEnabled: false,
                isBuiltIn: true
            ),
            ScanExclusionRule(
                id: "builtin.photoslibrary",
                title: "System Photos Library",
                subtitle: "\(home)/Pictures/Photos Library.photoslibrary",
                match: .exactPath("\(home)/Pictures/Photos Library.photoslibrary"),
                isEnabled: false,
                isBuiltIn: true
            ),
            ScanExclusionRule(
                id: "builtin.trash",
                title: "User Trash",
                subtitle: "\(home)/.Trash",
                match: .pathSuffix("/.Trash"),
                isEnabled: false,
                isBuiltIn: true
            ),
            ScanExclusionRule(
                id: "builtin.systemvol",
                title: "macOS Sealed System Files (/System)",
                subtitle: "Skip read-only OS files when scanning Macintosh HD (/)",
                match: .exactPath("/System"),
                isEnabled: false,
                isBuiltIn: true
            ),
            ScanExclusionRule(
                id: "builtin.git",
                title: "Git Metadata Folders (.git)",
                subtitle: "Skip .git directories inside repositories",
                match: .folderName(".git"),
                isEnabled: false,
                isBuiltIn: true
            )
        ]
    }

    /// Merges saved rules with any newly introduced built-in presets while preserving user toggles & custom rules.
    public func mergedWithDefaults(homeDirectory: String = NSHomeDirectory()) -> ScanExclusionConfig {
        let defaults = Self.defaultRules(homeDirectory: homeDirectory)
        var byID: [String: ScanExclusionRule] = [:]
        for r in rules {
            byID[r.id] = r
        }

        var merged: [ScanExclusionRule] = []
        for var def in defaults {
            if let existing = byID[def.id] {
                def.isEnabled = existing.isEnabled
            }
            merged.append(def)
        }

        for r in rules where !r.isBuiltIn {
            merged.append(r)
        }
        return ScanExclusionConfig(rules: merged)
    }

    public var enabledRules: [ScanExclusionRule] {
        rules.filter(\.isEnabled)
    }

    public mutating func addCustomPath(_ rawPath: String) {
        let standardized = (rawPath as NSString).expandingTildeInPath
        let clean = (standardized as NSString).standardizingPath
        guard !clean.isEmpty, clean != "/" else { return }

        if let idx = rules.firstIndex(where: {
            if case .exactPath(let p) = $0.match { return p == clean }
            return false
        }) {
            rules[idx].isEnabled = true
            return
        }

        let name = URL(fileURLWithPath: clean).lastPathComponent
        rules.append(
            ScanExclusionRule(
                title: name.isEmpty ? clean : name,
                subtitle: clean,
                match: .exactPath(clean),
                isEnabled: true,
                isBuiltIn: false
            )
        )
    }

    public mutating func addCustomFolderName(_ rawName: String) {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return }

        if let idx = rules.firstIndex(where: {
            if case .folderName(let n) = $0.match { return n == trimmed }
            return false
        }) {
            rules[idx].isEnabled = true
            return
        }

        rules.append(
            ScanExclusionRule(
                title: "Folders named “\(trimmed)”",
                subtitle: "Skips any directory named \(trimmed) anywhere in scan",
                match: .folderName(trimmed),
                isEnabled: true,
                isBuiltIn: false
            )
        )
    }
}

/// Fast compiled matcher used on hot scanner worker threads with zero allocations per check.
public struct CompiledExclusionMatcher: Sendable {
    @usableFromInline let exactPaths: Set<String>
    @usableFromInline let pathSuffixes: [String]
    @usableFromInline let folderNames: Set<String>

    public init(config: ScanExclusionConfig, scanRootPath: String) {
        let rootClean = (scanRootPath as NSString).standardizingPath
        var exact = Set<String>()
        var suffixes: [String] = []
        var names = Set<String>()

        for rule in config.rules where rule.isEnabled {
            switch rule.match {
            case .exactPath(let p):
                let clean = (p as NSString).standardizingPath
                // Do not exclude `scanRootPath` itself or an ancestor of `scanRootPath`
                // if the user explicitly chose to scan inside that folder!
                if rootClean == clean || rootClean.hasPrefix(clean + "/") {
                    continue
                }
                exact.insert(clean)

            case .pathSuffix(let s):
                // If scanRootPath already lies inside this suffix, allow the explicit scan
                if rootClean.hasSuffix(s) || rootClean.contains(s + "/") {
                    continue
                }
                suffixes.append(s)

            case .folderName(let name):
                let rootLast = URL(fileURLWithPath: rootClean).lastPathComponent
                if rootLast == name {
                    continue
                }
                names.insert(name)
            }
        }

        self.exactPaths = exact
        self.pathSuffixes = suffixes
        self.folderNames = names
    }

    @inlinable
    public func shouldExclude(directoryName: String, fullPath: String) -> Bool {
        if !folderNames.isEmpty && folderNames.contains(directoryName) {
            return true
        }
        if !exactPaths.isEmpty && exactPaths.contains(fullPath) {
            return true
        }
        if !pathSuffixes.isEmpty {
            for suffix in pathSuffixes where fullPath.hasSuffix(suffix) {
                return true
            }
        }
        return false
    }
}
