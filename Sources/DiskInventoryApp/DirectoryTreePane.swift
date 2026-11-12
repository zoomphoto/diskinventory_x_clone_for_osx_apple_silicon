import SwiftUI
import AppKit
import DiskInventoryCore

struct DirectoryTreePane: View {
    @Bindable var viewModel: InventoryViewModel

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            ScrollViewReader { proxy in
                List {
                    ForEach(viewModel.visibleTreeRows) { row in
                        switch row.kind {
                        case .node(let node):
                            TreeNodeRowView(
                                node: node,
                                depth: row.depth,
                                shareOfParent: row.shareOfParent,
                                isSelected: viewModel.selectedNode?.id == node.id,
                                isExpanded: viewModel.expandedNodeIDs.contains(node.id),
                                metric: viewModel.sizeMetric,
                                showPackageContents: viewModel.showPackageContents,
                                isZoomRoot: viewModel.zoomRoot === node,
                                onToggleExpand: {
                                    viewModel.toggleExpanded(node)
                                },
                                onSelect: {
                                    viewModel.selectNode(node, revealInTree: false)
                                },
                                onDoubleClick: {
                                    if node.isDirectory && node !== viewModel.zoomRoot {
                                        viewModel.zoomIn(to: node)
                                    } else {
                                        viewModel.revealInFinder(node)
                                    }
                                }
                            )
                            .id(row.id)
                            .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 8))
                            .listRowSeparator(.hidden)
                            .contextMenu {
                                nodeContextMenu(for: node)
                            }

                        case .showMore(let parent, let hiddenCount):
                            Button {
                                viewModel.showAllChildren(of: parent)
                            } label: {
                                HStack(spacing: 6) {
                                    Spacer()
                                        .frame(width: CGFloat(row.depth) * 14 + 18)
                                    Image(systemName: "ellipsis.circle")
                                        .foregroundStyle(.blue)
                                    Text("Show \(hiddenCount) smaller items in “\(parent.name)”…")
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .id(row.id)
                            .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 8))
                            .listRowSeparator(.hidden)
                        }
                    }
                }
                .listStyle(.plain)
                .onChange(of: viewModel.scrollTrigger) { _, _ in
                    if let targetID = viewModel.scrollToRowID {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(targetID, anchor: .center)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text("Folder & File Hierarchy")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(viewModel.sizeMetric.rawValue)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    @ViewBuilder
    private func nodeContextMenu(for node: FileNode) -> some View {
        if node.isDirectory && node !== viewModel.zoomRoot {
            Button {
                viewModel.zoomIn(to: node)
            } label: {
                Label("Zoom Into “\(node.name)”", systemImage: "plus.magnifyingglass")
            }
        }
        if viewModel.canZoomOut && node === viewModel.zoomRoot {
            Button {
                viewModel.zoomOut()
            } label: {
                Label("Zoom Out to Parent", systemImage: "minus.magnifyingglass")
            }
        }

        Divider()

        Button {
            viewModel.revealInFinder(node)
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }

        Button {
            viewModel.toggleQuickLook(node)
        } label: {
            Label("Quick Look", systemImage: "eye")
        }

        Button {
            viewModel.openInDefaultApp(node)
        } label: {
            Label("Open", systemImage: "arrow.up.forward.app")
        }

        Button {
            viewModel.copyPathToClipboard(node)
        } label: {
            Label("Copy Path", systemImage: "doc.on.doc")
        }

        if node.isDirectory && node !== viewModel.scanResult?.root {
            Button {
                viewModel.excludeFolderAndRemoveFromView(node)
            } label: {
                Label("Exclude “\(node.name)” from Scans", systemImage: "folder.badge.minus")
            }
        }

        Divider()

        let safety = node.evaluateDeletionSafety(scanRoot: viewModel.scanResult?.root)
        Button(role: .destructive) {
            viewModel.requestMoveToTrash(node)
        } label: {
            Label("Move to Trash…", systemImage: "trash")
        }
        .disabled(!safety.isAllowed)
    }
}

private struct TreeNodeRowView: View {
    let node: FileNode
    let depth: Int
    let shareOfParent: Double
    let isSelected: Bool
    let isExpanded: Bool
    let metric: SizeMetric
    let showPackageContents: Bool
    let isZoomRoot: Bool
    let onToggleExpand: () -> Void
    let onSelect: () -> Void
    let onDoubleClick: () -> Void

    private var canExpand: Bool {
        node.isDirectory && !node.children.isEmpty && (showPackageContents || !node.isPackage || isZoomRoot || isExpanded)
    }

    private var barColor: Color {
        if node.isDirectory && !node.isPackage {
            return Color.accentColor
        }
        return FileKindRegistry.shared.kind(for: node.kindID).color.swiftUIColor
    }

    var body: some View {
        HStack(spacing: 5) {
            if depth > 0 {
                Spacer()
                    .frame(width: CGFloat(min(depth, 16)) * 13)
            }

            if canExpand {
                Button(action: onToggleExpand) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isSelected ? .white : .secondary)
                        .frame(width: 14, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Spacer()
                    .frame(width: 14)
            }

            Image(nsImage: FileIconCache.shared.icon(for: node))
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)

            Text(node.name)
                .font(.system(size: 12.5, weight: isZoomRoot ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)
                .truncationMode(.middle)

            if node.isInaccessible {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : .orange)
                    .help("Permission denied while scanning this folder")
            } else if node.isDataless {
                Image(systemName: "icloud")
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
                    .help("Cloud-evicted file (uses minimal local disk blocks)")
            }

            Spacer(minLength: 6)

            if !isZoomRoot {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(isSelected ? Color.white.opacity(0.22) : Color.secondary.opacity(0.16))
                    Capsule()
                        .fill(isSelected ? Color.white.opacity(0.9) : barColor)
                        .frame(width: max(2, 44 * shareOfParent))
                }
                .frame(width: 44, height: 5)
            }

            Text(ByteFormatting.format(node.size(for: metric)))
                .font(.system(size: 11.5, design: .rounded).monospacedDigit())
                .foregroundStyle(isSelected ? .white : .secondary)
                .frame(width: 66, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3.5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onDoubleClick()
            }
        )
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                onSelect()
            }
        )
    }
}

