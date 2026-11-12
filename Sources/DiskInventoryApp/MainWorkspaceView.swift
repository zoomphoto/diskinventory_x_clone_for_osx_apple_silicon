import SwiftUI
import AppKit
import DiskInventoryCore

struct RootContentView: View {
    @Bindable var viewModel: InventoryViewModel
    @State private var showInspector: Bool = true

    var body: some View {
        Group {
            switch viewModel.phase {
            case .welcome:
                WelcomePickerView(viewModel: viewModel)
            case .scanning(let targetName, let targetPath):
                ScanningProgressView(
                    viewModel: viewModel,
                    targetName: targetName,
                    targetPath: targetPath
                )
            case .workspace:
                MainWorkspaceView(viewModel: viewModel, showInspector: $showInspector)
            }
        }
        .frame(minWidth: 980, minHeight: 620)
        .toolbar {
            workspaceToolbar
        }
        .sheet(isPresented: $viewModel.showTrashConfirmation) {
            TrashConfirmationSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showInaccessibleSheet) {
            InaccessibleFoldersSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showExclusionsSheet) {
            ScanExclusionsSheet(viewModel: viewModel)
        }
        .alert(viewModel.alertTitle, isPresented: $viewModel.showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.alertMessage)
        }
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            if case .workspace = viewModel.phase {
                Button {
                    viewModel.showWelcomePicker()
                } label: {
                    Label("Volumes", systemImage: "internaldrive")
                }
                .help("Choose another drive or preset folder to scan")

                Button {
                    viewModel.chooseFolderAndScan()
                } label: {
                    Label("Open Folder…", systemImage: "folder.badge.plus")
                }
                .help("Scan a specific folder (⌘O)")

                Button {
                    viewModel.rescanCurrentRoot()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .help("Rescan current root folder (⌘R)")

                Button {
                    viewModel.showExclusionsSheet = true
                } label: {
                    Label("Exclusions", systemImage: "folder.badge.minus")
                }
                .help("Configure folders excluded from scans (⌘,)")
            }
        }

        ToolbarItemGroup(placement: .principal) {
            if case .workspace = viewModel.phase {
                Button {
                    viewModel.zoomOut()
                } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                .disabled(!viewModel.canZoomOut)
                .help("Zoom Treemap out to parent folder (⌘[)")

                Button {
                    if let sel = viewModel.selectedNode {
                        viewModel.zoomIn(to: sel)
                    }
                } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                .disabled(!viewModel.canZoomIntoSelection)
                .help("Zoom Treemap into selected folder (⌘])")

                Menu {
                    Picker("Size Calculation", selection: $viewModel.sizeMetric) {
                        ForEach(SizeMetric.allCases) { metric in
                            Text(metric.rawValue).tag(metric)
                        }
                    }
                    Divider()
                    Toggle("3D Cushion Shading", isOn: $viewModel.useCushionShading)
                    Toggle("Show Top Folder Labels", isOn: $viewModel.showGroupLabels)
                    Toggle("Drill Inside Packages (.app, Libraries)", isOn: $viewModel.showPackageContents)
                    if let scanRoot = viewModel.scanResult?.root,
                       let vol = viewModel.scanResult?.volumeSummary,
                       scanRoot.path == vol.url.path {
                        Toggle("Show Free Volume Space in Treemap", isOn: $viewModel.showFreeSpaceInTreemap)
                    }
                } label: {
                    Label("Display", systemImage: "slider.horizontal.3")
                }
                .help("Configure Treemap & size calculation options")
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if case .workspace = viewModel.phase {
                Button {
                    viewModel.toggleQuickLook()
                } label: {
                    Label("Quick Look", systemImage: "eye")
                }
                .disabled(viewModel.selectedNode == nil)
                .help("Preview selected item with Quick Look (⌘Y)")

                Button {
                    viewModel.revealInFinder()
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
                .disabled(viewModel.selectedNode == nil)
                .help("Reveal selected item in Finder (⇧⌘R)")

                let canTrash = viewModel.selectedNode?.evaluateDeletionSafety(scanRoot: viewModel.scanResult?.root).isAllowed ?? false
                Button(role: .destructive) {
                    viewModel.requestMoveToTrash()
                } label: {
                    Label("Trash", systemImage: "trash")
                }
                .disabled(!canTrash)
                .help("Move selected item to macOS Trash (⌘⌫)")

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showInspector.toggle()
                    }
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Show or hide the Kinds & Largest Files inspector")
            }
        }
    }
}

struct MainWorkspaceView: View {
    @Bindable var viewModel: InventoryViewModel
    @Binding var showInspector: Bool

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbHeaderBar
            Divider()

            HSplitView {
                DirectoryTreePane(viewModel: viewModel)
                    .frame(minWidth: 250, idealWidth: 315, maxWidth: 480)

                TreemapCanvasPane(viewModel: viewModel)
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)

                if showInspector {
                    InspectorPane(viewModel: viewModel)
                        .frame(minWidth: 270, idealWidth: 325, maxWidth: 430)
                }
            }
        }
    }

    private var breadcrumbHeaderBar: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.zoomOut()
            } label: {
                Image(systemName: "arrow.turn.left.up")
                    .font(.caption.weight(.bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!viewModel.canZoomOut)
            .help("Zoom up one folder level")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    let crumbs = viewModel.breadcrumbs
                    ForEach(Array(crumbs.enumerated()), id: \.element.id) { idx, node in
                        if idx > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                        let isCurrent = idx == crumbs.count - 1
                        Button {
                            viewModel.zoomToBreadcrumb(node)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: idx == 0 ? "internaldrive.fill" : "folder.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                                Text(node.name)
                                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                                    .foregroundStyle(isCurrent ? .primary : .secondary)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                isCurrent ? Color.accentColor.opacity(0.13) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer(minLength: 8)

            if viewModel.sessionReclaimedBytes > 0 {
                Button {
                    viewModel.openUserTrashInFinder()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "trash.slash.fill")
                            .font(.caption2)
                        Text("Trashed: \(ByteFormatting.format(viewModel.sessionReclaimedBytes))")
                            .font(.caption.weight(.semibold).monospacedDigit())
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(Color.green.opacity(0.16), in: Capsule())
                    .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help("Click to open macOS Trash in Finder (Empty Trash to permanently reclaim APFS space)")
            }

            if let result = viewModel.scanResult, result.excludedCount > 0 {
                Button {
                    viewModel.showExclusionsSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.badge.minus")
                            .font(.caption2)
                        Text("\(result.excludedCount) excluded")
                            .font(.caption2.weight(.medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(Color.indigo.opacity(0.15), in: Capsule())
                    .foregroundStyle(.indigo)
                }
                .buttonStyle(.plain)
                .help("Folders skipped by your Exclusion rules (e.g. CloudStorage). Click to configure.")
            }

            if let result = viewModel.scanResult, result.inaccessibleCount > 0 {
                Button {
                    viewModel.showInaccessibleSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.trianglebadge.exclamationmark")
                            .font(.caption2)
                        Text("\(result.inaccessibleCount) locked")
                            .font(.caption2.weight(.medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(Color.orange.opacity(0.16), in: Capsule())
                    .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("Some protected folders could not be read without Full Disk Access. Click for details.")
            }

            if let root = viewModel.zoomRoot {
                Text("\(ByteFormatting.format(root.size(for: viewModel.sizeMetric))) • \(ByteFormatting.formatCount(root.fileCount, singular: "file", plural: "files"))")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

private struct TrashConfirmationSheet: View {
    @Bindable var viewModel: InventoryViewModel

    private var totalAllocated: Int64 {
        viewModel.pendingTrashNodes.reduce(0) { $0 + $1.allocatedSize }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(.red)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Move \(viewModel.pendingTrashNodes.count == 1 ? "Item" : "\(viewModel.pendingTrashNodes.count) Items") to Trash?")
                        .font(.headline)
                    Text("Estimated physical disk space: **\(ByteFormatting.format(totalAllocated))**")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.pendingTrashNodes) { node in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Image(nsImage: FileIconCache.shared.icon(for: node))
                                    .resizable()
                                    .frame(width: 16, height: 16)
                                Text(node.name)
                                    .font(.callout.weight(.semibold))
                                Spacer()
                                Text(ByteFormatting.format(node.allocatedSize))
                                    .font(.caption.monospacedDigit().weight(.semibold))
                            }
                            Text(node.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)

                            if case .caution(let warning) = node.evaluateDeletionSafety(scanRoot: viewModel.scanResult?.root) {
                                Text(warning)
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(8)
                        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(maxHeight: 200)

            Text("Items are moved safely to your macOS Trash—not permanently erased yet. Empty Trash in Finder when you are ready to release the APFS blocks.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    viewModel.pendingTrashNodes = []
                    viewModel.showTrashConfirmation = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Move to Trash", role: .destructive) {
                    viewModel.confirmMovePendingToTrash()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 500)
    }
}

private struct InaccessibleFoldersSheet: View {
    @Bindable var viewModel: InventoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.title)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Protected Folders Skipped (\(viewModel.scanResult?.inaccessibleCount ?? 0))")
                        .font(.headline)
                    Text("macOS Privacy (TCC) restricts apps from reading certain system/app containers without Full Disk Access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let samples = viewModel.scanResult?.sampleInaccessiblePaths, !samples.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(samples, id: \.self) { path in
                            Text(path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 180)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Button("Open Full Disk Access Settings…") {
                    viewModel.openFullDiskAccessSettings()
                }
                Spacer()
                Button("Done") {
                    viewModel.showInaccessibleSheet = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

