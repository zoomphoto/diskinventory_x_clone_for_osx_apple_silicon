import Foundation
import Darwin

public struct VolumeSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let url: URL
    public let totalBytes: Int64
    public let availableBytes: Int64
    public let availableImportantBytes: Int64
    public let isInternal: Bool
    public let isRemovable: Bool
    public let fileSystemType: String

    public var usedBytes: Int64 {
        max(0, totalBytes - availableBytes)
    }

    public var purgeableBytes: Int64 {
        max(0, availableImportantBytes - availableBytes)
    }

    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, max(0.0, Double(usedBytes) / Double(totalBytes)))
    }

    public init(
        id: String,
        name: String,
        url: URL,
        totalBytes: Int64,
        availableBytes: Int64,
        availableImportantBytes: Int64,
        isInternal: Bool,
        isRemovable: Bool,
        fileSystemType: String
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.availableImportantBytes = availableImportantBytes
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.fileSystemType = fileSystemType
    }

    public static func mountedVolumes() -> [VolumeSummary] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey,
            .volumeIsBrowsableKey,
            .volumeLocalizedFormatDescriptionKey
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else {
            return []
        }

        var results: [VolumeSummary] = []
        for url in urls {
            let standardized = url.standardizedFileURL
            let path = standardized.path
            // Skip Time Machine snapshot mounts and synthetic system submounts
            if path.hasPrefix("/System/Volumes/") || path.contains(".timemachine") {
                continue
            }
            guard let vals = try? standardized.resourceValues(forKeys: Set(keys)) else {
                continue
            }
            let total = Int64(vals.volumeTotalCapacity ?? 0)
            guard total > 0 else { continue }
            let avail = Int64(vals.volumeAvailableCapacity ?? 0)
            let availImp = max(avail, vals.volumeAvailableCapacityForImportantUsage ?? avail)
            let name = vals.volumeName ?? (path == "/" ? "Macintosh HD" : standardized.lastPathComponent)
            let isInternal = vals.volumeIsInternal ?? (path == "/")
            let isRemovable = vals.volumeIsRemovable ?? false
            let fsDesc = vals.volumeLocalizedFormatDescription ?? "APFS"

            results.append(
                VolumeSummary(
                    id: path,
                    name: name,
                    url: standardized,
                    totalBytes: total,
                    availableBytes: avail,
                    availableImportantBytes: availImp,
                    isInternal: isInternal,
                    isRemovable: isRemovable,
                    fileSystemType: fsDesc
                )
            )
        }

        results.sort { lhs, rhs in
            if lhs.url.path == "/" { return true }
            if rhs.url.path == "/" { return false }
            if lhs.isInternal != rhs.isInternal { return lhs.isInternal && !rhs.isInternal }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return results
    }
}

public struct ScanProgress: Sendable {
    public let filesScanned: Int
    public let directoriesScanned: Int
    public let allocatedBytesFound: Int64
    public let currentPath: String
    public let elapsedSeconds: TimeInterval

    public init(
        filesScanned: Int,
        directoriesScanned: Int,
        allocatedBytesFound: Int64,
        currentPath: String,
        elapsedSeconds: TimeInterval
    ) {
        self.filesScanned = filesScanned
        self.directoriesScanned = directoriesScanned
        self.allocatedBytesFound = allocatedBytesFound
        self.currentPath = currentPath
        self.elapsedSeconds = elapsedSeconds
    }
}

public struct ScanResult: Sendable {
    public let root: FileNode
    public let volumeSummary: VolumeSummary?
    public let totalFilesScanned: Int
    public let totalDirectoriesScanned: Int
    public let inaccessibleCount: Int
    public let sampleInaccessiblePaths: [String]
    public let excludedCount: Int
    public let sampleExcludedPaths: [String]
    public let durationSeconds: TimeInterval

    public init(
        root: FileNode,
        volumeSummary: VolumeSummary?,
        totalFilesScanned: Int,
        totalDirectoriesScanned: Int,
        inaccessibleCount: Int,
        sampleInaccessiblePaths: [String],
        excludedCount: Int = 0,
        sampleExcludedPaths: [String] = [],
        durationSeconds: TimeInterval
    ) {
        self.root = root
        self.volumeSummary = volumeSummary
        self.totalFilesScanned = totalFilesScanned
        self.totalDirectoriesScanned = totalDirectoriesScanned
        self.inaccessibleCount = inaccessibleCount
        self.sampleInaccessiblePaths = sampleInaccessiblePaths
        self.excludedCount = excludedCount
        self.sampleExcludedPaths = sampleExcludedPaths
        self.durationSeconds = durationSeconds
    }
}

public enum DiskScannerError: LocalizedError, Sendable {
    case targetDoesNotExist(String)
    case permissionDenied(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .targetDoesNotExist(let p):
            return "The folder '\(p)' does not exist or could not be accessed."
        case .permissionDenied(let p):
            return "Permission denied when opening '\(p)'. Grant Full Disk Access in System Settings > Privacy & Security if needed."
        case .cancelled:
            return "Scan cancelled."
        }
    }
}

private struct InodeKey: Hashable {
    let dev: dev_t
    let ino: ino_t
}

/// Sharded hard-link deduplication table and progress accumulator shared across parallel worker tasks.
private final class ScanCoordinatorState: @unchecked Sendable {
    private static let shardCount = 16
    private let inodeLocks: [NSLock] = (0..<shardCount).map { _ in NSLock() }
    private var seenHardLinks: [Set<InodeKey>] = (0..<shardCount).map { _ in Set<InodeKey>(minimumCapacity: 256) }

    private let stateLock = NSLock()
    private var nextIDCounter: UInt64 = 1
    private var filesScanned: Int = 0
    private var directoriesScanned: Int = 0
    private var allocatedBytesFound: Int64 = 0
    private var latestPath: String = ""
    private var inaccessibleCount: Int = 0
    private var sampleInaccessible: [String] = []
    private var excludedCount: Int = 0
    private var sampleExcluded: [String] = []
    private var lastReportedTime: CFAbsoluteTime = 0

    let startTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    let allowedDevs: Set<dev_t>
    let skipExactPaths: Set<String>
    let exclusionMatcher: CompiledExclusionMatcher
    let registry: FileKindRegistry
    let onProgress: (@Sendable (ScanProgress) -> Void)?

    init(
        allowedDevs: Set<dev_t>,
        skipExactPaths: Set<String>,
        exclusionMatcher: CompiledExclusionMatcher,
        registry: FileKindRegistry,
        onProgress: (@Sendable (ScanProgress) -> Void)?
    ) {
        self.allowedDevs = allowedDevs
        self.skipExactPaths = skipExactPaths
        self.exclusionMatcher = exclusionMatcher
        self.registry = registry
        self.onProgress = onProgress
    }

    /// Allocates a contiguous block of unique node IDs so workers rarely lock.
    func allocateIDRange(count: UInt64 = 256) -> UInt64 {
        stateLock.lock()
        let base = nextIDCounter
        nextIDCounter &+= count
        stateLock.unlock()
        return base
    }

    /// Returns `true` if this is the FIRST time we have seen this hard-linked file inode.
    func registerHardLink(dev: dev_t, ino: ino_t) -> Bool {
        let shard = Int(UInt64(bitPattern: Int64(ino)) & UInt64(Self.shardCount - 1))
        inodeLocks[shard].lock()
        let inserted = seenHardLinks[shard].insert(InodeKey(dev: dev, ino: ino)).inserted
        inodeLocks[shard].unlock()
        return inserted
    }

    func recordInaccessible(path: String) {
        stateLock.lock()
        inaccessibleCount += 1
        if sampleInaccessible.count < 25 {
            sampleInaccessible.append(path)
        }
        stateLock.unlock()
    }

    func recordExcluded(path: String) {
        stateLock.lock()
        excludedCount += 1
        if sampleExcluded.count < 100 {
            sampleExcluded.append(path)
        }
        stateLock.unlock()
    }

    func addBatchProgress(files: Int, dirs: Int, bytes: Int64, currentPath: String, forceReport: Bool = false) {
        var progressToEmit: ScanProgress?
        let now = CFAbsoluteTimeGetCurrent()

        stateLock.lock()
        filesScanned += files
        directoriesScanned += dirs
        allocatedBytesFound += bytes
        if !currentPath.isEmpty {
            latestPath = currentPath
        }
        if forceReport || (now - lastReportedTime >= 0.06) {
            lastReportedTime = now
            progressToEmit = ScanProgress(
                filesScanned: filesScanned,
                directoriesScanned: directoriesScanned,
                allocatedBytesFound: allocatedBytesFound,
                currentPath: latestPath,
                elapsedSeconds: max(0, now - startTime)
            )
        }
        stateLock.unlock()

        if let progressToEmit, let onProgress {
            onProgress(progressToEmit)
        }
    }

    func snapshotTotals() -> (
        files: Int,
        dirs: Int,
        inaccessible: Int,
        samples: [String],
        excluded: Int,
        excludedSamples: [String],
        duration: TimeInterval
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (
            filesScanned,
            directoriesScanned,
            inaccessibleCount,
            sampleInaccessible,
            excludedCount,
            sampleExcluded,
            max(0.001, CFAbsoluteTimeGetCurrent() - startTime)
        )
    }
}

/// Per-worker ID generator backed by batch range allocation.
private struct WorkerIDAllocator {
    let state: ScanCoordinatorState
    var current: UInt64 = 0
    var end: UInt64 = 0

    mutating func nextID() -> UInt64 {
        if current >= end {
            current = state.allocateIDRange(count: 512)
            end = current &+ 512
        }
        let id = current
        current &+= 1
        return id
    }
}

private struct RawChildEntry {
    let name: String
    let st: stat
}

public final class DiskScanner: Sendable {
    private static let datalessFlagMask: UInt32 = 0x40000000 // SF_DATALESS on Darwin

    public init() {}

    public func scan(
        url targetURL: URL,
        sortMetric: SizeMetric = .allocated,
        exclusions: ScanExclusionConfig = ScanExclusionConfig(),
        registry: FileKindRegistry = .shared,
        onProgress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> ScanResult {
        let standardizedURL = targetURL.standardizedFileURL
        let rootPath = standardizedURL.path

        var rootStat = stat()
        guard lstat(rootPath, &rootStat) == 0 else {
            if errno == EACCES || errno == EPERM {
                throw DiskScannerError.permissionDenied(rootPath)
            }
            throw DiskScannerError.targetDoesNotExist(rootPath)
        }

        // Determine allowed device IDs and synthetic/duplicate mount paths to skip
        var allowedDevs: Set<dev_t> = [rootStat.st_dev]
        var sysRootStat = stat()
        var dataVolStat = stat()
        let hasSysRoot = stat("/", &sysRootStat) == 0
        let hasDataVol = stat("/System/Volumes/Data", &dataVolStat) == 0

        if hasSysRoot && hasDataVol {
            if rootStat.st_dev == sysRootStat.st_dev || rootStat.st_dev == dataVolStat.st_dev {
                // Allow crossing standard APFS firmlinks between System and Data volumes
                allowedDevs.insert(sysRootStat.st_dev)
                allowedDevs.insert(dataVolStat.st_dev)
            }
        }

        var skipExactPaths: Set<String> = ["/dev", "/.vol"]
        if !rootPath.hasPrefix("/System/Volumes/") {
            // Avoid double-counting Data volume via /System/Volumes/Data when scanning / or firmlinked trees
            skipExactPaths.insert("/System/Volumes")
            skipExactPaths.insert("/System/Volumes/Data")
        }
        if !rootPath.hasPrefix("/Volumes/") && rootPath != "/Volumes" {
            // Avoid traversing external disks / mounted DMGs when scanning "/"
            skipExactPaths.insert("/Volumes")
        }

        let volumes = VolumeSummary.mountedVolumes()
        let matchingVolume = Self.matchingVolume(for: rootPath, in: volumes)

        let rootDisplayName: String
        if rootPath == "/" {
            rootDisplayName = matchingVolume?.name ?? "Macintosh HD"
        } else {
            let last = standardizedURL.lastPathComponent
            rootDisplayName = last.isEmpty ? rootPath : last
        }

        let exclusionMatcher = CompiledExclusionMatcher(config: exclusions, scanRootPath: rootPath)

        let coordinator = ScanCoordinatorState(
            allowedDevs: allowedDevs,
            skipExactPaths: skipExactPaths,
            exclusionMatcher: exclusionMatcher,
            registry: registry,
            onProgress: onProgress
        )

        var mainIDGen = WorkerIDAllocator(state: coordinator)
        let isRootPkg = FileKindRegistry.isPackageDirectory(name: rootDisplayName)
        let rootNode = FileNode(
            id: mainIDGen.nextID(),
            name: rootDisplayName,
            explicitPath: rootPath,
            allocatedSize: 0,
            logicalSize: 0,
            fileCount: 0,
            modificationTime: Int64(rootStat.st_mtimespec.tv_sec),
            kindID: registry.classify(name: rootDisplayName, isDirectory: true, isPackage: isRootPkg),
            flags: isRootPkg ? [.isDirectory, .isPackage] : [.isDirectory]
        )

        if (rootStat.st_mode & S_IFMT) != S_IFDIR {
            let alloc = Int64(rootStat.st_blocks) * 512
            let logical = Int64(rootStat.st_size)
            let fileNode = FileNode(
                id: rootNode.id,
                name: rootDisplayName,
                explicitPath: rootPath,
                allocatedSize: alloc,
                logicalSize: logical,
                fileCount: 1,
                modificationTime: Int64(rootStat.st_mtimespec.tv_sec),
                kindID: registry.classify(name: rootDisplayName, isDirectory: false, isPackage: false),
                flags: []
            )
            return ScanResult(
                root: fileNode,
                volumeSummary: matchingVolume,
                totalFilesScanned: 1,
                totalDirectoriesScanned: 0,
                inaccessibleCount: 0,
                sampleInaccessiblePaths: [],
                durationSeconds: 0.001
            )
        }

        try Task.checkCancellation()

        // Expand top 2 directory levels to generate fine-grained subtree tasks for multi-core scanning
        var deferredSubtrees: [(node: FileNode, path: String)] = []
        try Self.expandShallowLevels(
            node: rootNode,
            path: rootPath,
            currentDepth: 0,
            maxShallowDepth: 2,
            idGen: &mainIDGen,
            coordinator: coordinator,
            deferredSubtrees: &deferredSubtrees
        )

        // Sort larger/deeper likely candidates or shuffle slightly; process via bounded worker pool
        let maxConcurrency = min(12, max(4, ProcessInfo.processInfo.activeProcessorCount))

        if !deferredSubtrees.isEmpty {
            try await withThrowingTaskGroup(of: Void.self) { group in
                var nextIdx = 0
                let initialBatch = min(maxConcurrency, deferredSubtrees.count)
                for _ in 0..<initialBatch {
                    let item = deferredSubtrees[nextIdx]
                    nextIdx += 1
                    group.addTask {
                        try Task.checkCancellation()
                        try Self.scanSubtreeSync(node: item.node, path: item.path, coordinator: coordinator)
                    }
                }

                while try await group.next() != nil {
                    try Task.checkCancellation()
                    if nextIdx < deferredSubtrees.count {
                        let item = deferredSubtrees[nextIdx]
                        nextIdx += 1
                        group.addTask {
                            try Task.checkCancellation()
                            try Self.scanSubtreeSync(node: item.node, path: item.path, coordinator: coordinator)
                        }
                    }
                }
            }
        }

        try Task.checkCancellation()

        // Reconcile shallow directory totals bottom-up and sort children by size descending
        Self.recomputeShallowTotals(node: rootNode, currentDepth: 0, maxShallowDepth: 2)
        rootNode.sortChildrenRecursively(by: sortMetric)

        coordinator.addBatchProgress(files: 0, dirs: 0, bytes: 0, currentPath: rootPath, forceReport: true)
        let summary = coordinator.snapshotTotals()

        return ScanResult(
            root: rootNode,
            volumeSummary: matchingVolume,
            totalFilesScanned: summary.files,
            totalDirectoriesScanned: summary.dirs,
            inaccessibleCount: summary.inaccessible,
            sampleInaccessiblePaths: summary.samples,
            excludedCount: summary.excluded,
            sampleExcludedPaths: summary.excludedSamples,
            durationSeconds: summary.duration
        )
    }

    private static func matchingVolume(for path: String, in volumes: [VolumeSummary]) -> VolumeSummary? {
        // Match longest volume mount prefix (e.g. "/Volumes/External" before "/")
        let sorted = volumes.sorted { $0.url.path.count > $1.url.path.count }
        for vol in sorted {
            let vPath = vol.url.path
            if vPath == "/" {
                return vol
            }
            if path == vPath || path.hasPrefix(vPath + "/") {
                return vol
            }
        }
        return volumes.first
    }

    /// Reads immediate directory entries using `open` + `fdopendir` + `fstatat` and closes the FD immediately
    /// before returning so file descriptors are never held open across recursion levels.
    private static func readDirectoryEntries(
        at path: String,
        node: FileNode,
        isRoot: Bool,
        coordinator: ScanCoordinatorState
    ) throws -> [RawChildEntry] {
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd < 0 {
            let err = errno
            if err == EACCES || err == EPERM {
                if isRoot {
                    throw DiskScannerError.permissionDenied(path)
                }
                node.flags.insert(.isInaccessible)
                coordinator.recordInaccessible(path: path)
                return []
            }
            return []
        }

        guard let dir = fdopendir(fd) else {
            Darwin.close(fd)
            return []
        }
        defer { closedir(dir) }

        var entries: [RawChildEntry] = []
        entries.reserveCapacity(32)

        while let dp = readdir(dir) {
            // Check "." and ".." directly on C bytes before allocating a Swift String
            let nameTuple = dp.pointee.d_name
            let isDotOrDotDot = withUnsafePointer(to: nameTuple) { ptr -> Bool in
                ptr.withMemoryRebound(to: CChar.self, capacity: 3) { cstr in
                    if cstr[0] == 0x2E { // '.'
                        if cstr[1] == 0 { return true }
                        if cstr[1] == 0x2E && cstr[2] == 0 { return true }
                    }
                    return false
                }
            }
            if isDotOrDotDot { continue }

            let name = withUnsafePointer(to: nameTuple) { ptr -> String in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(dp.pointee.d_namlen) + 1) { cstr in
                    String(cString: cstr)
                }
            }
            if name.isEmpty { continue }

            // Fast pre-stat check for directories (DT_DIR == 4) so excluded cloud mounts like
            // ~/Library/CloudStorage are never touched by fstatat/open at all!
            if dp.pointee.d_type == UInt8(DT_DIR) {
                let candidatePath = joinPath(path, name)
                if coordinator.skipExactPaths.contains(candidatePath) {
                    continue
                }
                if coordinator.exclusionMatcher.shouldExclude(directoryName: name, fullPath: candidatePath) {
                    coordinator.recordExcluded(path: candidatePath)
                    continue
                }
            }

            var st = stat()
            let statOK = name.withCString { cName in
                fstatat(fd, cName, &st, AT_SYMLINK_NOFOLLOW) == 0
            }
            guard statOK else { continue }

            if (st.st_mode & S_IFMT) == S_IFDIR && dp.pointee.d_type != UInt8(DT_DIR) {
                let candidatePath = joinPath(path, name)
                if coordinator.skipExactPaths.contains(candidatePath) {
                    continue
                }
                if coordinator.exclusionMatcher.shouldExclude(directoryName: name, fullPath: candidatePath) {
                    coordinator.recordExcluded(path: candidatePath)
                    continue
                }
            }

            entries.append(RawChildEntry(name: name, st: st))
        }

        return entries
    }

    private static func joinPath(_ parent: String, _ child: String) -> String {
        if parent == "/" {
            return "/" + child
        }
        return parent + "/" + child
    }

    /// Expands the first `maxShallowDepth` directory levels sequentially and collects deeper directories for parallel workers.
    private static func expandShallowLevels(
        node: FileNode,
        path: String,
        currentDepth: Int,
        maxShallowDepth: Int,
        idGen: inout WorkerIDAllocator,
        coordinator: ScanCoordinatorState,
        deferredSubtrees: inout [(node: FileNode, path: String)]
    ) throws {
        try Task.checkCancellation()
        let rawEntries = try readDirectoryEntries(at: path, node: node, isRoot: currentDepth == 0, coordinator: coordinator)
        coordinator.addBatchProgress(files: 0, dirs: 1, bytes: 0, currentPath: path)

        var childNodes: [FileNode] = []
        childNodes.reserveCapacity(rawEntries.count)

        var batchFiles = 0
        var batchBytes: Int64 = 0

        for entry in rawEntries {
            let childPath = joinPath(path, entry.name)
            if coordinator.skipExactPaths.contains(childPath) {
                continue
            }
            let mode = entry.st.st_mode & S_IFMT
            if mode == S_IFDIR {
                guard coordinator.allowedDevs.contains(entry.st.st_dev) else {
                    continue
                }
                let isPkg = FileKindRegistry.isPackageDirectory(name: entry.name)
                var flags: NodeFlags = [.isDirectory]
                if isPkg { flags.insert(.isPackage) }
                if entry.name.hasPrefix(".") { flags.insert(.isHidden) }

                let dirNode = FileNode(
                    id: idGen.nextID(),
                    name: entry.name,
                    parent: node,
                    modificationTime: Int64(entry.st.st_mtimespec.tv_sec),
                    kindID: coordinator.registry.classify(name: entry.name, isDirectory: true, isPackage: isPkg),
                    flags: flags
                )
                childNodes.append(dirNode)

                if currentDepth + 1 < maxShallowDepth {
                    try expandShallowLevels(
                        node: dirNode,
                        path: childPath,
                        currentDepth: currentDepth + 1,
                        maxShallowDepth: maxShallowDepth,
                        idGen: &idGen,
                        coordinator: coordinator,
                        deferredSubtrees: &deferredSubtrees
                    )
                } else {
                    deferredSubtrees.append((node: dirNode, path: childPath))
                }
            } else {
                let fileNode = buildLeafNode(entry: entry, parent: node, idGen: &idGen, coordinator: coordinator)
                childNodes.append(fileNode)
                batchFiles += 1
                batchBytes += fileNode.allocatedSize
            }
        }

        node.children = childNodes
        if batchFiles > 0 {
            coordinator.addBatchProgress(files: batchFiles, dirs: 0, bytes: batchBytes, currentPath: path)
        }
    }

    private static func recomputeShallowTotals(node: FileNode, currentDepth: Int, maxShallowDepth: Int) {
        var totalAlloc: Int64 = 0
        var totalLogical: Int64 = 0
        var totalFiles: Int = 0

        for child in node.children {
            if child.isDirectory && currentDepth + 1 < maxShallowDepth {
                recomputeShallowTotals(node: child, currentDepth: currentDepth + 1, maxShallowDepth: maxShallowDepth)
            }
            totalAlloc += child.allocatedSize
            totalLogical += child.logicalSize
            totalFiles += child.isDirectory ? child.fileCount : 1
        }

        node.allocatedSize = totalAlloc
        node.logicalSize = totalLogical
        node.fileCount = totalFiles
    }

    /// Scans an entire subtree iteratively/recursively on a single worker thread with zero locking per file.
    private static func scanSubtreeSync(
        node rootSubtreeNode: FileNode,
        path rootSubtreePath: String,
        coordinator: ScanCoordinatorState
    ) throws {
        var idGen = WorkerIDAllocator(state: coordinator)
        var pendingFiles = 0
        var pendingDirs = 0
        var pendingBytes: Int64 = 0

        func flushIfNeeded(path: String, force: Bool = false) throws {
            if force || pendingFiles + pendingDirs >= 512 {
                if Task.isCancelled {
                    throw DiskScannerError.cancelled
                }
                coordinator.addBatchProgress(
                    files: pendingFiles,
                    dirs: pendingDirs,
                    bytes: pendingBytes,
                    currentPath: path
                )
                pendingFiles = 0
                pendingDirs = 0
                pendingBytes = 0
            }
        }

        // Explicit stack frame for post-order accumulation without call-stack depth limits
        struct Frame {
            let node: FileNode
            let path: String
            var childDirsToVisit: [(FileNode, String)]
            var nextDirIndex: Int
        }

        func populateDirectory(node: FileNode, path: String) throws -> [(FileNode, String)] {
            let rawEntries = try readDirectoryEntries(at: path, node: node, isRoot: false, coordinator: coordinator)
            pendingDirs += 1
            try flushIfNeeded(path: path)

            var children: [FileNode] = []
            children.reserveCapacity(rawEntries.count)
            var subdirs: [(FileNode, String)] = []

            for entry in rawEntries {
                let mode = entry.st.st_mode & S_IFMT
                if mode == S_IFDIR {
                    let childPath = joinPath(path, entry.name)
                    if coordinator.skipExactPaths.contains(childPath) {
                        continue
                    }
                    guard coordinator.allowedDevs.contains(entry.st.st_dev) else {
                        continue
                    }
                    let isPkg = FileKindRegistry.isPackageDirectory(name: entry.name)
                    var flags: NodeFlags = [.isDirectory]
                    if isPkg { flags.insert(.isPackage) }
                    if entry.name.hasPrefix(".") { flags.insert(.isHidden) }

                    let dirNode = FileNode(
                        id: idGen.nextID(),
                        name: entry.name,
                        parent: node,
                        modificationTime: Int64(entry.st.st_mtimespec.tv_sec),
                        kindID: coordinator.registry.classify(name: entry.name, isDirectory: true, isPackage: isPkg),
                        flags: flags
                    )
                    children.append(dirNode)
                    subdirs.append((dirNode, childPath))
                } else {
                    let leaf = buildLeafNode(entry: entry, parent: node, idGen: &idGen, coordinator: coordinator)
                    children.append(leaf)
                    pendingFiles += 1
                    pendingBytes += leaf.allocatedSize
                }
            }

            node.children = children
            try flushIfNeeded(path: path)
            return subdirs
        }

        let initialSubdirs = try populateDirectory(node: rootSubtreeNode, path: rootSubtreePath)
        var stack: [Frame] = [Frame(node: rootSubtreeNode, path: rootSubtreePath, childDirsToVisit: initialSubdirs, nextDirIndex: 0)]

        while var top = stack.popLast() {
            if top.nextDirIndex < top.childDirsToVisit.count {
                let (nextNode, nextPath) = top.childDirsToVisit[top.nextDirIndex]
                top.nextDirIndex += 1
                stack.append(top)

                let grandSubdirs = try populateDirectory(node: nextNode, path: nextPath)
                stack.append(Frame(node: nextNode, path: nextPath, childDirsToVisit: grandSubdirs, nextDirIndex: 0))
            } else {
                // All children of `top.node` are populated; sum sizes now
                var sumAlloc: Int64 = 0
                var sumLogical: Int64 = 0
                var sumFiles: Int = 0
                for child in top.node.children {
                    sumAlloc += child.allocatedSize
                    sumLogical += child.logicalSize
                    sumFiles += child.isDirectory ? child.fileCount : 1
                }
                top.node.allocatedSize = sumAlloc
                top.node.logicalSize = sumLogical
                top.node.fileCount = sumFiles
            }
        }

        try flushIfNeeded(path: rootSubtreePath, force: true)
    }

    private static func buildLeafNode(
        entry: RawChildEntry,
        parent: FileNode,
        idGen: inout WorkerIDAllocator,
        coordinator: ScanCoordinatorState
    ) -> FileNode {
        let mode = entry.st.st_mode & S_IFMT
        var flags: NodeFlags = []
        if mode == S_IFLNK {
            flags.insert(.isSymlink)
        }
        if (entry.st.st_flags & datalessFlagMask) != 0 {
            flags.insert(.isDataless)
        }
        if entry.name.hasPrefix(".") {
            flags.insert(.isHidden)
        }

        var allocSize = Int64(entry.st.st_blocks) * 512
        let logicalSize = Int64(entry.st.st_size)

        // Deduplicate hard-linked regular files (e.g., Homebrew / git / Xcode toolchains)
        if mode == S_IFREG && entry.st.st_nlink > 1 && allocSize > 0 {
            let isFirst = coordinator.registerHardLink(dev: entry.st.st_dev, ino: entry.st.st_ino)
            if !isFirst {
                allocSize = 0
                flags.insert(.isHardLinkDuplicate)
            }
        }

        let kindID = coordinator.registry.classify(name: entry.name, isDirectory: false, isPackage: false)
        return FileNode(
            id: idGen.nextID(),
            name: entry.name,
            parent: parent,
            allocatedSize: allocSize,
            logicalSize: logicalSize,
            fileCount: 1,
            modificationTime: Int64(entry.st.st_mtimespec.tv_sec),
            kindID: kindID,
            flags: flags
        )
    }
}

