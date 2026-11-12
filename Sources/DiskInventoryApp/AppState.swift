import Foundation
import AppKit
import Observation
import DiskInventoryCore

enum InspectorTab: String, CaseIterable, Identifiable {
    case kinds = "Kinds"
    case largest = "Largest"
    case info = "Info"

    var id: String { rawValue }
}

enum SizeFilterPreset: Int64, CaseIterable, Identifiable {
    case all = 0
    case mb50 = 50_000_000
    case mb250 = 250_000_000
    case gb1 = 1_000_000_000
    case gb5 = 5_000_000_000

    var id: Int64 { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .mb50: return "50 MB+"
        case .mb250: return "250 MB+"
        case .gb1: return "1 GB+"
        case .gb5: return "5 GB+"
        }
    }
}

struct VisibleTreeRow: Identifiable {
    enum RowKind {
        case node(FileNode)
        case showMore(parent: FileNode, hiddenCount: Int)
    }

    let id: String
    let kind: RowKind
    let depth: Int
    let shareOfParent: Double

    var node: FileNode? {
        if case .node(let n) = kind { return n }
        return nil
    }
}

@MainActor
@Observable
final class InventoryViewModel {
    enum ScreenPhase {
        case welcome
        case scanning(targetName: String, targetPath: String)
        case workspace
    }

    // MARK: - App Lifecycle & Volumes
    var phase: ScreenPhase = .welcome
    var volumes: [VolumeSummary] = []
    var scanProgress: ScanProgress = ScanProgress(
        filesScanned: 0,
        directoriesScanned: 0,
        allocatedBytesFound: 0,
        currentPath: "",
        elapsedSeconds: 0
    )

    // MARK: - Scan Data & Navigation
    var scanResult: ScanResult?
    var zoomRoot: FileNode?
    var selectedNode: FileNode?
    var hoveredLeaf: TreemapLeaf?

    // MARK: - Tree Virtualization & Scroll Sync
    var expandedNodeIDs: Set<UInt64> = []
    var unlimitedFolderIDs: Set<UInt64> = []
    var visibleTreeRows: [VisibleTreeRow] = []
    var scrollToRowID: String?
    var scrollTrigger: Int = 0

    // MARK: - View Options
    var sizeMetric: SizeMetric = .allocated {
        didSet {
            if oldValue != sizeMetric {
                handleViewOptionChange(resortTree: true)
            }
        }
    }
    var showPackageContents: Bool = false {
        didSet {
            if oldValue != showPackageContents {
                handleViewOptionChange(resortTree: false)
            }
        }
    }
    var useCushionShading: Bool = true
    var showFreeSpaceInTreemap: Bool = false
    var showGroupLabels: Bool = true
    var highlightedKindID: UInt16? {
        didSet {
            if oldValue != highlightedKindID {
                recomputeLargestItems()
            }
        }
    }

    // MARK: - Inspector & Search
    var inspectorTab: InspectorTab = .kinds
    var searchQuery: String = "" {
        didSet {
            if oldValue != searchQuery {
                recomputeLargestItems()
            }
        }
    }
    var sizeFilter: SizeFilterPreset = .all {
        didSet {
            if oldValue != sizeFilter {
                recomputeLargestItems()
            }
        }
    }

    var kindStatistics: [KindStatistic] = []
    var largestItems: [FileNode] = []
    var mutationRevision: Int = 0

    // MARK: - Exclusions
    private static let exclusionsStorageKey = "com.local.diskinventory.exclusions.v1"
    var exclusionConfig: ScanExclusionConfig = ScanExclusionConfig()
    var showExclusionsSheet: Bool = false
    var lastScanTargetURL: URL?

    // MARK: - Trash & Alerts
    var pendingTrashNodes: [FileNode] = []
    var showTrashConfirmation: Bool = false
    var alertTitle: String = ""
    var alertMessage: String = ""
    var showAlert: Bool = false
    var showInaccessibleSheet: Bool = false

    var sessionReclaimedBytes: Int64 = 0
    var sessionTrashedCount: Int = 0

    private var activeScanTask: Task<Void, Never>?
    private let scanner = DiskScanner()
    private static let folderChildrenInitialCap = 350

    init() {
        loadExclusions()
        refreshVolumes()
    }

    func refreshVolumes() {
        volumes = VolumeSummary.mountedVolumes()
    }

    // MARK: - Scanning

    func chooseFolderAndScan() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Volume or Folder to Analyze"
        panel.prompt = "Scan"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.showsHiddenFiles = false

        if panel.runModal() == .OK, let url = panel.url {
            startScan(url: url)
        }
    }

    func startScan(url: URL) {
        activeScanTask?.cancel()
        let standardized = url.standardizedFileURL
        self.lastScanTargetURL = standardized
        let displayName = standardized.path == "/"
            ? (volumes.first(where: { $0.url.path == "/" })?.name ?? "Macintosh HD")
            : standardized.lastPathComponent

        scanProgress = ScanProgress(
            filesScanned: 0,
            directoriesScanned: 0,
            allocatedBytesFound: 0,
            currentPath: standardized.path,
            elapsedSeconds: 0
        )
        phase = .scanning(targetName: displayName, targetPath: standardized.path)

        let metric = self.sizeMetric
        let exclusionsSnapshot = self.exclusionConfig
        let scannerRef = self.scanner
        let progressCallback: @Sendable (ScanProgress) -> Void = { [weak self] prog in
            Task { @MainActor in
                guard let self, case .scanning = self.phase else { return }
                self.scanProgress = prog
            }
        }

        activeScanTask = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try await scannerRef.scan(
                        url: standardized,
                        sortMetric: metric,
                        exclusions: exclusionsSnapshot,
                        onProgress: progressCallback
                    )
                }.value

                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.applyCompletedScan(result)
            } catch is CancellationError {
                self?.returnToWelcomeOrWorkspace()
            } catch DiskScannerError.cancelled {
                self?.returnToWelcomeOrWorkspace()
            } catch {
                guard let self else { return }
                self.returnToWelcomeOrWorkspace()
                self.presentAlert(title: "Could Not Complete Scan", message: error.localizedDescription)
            }
        }
    }

    func rescanCurrentRoot() {
        guard let root = scanResult?.root else { return }
        startScan(url: root.url)
    }

    func restartLastScan() {
        if let target = lastScanTargetURL ?? scanResult?.root.url {
            startScan(url: target)
        }
    }

    func cancelScan() {
        activeScanTask?.cancel()
        activeScanTask = nil
        returnToWelcomeOrWorkspace()
    }

    func showWelcomePicker() {
        refreshVolumes()
        phase = .welcome
    }

    private func returnToWelcomeOrWorkspace() {
        if scanResult != nil {
            phase = .workspace
        } else {
            refreshVolumes()
            phase = .welcome
        }
    }

    private func applyCompletedScan(_ result: ScanResult) {
        self.scanResult = result
        self.zoomRoot = result.root
        self.selectedNode = result.root
        self.hoveredLeaf = nil
        self.highlightedKindID = nil
        self.expandedNodeIDs = [result.root.id]
        self.unlimitedFolderIDs = []
        self.mutationRevision &+= 1
        self.refreshVolumes()
        self.recomputeAllDerivedViews()
        self.phase = .workspace
    }

    // MARK: - Navigation & Selection Sync

    var breadcrumbs: [FileNode] {
        guard let scanRoot = scanResult?.root, let zoomRoot else { return [] }
        return zoomRoot.ancestorChain(from: scanRoot)
    }

    var canZoomOut: Bool {
        guard let scanRoot = scanResult?.root, let zoomRoot else { return false }
        return zoomRoot !== scanRoot && zoomRoot.parent != nil
    }

    var canZoomIntoSelection: Bool {
        guard let selected = selectedNode, let zoomRoot else { return false }
        return selected.isDirectory && selected !== zoomRoot && !selected.children.isEmpty
    }

    func zoomIn(to target: FileNode) {
        guard target.isDirectory else {
            if let parent = target.parent, parent !== zoomRoot {
                zoomIn(to: parent)
            }
            return
        }
        zoomRoot = target
        expandedNodeIDs.insert(target.id)
        hoveredLeaf = nil
        if let selected = selectedNode, !selected.isDescendant(of: target) && selected !== target {
            selectedNode = target
        }
        mutationRevision &+= 1
        recomputeAllDerivedViews()
    }

    func zoomOut() {
        guard let scanRoot = scanResult?.root, let current = zoomRoot, current !== scanRoot else { return }
        if let parent = current.parent {
            zoomRoot = parent
            selectedNode = current
            hoveredLeaf = nil
            mutationRevision &+= 1
            recomputeAllDerivedViews()
            revealNodeInTree(current)
        }
    }

    func zoomToBreadcrumb(_ ancestor: FileNode) {
        guard ancestor !== zoomRoot else { return }
        zoomRoot = ancestor
        hoveredLeaf = nil
        if let selected = selectedNode, !selected.isDescendant(of: ancestor) && selected !== ancestor {
            selectedNode = ancestor
        }
        mutationRevision &+= 1
        recomputeAllDerivedViews()
    }

    func selectNode(_ node: FileNode?, revealInTree: Bool = false) {
        selectedNode = node
        if let node {
            QuickLookController.shared.refreshIfVisible(with: node.url)
            if revealInTree {
                revealNodeInTree(node)
            }
        }
    }

    func selectParentOfSelection() {
        guard let current = selectedNode, let zoomRoot else { return }
        guard current !== zoomRoot, let parent = current.parent else { return }
        selectNode(parent, revealInTree: true)
    }

    func toggleExpanded(_ folder: FileNode) {
        if expandedNodeIDs.contains(folder.id) {
            expandedNodeIDs.remove(folder.id)
        } else {
            expandedNodeIDs.insert(folder.id)
        }
        rebuildVisibleTreeRows()
    }

    func showAllChildren(of folder: FileNode) {
        unlimitedFolderIDs.insert(folder.id)
        rebuildVisibleTreeRows()
    }

    func revealNodeInTree(_ target: FileNode) {
        guard let root = zoomRoot else { return }
        // Expand every ancestor from zoomRoot down to target.parent
        let chain = target.ancestorChain(from: root)
        var changed = false
        for anc in chain.dropLast() {
            if expandedNodeIDs.insert(anc.id).inserted {
                changed = true
            }
            // If target is beyond initial cap inside `anc`, unlock `anc` so target row is visible
            if !unlimitedFolderIDs.contains(anc.id),
               anc.children.count > Self.folderChildrenInitialCap,
               let idx = anc.children.firstIndex(where: { $0.id == target.id || target.isDescendant(of: $0) }),
               idx >= Self.folderChildrenInitialCap {
                unlimitedFolderIDs.insert(anc.id)
                changed = true
            }
        }
        if changed {
            rebuildVisibleTreeRows()
        }
        scrollToRowID = "node-\(target.id)"
        scrollTrigger &+= 1
    }

    func toggleKindHighlight(_ kindID: UInt16) {
        if highlightedKindID == kindID {
            highlightedKindID = nil
        } else {
            highlightedKindID = kindID
        }
    }

    // MARK: - Derived State Recomputation

    private func handleViewOptionChange(resortTree: Bool) {
        if resortTree, let scanRoot = scanResult?.root {
            scanRoot.sortChildrenRecursively(by: sizeMetric)
        }
        mutationRevision &+= 1
        recomputeAllDerivedViews()
    }

    func recomputeAllDerivedViews() {
        rebuildVisibleTreeRows()
        recomputeKindStats()
        recomputeLargestItems()
    }

    func rebuildVisibleTreeRows() {
        guard let root = zoomRoot else {
            visibleTreeRows = []
            return
        }

        var rows: [VisibleTreeRow] = []
        rows.reserveCapacity(512)

        func appendNode(_ node: FileNode, depth: Int, parentBytes: Int64) {
            let sz = node.size(for: sizeMetric)
            let share = parentBytes > 0 ? min(1.0, max(0.0, Double(sz) / Double(parentBytes))) : 1.0
            rows.append(
                VisibleTreeRow(
                    id: "node-\(node.id)",
                    kind: .node(node),
                    depth: depth,
                    shareOfParent: depth == 0 ? 1.0 : share
                )
            )

            let canExpandChildren = node.isDirectory && !node.children.isEmpty &&
                (showPackageContents || !node.isPackage || node === root || expandedNodeIDs.contains(node.id))

            if canExpandChildren && expandedNodeIDs.contains(node.id) {
                let totalChildren = node.children.count
                let isUnlimited = unlimitedFolderIDs.contains(node.id)
                let limit = isUnlimited ? totalChildren : min(totalChildren, Self.folderChildrenInitialCap)
                let denom = max(1, sz)

                for i in 0..<limit {
                    appendNode(node.children[i], depth: depth + 1, parentBytes: denom)
                }

                if limit < totalChildren {
                    rows.append(
                        VisibleTreeRow(
                            id: "more-\(node.id)",
                            kind: .showMore(parent: node, hiddenCount: totalChildren - limit),
                            depth: depth + 1,
                            shareOfParent: 0
                        )
                    )
                }
            }
        }

        appendNode(root, depth: 0, parentBytes: root.size(for: sizeMetric))
        visibleTreeRows = rows
    }

    private func recomputeKindStats() {
        guard let root = zoomRoot else {
            kindStatistics = []
            return
        }
        kindStatistics = root.collectKindStatistics(
            metric: sizeMetric,
            showPackageContents: showPackageContents
        )
    }

    private func recomputeLargestItems() {
        guard let root = zoomRoot else {
            largestItems = []
            return
        }
        largestItems = root.collectLargestItems(
            limit: 250,
            minBytes: sizeFilter.rawValue,
            metric: sizeMetric,
            showPackageContents: showPackageContents,
            searchQuery: searchQuery,
            kindFilter: highlightedKindID
        )
    }

    var effectiveFreeSpaceForTreemap: Int64 {
        guard showFreeSpaceInTreemap,
              let scanRoot = scanResult?.root,
              let zoomRoot,
              zoomRoot === scanRoot,
              let vol = scanResult?.volumeSummary,
              scanRoot.path == vol.url.path else {
            return 0
        }
        return vol.availableBytes
    }

    // MARK: - File Actions (Finder, Quick Look, Safe Trash)

    func revealInFinder(_ node: FileNode? = nil) {
        guard let target = node ?? selectedNode else { return }
        NSWorkspace.shared.activateFileViewerSelecting([target.url])
    }

    func openInDefaultApp(_ node: FileNode? = nil) {
        guard let target = node ?? selectedNode else { return }
        NSWorkspace.shared.open(target.url)
    }

    func toggleQuickLook(_ node: FileNode? = nil) {
        guard let target = node ?? selectedNode else { return }
        QuickLookController.shared.togglePreview(for: target.url)
    }

    func copyPathToClipboard(_ node: FileNode? = nil) {
        guard let target = node ?? selectedNode else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(target.path, forType: .string)
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func openUserTrashInFinder() {
        if let trashURL = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first {
            NSWorkspace.shared.open(trashURL)
        }
    }

    func requestMoveToTrash(_ node: FileNode? = nil) {
        guard let target = node ?? selectedNode else { return }
        requestMoveMultipleToTrash([target])
    }

    func requestMoveMultipleToTrash(_ candidates: [FileNode]) {
        let deduped = deduplicateTopLevelNodes(candidates)
        guard !deduped.isEmpty else { return }

        let scanRoot = scanResult?.root
        for item in deduped {
            let safety = item.evaluateDeletionSafety(scanRoot: scanRoot)
            if case .protectedSystemPath(let reason) = safety {
                presentAlert(title: "Protected Item Cannot Be Trashed", message: reason)
                return
            }
        }

        pendingTrashNodes = deduped
        showTrashConfirmation = true
    }

    func confirmMovePendingToTrash() {
        let targets = pendingTrashNodes
        pendingTrashNodes = []
        showTrashConfirmation = false
        guard !targets.isEmpty else { return }

        var trashedBytes: Int64 = 0
        var trashedItems = 0
        var failedMessages: [String] = []

        for node in targets {
            let fallbackSelection = node.parent ?? zoomRoot
            let bytes = node.allocatedSize

            do {
                try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
                if zoomRoot === node {
                    zoomRoot = node.parent ?? scanResult?.root
                }
                if let sel = selectedNode, (sel === node || sel.isDescendant(of: node)) {
                    selectedNode = fallbackSelection
                }
                if let hov = hoveredLeaf?.node, (hov === node || hov.isDescendant(of: node)) {
                    hoveredLeaf = nil
                }
                node.detachAndSubtractFromAncestors()
                trashedBytes += bytes
                trashedItems += 1
            } catch {
                failedMessages.append("\(node.name): \(error.localizedDescription)")
            }
        }

        if trashedItems > 0 {
            sessionReclaimedBytes += trashedBytes
            sessionTrashedCount += trashedItems
            mutationRevision &+= 1
            refreshVolumes()
            recomputeAllDerivedViews()
        }

        if !failedMessages.isEmpty {
            presentAlert(
                title: "Some Items Could Not Be Moved to Trash",
                message: failedMessages.joined(separator: "\n")
            )
        }
    }

    private func presentAlert(title: String, message: String) {
        self.alertTitle = title
        self.alertMessage = message
        self.showAlert = true
    }

    // MARK: - Exclusion Management & Persistence

    private func loadExclusions() {
        if let data = UserDefaults.standard.data(forKey: Self.exclusionsStorageKey),
           let decoded = try? JSONDecoder().decode(ScanExclusionConfig.self, from: data) {
            self.exclusionConfig = decoded.mergedWithDefaults()
        } else {
            self.exclusionConfig = ScanExclusionConfig.init()
        }
    }

    private func persistExclusions() {
        if let data = try? JSONEncoder().encode(exclusionConfig) {
            UserDefaults.standard.set(data, forKey: Self.exclusionsStorageKey)
        }
    }

    func toggleExclusionRule(id: String) {
        guard let idx = exclusionConfig.rules.firstIndex(where: { $0.id == id }) else { return }
        exclusionConfig.rules[idx].isEnabled.toggle()
        persistExclusions()
    }

    func addExcludedFoldersViaPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose Folder(s) to Exclude from Scans"
        panel.prompt = "Exclude"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

        if panel.runModal() == .OK {
            for url in panel.urls {
                exclusionConfig.addCustomPath(url.standardizedFileURL.path)
            }
            persistExclusions()
        }
    }

    func addExcludedFolderName(_ name: String) {
        exclusionConfig.addCustomFolderName(name)
        persistExclusions()
    }

    func removeCustomExclusionRule(id: String) {
        exclusionConfig.rules.removeAll { $0.id == id && !$0.isBuiltIn }
        persistExclusions()
    }

    func resetExclusionsToDefaults() {
        exclusionConfig = ScanExclusionConfig()
        persistExclusions()
    }

    /// Adds a directory node to Exclusions and immediately removes it from the active in-memory scan view.
    func excludeFolderAndRemoveFromView(_ node: FileNode) {
        guard node.isDirectory, node !== scanResult?.root else { return }
        exclusionConfig.addCustomPath(node.path)
        persistExclusions()

        let fallback = node.parent ?? zoomRoot
        if zoomRoot === node {
            zoomRoot = node.parent ?? scanResult?.root
        }
        if let sel = selectedNode, (sel === node || sel.isDescendant(of: node)) {
            selectedNode = fallback
        }
        if let hov = hoveredLeaf?.node, (hov === node || hov.isDescendant(of: node)) {
            hoveredLeaf = nil
        }
        node.detachAndSubtractFromAncestors()
        mutationRevision &+= 1
        recomputeAllDerivedViews()
    }
}
