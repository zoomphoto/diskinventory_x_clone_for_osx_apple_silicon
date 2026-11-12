import SwiftUI
import AppKit
import DiskInventoryCore

struct TreemapCanvasPane: View {
    @Bindable var viewModel: InventoryViewModel
    @Environment(\.displayScale) private var displayScale

    @State private var currentLayout: TreemapLayout?
    @State private var currentImage: CGImage?
    @State private var renderTask: Task<Void, Never>?

    private struct RenderKey: Equatable {
        let rootID: UInt64
        let width: Int
        let height: Int
        let scale: CGFloat
        let metric: SizeMetric
        let showPkg: Bool
        let cushion: Bool
        let freeBytes: Int64
        let highlightedKind: UInt16?
        let revision: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let size = geo.size
                let key = RenderKey(
                    rootID: viewModel.zoomRoot?.id ?? 0,
                    width: max(0, Int(size.width.rounded())),
                    height: max(0, Int(size.height.rounded())),
                    scale: displayScale,
                    metric: viewModel.sizeMetric,
                    showPkg: viewModel.showPackageContents,
                    cushion: viewModel.useCushionShading,
                    freeBytes: viewModel.effectiveFreeSpaceForTreemap,
                    highlightedKind: viewModel.highlightedKindID,
                    revision: viewModel.mutationRevision
                )

                ZStack(alignment: .topLeading) {
                    Color(red: 0.10, green: 0.11, blue: 0.13)

                    if let cgImage = currentImage {
                        Image(decorative: cgImage, scale: displayScale, orientation: .up)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: size.width, height: size.height)
                    } else if let root = viewModel.zoomRoot, root.size(for: viewModel.sizeMetric) == 0 {
                        emptyFolderOverlay
                    }

                    if let layout = currentLayout {
                        overlayAnnotations(layout: layout)
                            .allowsHitTesting(false)

                        TreemapMouseInteractionOverlay(
                            layout: layout,
                            viewModel: viewModel
                        )
                        .frame(width: size.width, height: size.height)
                    }
                }
                .clipped()
                .onChange(of: key, initial: true) { _, newKey in
                    scheduleRender(for: newKey)
                }
            }

            Divider()
            statusFooterBar
        }
    }

    private var emptyFolderOverlay: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No Disk Blocks Allocated in This Folder")
                .font(.headline)
                .foregroundStyle(.secondary)
            if viewModel.sizeMetric == .allocated {
                Text("Switch to Logical Size if this folder only contains cloud-evicted files.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func overlayAnnotations(layout: TreemapLayout) -> some View {
        ZStack(alignment: .topLeading) {
            // 1. Subtle directory headers on major top-level regions
            if viewModel.showGroupLabels {
                ForEach(Array(layout.topLevelFrames.enumerated()), id: \.offset) { _, frame in
                    if frame.depth == 0 {
                        // Subtle thin dark border around top-level branches
                        Rectangle()
                            .strokeBorder(Color.black.opacity(0.38), lineWidth: 1)
                            .frame(width: frame.rect.width, height: frame.rect.height)
                            .offset(x: frame.rect.minX, y: frame.rect.minY)

                        if frame.rect.width >= 92 && frame.rect.height >= 42 {
                            let labelText = "\(frame.node.name)  \(ByteFormatting.format(frame.node.size(for: viewModel.sizeMetric)))"
                            Text(labelText)
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.95))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .frame(maxWidth: max(0, frame.rect.width - 8), alignment: .leading)
                                .offset(x: frame.rect.minX + 4, y: frame.rect.minY + 4)
                        }
                    }
                }
            }

            // 2. Hovered branch & leaf highlight
            if let hovered = viewModel.hoveredLeaf {
                if let branch = hovered.topBranchNode,
                   let branchRect = layout.rect(for: branch),
                   branchRect != hovered.rect {
                    Rectangle()
                        .strokeBorder(
                            Color.white.opacity(0.45),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                        .frame(width: branchRect.width, height: branchRect.height)
                        .offset(x: branchRect.minX, y: branchRect.minY)
                }

                Rectangle()
                    .strokeBorder(Color.white.opacity(0.92), lineWidth: 1.5)
                    .frame(width: max(2, hovered.rect.width), height: max(2, hovered.rect.height))
                    .offset(x: hovered.rect.minX, y: hovered.rect.minY)
            }

            // 3. Selected file or directory highlight (high-contrast double frame)
            if let selected = viewModel.selectedNode,
               selected !== layout.rootNode,
               let selRect = layout.rect(for: selected) {
                ZStack {
                    Rectangle()
                        .strokeBorder(Color.black.opacity(0.88), lineWidth: 3.5)
                    Rectangle()
                        .strokeBorder(Color(red: 1.0, green: 0.92, blue: 0.28), lineWidth: 2.0)
                        .padding(1)
                }
                .frame(width: max(4, selRect.width), height: max(4, selRect.height))
                .offset(x: selRect.minX, y: selRect.minY)
            }
        }
    }

    private var statusFooterBar: some View {
        HStack(spacing: 10) {
            if let hovered = viewModel.hoveredLeaf {
                if hovered.isFreeSpace {
                    Circle()
                        .fill(Color.gray)
                        .frame(width: 9, height: 9)
                    Text("Free Space on Volume")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Text(ByteFormatting.format(hovered.bytes))
                        .font(.caption.monospacedDigit().weight(.semibold))
                } else if let node = hovered.node {
                    let kind = FileKindRegistry.shared.kind(for: hovered.kindID)
                    Circle()
                        .fill(kind.color.swiftUIColor)
                        .frame(width: 9, height: 9)
                    Text(node.path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(kind.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("•")
                        .foregroundStyle(.tertiary)
                    Text(ByteFormatting.format(node.size(for: viewModel.sizeMetric)))
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
            } else if let selected = viewModel.selectedNode {
                let kind = FileKindRegistry.shared.kind(for: selected.kindID)
                Circle()
                    .fill(selected.isDirectory && !selected.isPackage ? Color.accentColor : kind.color.swiftUIColor)
                    .frame(width: 9, height: 9)
                Text(selected.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text("Click: Select  •  Double-Click: Zoom In  •  Right-Click: Actions")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(ByteFormatting.format(selected.size(for: viewModel.sizeMetric)))
                    .font(.caption.monospacedDigit().weight(.semibold))
            } else {
                Text("Hover over any cushion to inspect file path and size.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func scheduleRender(for key: RenderKey) {
        renderTask?.cancel()
        guard let root = viewModel.zoomRoot, key.width >= 4, key.height >= 4 else {
            currentLayout = nil
            currentImage = nil
            return
        }

        let bounds = CGRect(x: 0, y: 0, width: CGFloat(key.width), height: CGFloat(key.height))
        renderTask = Task {
            let output = await Task.detached(priority: .userInitiated) { () -> (TreemapLayout, CGImage?)? in
                if Task.isCancelled { return nil }
                let layout = CushionTreemapEngine.buildLayout(
                    rootNode: root,
                    bounds: bounds,
                    metric: key.metric,
                    showPackageContents: key.showPkg,
                    freeSpaceBytes: key.freeBytes
                )
                if Task.isCancelled { return nil }
                let img = CushionTreemapEngine.renderImage(
                    layout: layout,
                    scale: key.scale,
                    useCushionShading: key.cushion,
                    highlightedKindID: key.highlightedKind
                )
                if Task.isCancelled { return nil }
                return (layout, img)
            }.value

            guard !Task.isCancelled, let (layout, img) = output else { return }
            self.currentLayout = layout
            self.currentImage = img
        }
    }
}

// MARK: - Native AppKit Zero-Latency Mouse & Context-Menu Overlay

private struct TreemapMouseInteractionOverlay: NSViewRepresentable {
    let layout: TreemapLayout
    let viewModel: InventoryViewModel

    func makeNSView(context: Context) -> TreemapInteractiveNSView {
        let view = TreemapInteractiveNSView()
        view.layoutModel = layout
        view.viewModel = viewModel
        return view
    }

    func updateNSView(_ nsView: TreemapInteractiveNSView, context: Context) {
        nsView.layoutModel = layout
        nsView.viewModel = viewModel
    }
}

@MainActor
private final class TreemapInteractiveNSView: NSView {
    var layoutModel: TreemapLayout?
    weak var viewModel: InventoryViewModel?
    private var trackingAreaRef: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    private func localPoint(from event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = localPoint(from: event)
        let hit = layoutModel?.hitTest(at: pt)
        if viewModel?.hoveredLeaf?.node !== hit?.node || viewModel?.hoveredLeaf?.isFreeSpace != hit?.isFreeSpace {
            viewModel?.hoveredLeaf = hit
        }
    }

    override func mouseExited(with event: NSEvent) {
        viewModel?.hoveredLeaf = nil
    }

    override func mouseDown(with event: NSEvent) {
        let pt = localPoint(from: event)
        guard let hit = layoutModel?.hitTest(at: pt), !hit.isFreeSpace, let node = hit.node else {
            return
        }

        if event.clickCount == 2 {
            // Double-click zooms into the enclosing top-level branch (classic Disk Inventory X navigation!)
            if let branch = hit.topBranchNode, branch.isDirectory {
                viewModel?.zoomIn(to: branch)
            } else if node.isDirectory {
                viewModel?.zoomIn(to: node)
            } else if let parent = node.parent, parent !== viewModel?.zoomRoot {
                viewModel?.zoomIn(to: parent)
            }
        } else {
            // Option-click selects the enclosing folder; normal click selects the exact file cushion
            if event.modifierFlags.contains(.option), let parent = node.parent {
                viewModel?.selectNode(parent, revealInTree: true)
            } else {
                viewModel?.selectNode(node, revealInTree: true)
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let pt = localPoint(from: event)
        guard let vm = viewModel,
              let hit = layoutModel?.hitTest(at: pt),
              !hit.isFreeSpace,
              let node = hit.node else {
            return nil
        }

        vm.selectNode(node, revealInTree: true)

        let menu = NSMenu(title: "Treemap Actions")
        let headerTitle = "\(node.name) (\(ByteFormatting.format(node.size(for: vm.sizeMetric))))"
        let headerItem = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(.separator())

        if let parent = node.parent, parent !== vm.zoomRoot {
            let selectParent = NSMenuItem(
                title: "Select Enclosing Folder “\(parent.name)”",
                action: #selector(handleSelectParent(_:)),
                keyEquivalent: ""
            )
            selectParent.target = self
            selectParent.representedObject = parent
            menu.addItem(selectParent)
        }

        if let branch = hit.topBranchNode, branch.isDirectory, branch !== vm.zoomRoot {
            let zoomBranch = NSMenuItem(
                title: "Zoom Into “\(branch.name)”",
                action: #selector(handleZoomNode(_:)),
                keyEquivalent: ""
            )
            zoomBranch.target = self
            zoomBranch.representedObject = branch
            menu.addItem(zoomBranch)
        }

        if let parent = node.parent, parent.isDirectory, parent !== vm.zoomRoot, parent !== hit.topBranchNode {
            let zoomParent = NSMenuItem(
                title: "Zoom Into “\(parent.name)”",
                action: #selector(handleZoomNode(_:)),
                keyEquivalent: ""
            )
            zoomParent.target = self
            zoomParent.representedObject = parent
            menu.addItem(zoomParent)
        }

        if vm.canZoomOut {
            let zoomOutItem = NSMenuItem(
                title: "Zoom Out to Parent",
                action: #selector(handleZoomOut(_:)),
                keyEquivalent: ""
            )
            zoomOutItem.target = self
            menu.addItem(zoomOutItem)
        }

        menu.addItem(.separator())

        let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(handleReveal(_:)), keyEquivalent: "")
        revealItem.target = self
        revealItem.representedObject = node
        menu.addItem(revealItem)

        let qlItem = NSMenuItem(title: "Quick Look", action: #selector(handleQuickLook(_:)), keyEquivalent: "")
        qlItem.target = self
        qlItem.representedObject = node
        menu.addItem(qlItem)

        let copyItem = NSMenuItem(title: "Copy Path", action: #selector(handleCopyPath(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.representedObject = node
        menu.addItem(copyItem)

        menu.addItem(.separator())

        let safety = node.evaluateDeletionSafety(scanRoot: vm.scanResult?.root)
        let trashItem = NSMenuItem(
            title: "Move “\(node.name)” to Trash…",
            action: safety.isAllowed ? #selector(handleTrash(_:)) : nil,
            keyEquivalent: ""
        )
        trashItem.target = self
        trashItem.representedObject = node
        menu.addItem(trashItem)

        return menu
    }

    @objc private func handleSelectParent(_ sender: NSMenuItem) {
        if let folder = sender.representedObject as? FileNode {
            viewModel?.selectNode(folder, revealInTree: true)
        }
    }

    @objc private func handleZoomNode(_ sender: NSMenuItem) {
        if let folder = sender.representedObject as? FileNode {
            viewModel?.zoomIn(to: folder)
        }
    }

    @objc private func handleZoomOut(_ sender: NSMenuItem) {
        viewModel?.zoomOut()
    }

    @objc private func handleReveal(_ sender: NSMenuItem) {
        if let node = sender.representedObject as? FileNode {
            viewModel?.revealInFinder(node)
        }
    }

    @objc private func handleQuickLook(_ sender: NSMenuItem) {
        if let node = sender.representedObject as? FileNode {
            viewModel?.toggleQuickLook(node)
        }
    }

    @objc private func handleCopyPath(_ sender: NSMenuItem) {
        if let node = sender.representedObject as? FileNode {
            viewModel?.copyPathToClipboard(node)
        }
    }

    @objc private func handleTrash(_ sender: NSMenuItem) {
        if let node = sender.representedObject as? FileNode {
            viewModel?.requestMoveToTrash(node)
        }
    }
}

