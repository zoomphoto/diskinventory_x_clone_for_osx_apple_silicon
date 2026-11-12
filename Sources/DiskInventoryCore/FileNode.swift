import Foundation

public enum SizeMetric: String, CaseIterable, Identifiable, Sendable {
    case allocated = "Size on Disk"
    case logical = "Logical Size"

    public var id: String { rawValue }

    public var subtitle: String {
        switch self {
        case .allocated:
            return "Actual physical APFS blocks used on your SSD (ignores cloud-evicted & sparse zeros)"
        case .logical:
            return "Apparent byte length reported by file metadata"
        }
    }
}

public struct NodeFlags: OptionSet, Sendable, Equatable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let isDirectory         = NodeFlags(rawValue: 1 << 0)
    public static let isPackage           = NodeFlags(rawValue: 1 << 1)
    public static let isSymlink           = NodeFlags(rawValue: 1 << 2)
    public static let isDataless          = NodeFlags(rawValue: 1 << 3)
    public static let isHardLinkDuplicate = NodeFlags(rawValue: 1 << 4)
    public static let isInaccessible      = NodeFlags(rawValue: 1 << 5)
    public static let isHidden            = NodeFlags(rawValue: 1 << 6)
}

public enum DeletionSafety: Equatable, Sendable {
    case safe
    case caution(String)
    case protectedSystemPath(String)

    public var isAllowed: Bool {
        if case .protectedSystemPath = self {
            return false
        }
        return true
    }
}

public final class FileNode: Identifiable, @unchecked Sendable {
    public let id: UInt64
    public let name: String
    public let explicitPath: String?
    public weak var parent: FileNode?

    public var allocatedSize: Int64
    public var logicalSize: Int64
    public var fileCount: Int
    public let modificationTime: Int64
    public let kindID: UInt16
    public var flags: NodeFlags
    public var children: [FileNode]

    public init(
        id: UInt64,
        name: String,
        explicitPath: String? = nil,
        parent: FileNode? = nil,
        allocatedSize: Int64 = 0,
        logicalSize: Int64 = 0,
        fileCount: Int = 0,
        modificationTime: Int64 = 0,
        kindID: UInt16 = FileKindRegistry.directoryKindID,
        flags: NodeFlags = [],
        children: [FileNode] = []
    ) {
        self.id = id
        self.name = name
        self.explicitPath = explicitPath
        self.parent = parent
        self.allocatedSize = allocatedSize
        self.logicalSize = logicalSize
        self.fileCount = fileCount
        self.modificationTime = modificationTime
        self.kindID = kindID
        self.flags = flags
        self.children = children
    }

    @inlinable
    public var isDirectory: Bool { flags.contains(.isDirectory) }

    @inlinable
    public var isPackage: Bool { flags.contains(.isPackage) }

    @inlinable
    public var isSymlink: Bool { flags.contains(.isSymlink) }

    @inlinable
    public var isDataless: Bool { flags.contains(.isDataless) }

    @inlinable
    public var isHardLinkDuplicate: Bool { flags.contains(.isHardLinkDuplicate) }

    @inlinable
    public var isInaccessible: Bool { flags.contains(.isInaccessible) }

    @inlinable
    public var isHidden: Bool { flags.contains(.isHidden) }

    @inlinable
    public func size(for metric: SizeMetric) -> Int64 {
        switch metric {
        case .allocated: return allocatedSize
        case .logical: return logicalSize
        }
    }

    /// True if this node should be treated as an atomic leaf item rather than drilled into.
    @inlinable
    public func actsAsLeaf(showPackageContents: Bool, currentRoot: FileNode?) -> Bool {
        if !isDirectory { return true }
        if isPackage && !showPackageContents && self !== currentRoot {
            return true
        }
        return children.isEmpty
    }

    public var modificationDate: Date? {
        guard modificationTime > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(modificationTime))
    }

    /// Full filesystem path reconstructed from the ancestor chain.
    public var path: String {
        if let explicitPath {
            return explicitPath
        }
        var parts: [String] = []
        var cursor: FileNode? = self
        var base: String = ""

        while let node = cursor {
            if let explicit = node.explicitPath {
                base = explicit
                break
            }
            parts.append(node.name)
            cursor = node.parent
        }

        parts.reverse()
        let joined = parts.joined(separator: "/")
        if base.isEmpty {
            return joined.isEmpty ? "/" : "/" + joined
        }
        if base == "/" {
            return joined.isEmpty ? "/" : "/" + joined
        }
        if joined.isEmpty {
            return base
        }
        return base.hasSuffix("/") ? (base + joined) : (base + "/" + joined)
    }

    public var url: URL {
        URL(fileURLWithPath: path, isDirectory: isDirectory)
    }

    /// Path relative to an ancestor root for compact UI display.
    public func relativePath(from root: FileNode) -> String {
        if self === root { return root.name }
        var parts: [String] = []
        var cursor: FileNode? = self
        while let node = cursor, node !== root {
            parts.append(node.name)
            cursor = node.parent
        }
        parts.reverse()
        return parts.joined(separator: "/")
    }

    public func isDescendant(of candidateAncestor: FileNode) -> Bool {
        var cursor = self.parent
        while let node = cursor {
            if node === candidateAncestor { return true }
            cursor = node.parent
        }
        return false
    }

    /// Returns the chain `[stopRoot, ..., self]` when `stopRoot` is an ancestor, or `[..., self]` from true root.
    public func ancestorChain(from stopRoot: FileNode? = nil) -> [FileNode] {
        var chain: [FileNode] = []
        var cursor: FileNode? = self
        while let node = cursor {
            chain.append(node)
            if let stopRoot, node === stopRoot {
                break
            }
            cursor = node.parent
        }
        chain.reverse()
        return chain
    }

    /// Sorts all directory child arrays descending by `metric` using an iterative stack.
    public func sortChildrenRecursively(by metric: SizeMetric) {
        var stack: [FileNode] = [self]
        while let node = stack.popLast() {
            if !node.children.isEmpty {
                node.children.sort { lhs, rhs in
                    let ls = lhs.size(for: metric)
                    let rs = rhs.size(for: metric)
                    if ls != rs { return ls > rs }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                for child in node.children where child.isDirectory && !child.children.isEmpty {
                    stack.append(child)
                }
            }
        }
    }

    /// Detaches this node from its parent and subtracts its sizes & file counts up the entire ancestor chain.
    @discardableResult
    public func detachAndSubtractFromAncestors() -> Bool {
        guard let parent = self.parent else { return false }
        guard let idx = parent.children.firstIndex(where: { $0 === self }) else { return false }

        parent.children.remove(at: idx)
        let removedAlloc = self.allocatedSize
        let removedLogical = self.logicalSize
        let removedFiles = self.isDirectory ? self.fileCount : 1

        var cursor: FileNode? = parent
        while let ancestor = cursor {
            ancestor.allocatedSize = max(0, ancestor.allocatedSize - removedAlloc)
            ancestor.logicalSize = max(0, ancestor.logicalSize - removedLogical)
            ancestor.fileCount = max(0, ancestor.fileCount - removedFiles)
            cursor = ancestor.parent
        }

        self.parent = nil
        return true
    }

    /// Computes aggregated FileKind statistics within this subtree.
    public func collectKindStatistics(
        metric: SizeMetric,
        showPackageContents: Bool,
        registry: FileKindRegistry = .shared
    ) -> [KindStatistic] {
        var totalsByKind: [UInt16: (bytes: Int64, count: Int)] = [:]
        totalsByKind.reserveCapacity(32)

        var stack: [FileNode] = [self]
        while let node = stack.popLast() {
            if node !== self && node.isPackage && !showPackageContents {
                let sz = node.size(for: metric)
                var entry = totalsByKind[node.kindID] ?? (0, 0)
                entry.bytes += sz
                entry.count += 1
                totalsByKind[node.kindID] = entry
                continue
            }

            if node.isDirectory {
                for child in node.children {
                    stack.append(child)
                }
            } else {
                let sz = node.size(for: metric)
                var entry = totalsByKind[node.kindID] ?? (0, 0)
                entry.bytes += sz
                entry.count += 1
                totalsByKind[node.kindID] = entry
            }
        }

        let grandTotal = totalsByKind.values.reduce(Int64(0)) { $0 + $1.bytes }
        let denom = Double(max(1, grandTotal))

        var stats: [KindStatistic] = totalsByKind.map { (kindID, pair) in
            KindStatistic(
                kind: registry.kind(for: kindID),
                totalBytes: pair.bytes,
                fileCount: pair.count,
                fraction: grandTotal > 0 ? Double(pair.bytes) / denom : 0
            )
        }

        stats.sort { lhs, rhs in
            if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
            return lhs.fileCount > rhs.fileCount
        }
        return stats
    }

    /// Finds the largest leaf files (and atomic packages when `showPackageContents == false`) in this subtree.
    /// Uses branch-and-bound subtree size pruning for sub-millisecond queries when unfiltered.
    public func collectLargestItems(
        limit: Int = 250,
        minBytes: Int64 = 0,
        metric: SizeMetric = .allocated,
        showPackageContents: Bool = false,
        searchQuery: String = "",
        kindFilter: UInt16? = nil
    ) -> [FileNode] {
        guard limit > 0 else { return [] }
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasQuery = !trimmedQuery.isEmpty

        // Min-heap of size `limit` ordered by smallest `size` at index 0
        var heap: [FileNode] = []
        heap.reserveCapacity(min(limit, 512))

        func siftUp(_ index: Int) {
            var child = index
            while child > 0 {
                let parentIdx = (child - 1) / 2
                if heap[child].size(for: metric) < heap[parentIdx].size(for: metric) {
                    heap.swapAt(child, parentIdx)
                    child = parentIdx
                } else {
                    break
                }
            }
        }

        func siftDown(_ index: Int) {
            var parentIdx = index
            let count = heap.count
            while true {
                let left = 2 * parentIdx + 1
                let right = left + 1
                var smallest = parentIdx
                if left < count && heap[left].size(for: metric) < heap[smallest].size(for: metric) {
                    smallest = left
                }
                if right < count && heap[right].size(for: metric) < heap[smallest].size(for: metric) {
                    smallest = right
                }
                if smallest == parentIdx { break }
                heap.swapAt(parentIdx, smallest)
                parentIdx = smallest
            }
        }

        func consider(_ candidate: FileNode) {
            let sz = candidate.size(for: metric)
            let floor = heap.count == limit ? max(minBytes, heap[0].size(for: metric)) : minBytes
            guard sz >= floor else { return }
            if let kindFilter, candidate.kindID != kindFilter { return }
            if hasQuery && !candidate.name.lowercased().contains(trimmedQuery) { return }

            if heap.count < limit {
                heap.append(candidate)
                siftUp(heap.count - 1)
            } else if sz > heap[0].size(for: metric) {
                heap[0] = candidate
                siftDown(0)
            }
        }

        var stack: [FileNode] = [self]
        while let node = stack.popLast() {
            let threshold = heap.count == limit ? max(minBytes, heap[0].size(for: metric)) : minBytes
            // Branch-and-bound: no descendant can have a larger size than its enclosing directory!
            if node.size(for: metric) < threshold && node !== self {
                continue
            }

            if node !== self && node.isPackage && !showPackageContents {
                consider(node)
                continue
            }

            if node.isDirectory {
                // Push children in reverse order (smallest first) so largest children pop first,
                // raising the min-heap threshold immediately for maximum subtree pruning!
                for child in node.children.reversed() {
                    if child.size(for: metric) >= threshold {
                        stack.append(child)
                    }
                }
            } else if node !== self {
                consider(node)
            }
        }

        return heap.sorted { lhs, rhs in
            let ls = lhs.size(for: metric)
            let rs = rhs.size(for: metric)
            if ls != rs { return ls > rs }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Evaluates whether moving this node to Trash is safe, warrants caution, or should be blocked.
    public func evaluateDeletionSafety(scanRoot: FileNode? = nil) -> DeletionSafety {
        if let scanRoot, self === scanRoot {
            return .protectedSystemPath("Cannot move the active scan root folder itself to Trash.")
        }
        if self.parent == nil {
            return .protectedSystemPath("Cannot move the root node to Trash.")
        }

        let fullPath = (self.path as NSString).standardizingPath
        let homePath = (NSHomeDirectory() as NSString).standardizingPath

        let blockedExactPaths: Set<String> = [
            "/", "/System", "/Users", "/Library", "/Applications",
            "/bin", "/sbin", "/usr", "/private", "/var", "/etc",
            "/dev", "/Volumes", "/cores", "/opt",
            homePath,
            homePath + "/Desktop",
            homePath + "/Documents",
            homePath + "/Downloads",
            homePath + "/Library",
            homePath + "/Pictures",
            homePath + "/Music",
            homePath + "/Movies"
        ]

        if blockedExactPaths.contains(fullPath) {
            return .protectedSystemPath("Protected macOS or top-level user directory (\(fullPath)). Delete individual items inside it instead.")
        }

        let blockedPrefixes = [
            "/System/",
            "/usr/bin/", "/usr/sbin/", "/usr/lib/", "/usr/libexec/", "/usr/share/",
            "/bin/", "/sbin/",
            "/Library/Apple/",
            "/private/var/db/"
        ]
        for prefix in blockedPrefixes where fullPath.hasPrefix(prefix) {
            return .protectedSystemPath("Protected macOS system file (\(fullPath)).")
        }

        if fullPath.hasPrefix(homePath + "/Library/") {
            let safeCacheHints = ["/Caches/", "/Logs/", "/Developer/Xcode/DerivedData", "/Developer/CoreSimulator", "/Containers/com.docker"]
            if safeCacheHints.contains(where: { fullPath.contains($0) }) {
                return .safe
            }
            return .caution("Located inside ~/Library — verify an app doesn't need this data before emptying Trash.")
        }

        if fullPath.hasPrefix("/Library/") || fullPath.hasPrefix("/private/") {
            return .caution("Located in a shared system folder — may require administrator authentication to move to Trash.")
        }

        return .safe
    }
}

/// Reduces a multi-selection so that if both a folder and one of its descendants are selected,
/// only the top-most ancestor is operated on (preventing double-trash or double-subtraction).
public func deduplicateTopLevelNodes(_ nodes: [FileNode]) -> [FileNode] {
    guard nodes.count > 1 else { return nodes }
    let selectedIDs = Set(nodes.map(\.id))
    return nodes.filter { node in
        var cursor = node.parent
        while let ancestor = cursor {
            if selectedIDs.contains(ancestor.id) {
                return false
            }
            cursor = ancestor.parent
        }
        return true
    }
}

