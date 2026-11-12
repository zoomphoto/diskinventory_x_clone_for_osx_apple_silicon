import SwiftUI
import AppKit
import DiskInventoryCore

struct InspectorPane: View {
    @Bindable var viewModel: InventoryViewModel

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df
    }()

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $viewModel.inspectorTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            switch viewModel.inspectorTab {
            case .kinds:
                kindsTabView
            case .largest:
                largestFilesTabView
            case .info:
                selectionInfoTabView
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Tab 1: Classic Disk Inventory X File Kinds Legend

    private var kindsTabView: some View {
        VStack(spacing: 0) {
            if let activeID = viewModel.highlightedKindID {
                let activeKind = FileKindRegistry.shared.kind(for: activeID)
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(activeKind.color.swiftUIColor)
                        .frame(width: 11, height: 11)
                    Text("Highlighting **\(activeKind.name)**")
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Button("Top Files") {
                        viewModel.inspectorTab = .largest
                    }
                    .font(.caption.weight(.medium))
                    .buttonStyle(.link)

                    Button {
                        viewModel.highlightedKindID = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear Kind highlight")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(activeKind.color.swiftUIColor.opacity(0.14))
                Divider()
            } else {
                HStack {
                    Text("Click any Kind to highlight its blocks in the Treemap")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                Divider()
            }

            List {
                ForEach(viewModel.kindStatistics) { stat in
                    let isHighlighted = viewModel.highlightedKindID == stat.kind.id
                    Button {
                        viewModel.toggleKindHighlight(stat.kind.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                    .fill(stat.kind.color.swiftUIColor)
                                    .frame(width: 13, height: 13)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 3.5)
                                            .strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5)
                                    )

                                Text(stat.kind.name)
                                    .font(.system(size: 12.5, weight: isHighlighted ? .semibold : .medium))
                                    .lineLimit(1)

                                Spacer(minLength: 4)

                                Text(ByteFormatting.format(stat.totalBytes))
                                    .font(.system(size: 12, design: .rounded).monospacedDigit().weight(.semibold))
                            }

                            HStack(spacing: 8) {
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(Color.secondary.opacity(0.14))
                                        Capsule()
                                            .fill(stat.kind.color.swiftUIColor)
                                            .frame(width: max(2, geo.size.width * stat.fraction))
                                    }
                                }
                                .frame(height: 4)

                                Text("\(ByteFormatting.formatCount(stat.fileCount, singular: "file", plural: "files")) • \(String(format: "%.1f%%", stat.fraction * 100))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(isHighlighted ? Color.accentColor.opacity(0.16) : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Tab 2: Largest Space Hogs Finder

    private var largestFilesTabView: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("Filter largest items by name…", text: $viewModel.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.caption)
                    if !viewModel.searchQuery.isEmpty {
                        Button {
                            viewModel.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(SizeFilterPreset.allCases) { preset in
                            let active = viewModel.sizeFilter == preset
                            Button {
                                viewModel.sizeFilter = preset
                            } label: {
                                Text(preset.label)
                                    .font(.caption2.weight(active ? .semibold : .regular))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3.5)
                                    .background(
                                        active ? Color.accentColor : Color.secondary.opacity(0.14),
                                        in: Capsule()
                                    )
                                    .foregroundStyle(active ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let kindID = viewModel.highlightedKindID {
                    let kind = FileKindRegistry.shared.kind(for: kindID)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(kind.color.swiftUIColor)
                            .frame(width: 8, height: 8)
                        Text("Filtered by: \(kind.name)")
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                        Button("Show All Kinds") {
                            viewModel.highlightedKindID = nil
                        }
                        .font(.caption2)
                        .buttonStyle(.link)
                    }
                }
            }
            .padding(10)

            Divider()

            if viewModel.largestItems.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "checkmark.seal")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("No matching items above threshold")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    if viewModel.sizeFilter != .all || viewModel.highlightedKindID != nil || !viewModel.searchQuery.isEmpty {
                        Button("Reset Filters") {
                            viewModel.sizeFilter = .all
                            viewModel.highlightedKindID = nil
                            viewModel.searchQuery = ""
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(Array(viewModel.largestItems.enumerated()), id: \.element.id) { index, item in
                        let isSelected = viewModel.selectedNode?.id == item.id
                        let kind = FileKindRegistry.shared.kind(for: item.kindID)
                        let relDir = item.parent.flatMap { parent in
                            if let root = viewModel.zoomRoot {
                                return parent.relativePath(from: root)
                            }
                            return parent.path
                        } ?? ""

                        HStack(spacing: 8) {
                            Text("#\(index + 1)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                                .frame(width: 26, alignment: .leading)

                            Image(nsImage: FileIconCache.shared.icon(for: item))
                                .resizable()
                                .frame(width: 18, height: 18)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(isSelected ? .white : .primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Text(relDir)
                                    .font(.system(size: 10))
                                    .foregroundStyle(isSelected ? .white.opacity(0.78) : .secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }

                            Spacer(minLength: 4)

                            VStack(alignment: .trailing, spacing: 2) {
                                Text(ByteFormatting.format(item.size(for: viewModel.sizeMetric)))
                                    .font(.system(size: 11.5, design: .rounded).monospacedDigit().weight(.semibold))
                                    .foregroundStyle(isSelected ? .white : .primary)

                                Circle()
                                    .fill(kind.color.swiftUIColor)
                                    .frame(width: 7, height: 7)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isSelected ? Color.accentColor : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.selectNode(item, revealInTree: true)
                        }
                        .contextMenu {
                            Button {
                                viewModel.revealInFinder(item)
                            } label: {
                                Label("Reveal in Finder", systemImage: "folder")
                            }
                            Button {
                                viewModel.toggleQuickLook(item)
                            } label: {
                                Label("Quick Look", systemImage: "eye")
                            }
                            Button {
                                viewModel.copyPathToClipboard(item)
                            } label: {
                                Label("Copy Path", systemImage: "doc.on.doc")
                            }
                            Divider()
                            let safety = item.evaluateDeletionSafety(scanRoot: viewModel.scanResult?.root)
                            Button(role: .destructive) {
                                viewModel.requestMoveToTrash(item)
                            } label: {
                                Label("Move to Trash…", systemImage: "trash")
                            }
                            .disabled(!safety.isAllowed)
                        }
                        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - Tab 3: Selected Item Details & Safe Cleanup Actions

    private var selectionInfoTabView: some View {
        ScrollView {
            if let node = viewModel.selectedNode {
                let kind = FileKindRegistry.shared.kind(for: node.kindID)
                let safety = node.evaluateDeletionSafety(scanRoot: viewModel.scanResult?.root)

                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(nsImage: FileIconCache.shared.icon(for: node))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 40, height: 40)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(node.name)
                                .font(.headline)
                                .textSelection(.enabled)

                            HStack(spacing: 6) {
                                Circle()
                                    .fill(node.isDirectory && !node.isPackage ? Color.accentColor : kind.color.swiftUIColor)
                                    .frame(width: 8, height: 8)
                                Text(node.isDirectory && !node.isPackage ? "Folder" : kind.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 9) {
                        infoRow(label: "Size on Disk", value: ByteFormatting.format(node.allocatedSize), bold: true)
                        infoRow(label: "Logical Size", value: ByteFormatting.format(node.logicalSize))

                        if node.isDirectory {
                            infoRow(
                                label: "Contained Files",
                                value: ByteFormatting.formatCount(node.fileCount, singular: "file", plural: "files")
                            )
                        }

                        if let modDate = node.modificationDate {
                            infoRow(label: "Modified", value: Self.dateFormatter.string(from: modDate))
                        }
                    }

                    if node.isDataless {
                        calloutBox(
                            symbol: "icloud.and.arrow.down",
                            tint: .blue,
                            text: "This is an iCloud Drive dataless placeholder. It currently uses \(ByteFormatting.format(node.allocatedSize)) on your local SSD."
                        )
                    } else if node.logicalSize > node.allocatedSize + 10_000_000 && node.allocatedSize > 0 {
                        calloutBox(
                            symbol: "internaldrive",
                            tint: .teal,
                            text: "Sparse or APFS-compressed item: deleting it reclaims \(ByteFormatting.format(node.allocatedSize)) of physical disk space."
                        )
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("Location")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Copy Path") {
                                viewModel.copyPathToClipboard(node)
                            }
                            .font(.caption2)
                            .buttonStyle(.link)
                        }
                        Text(node.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                    }

                    switch safety {
                    case .safe:
                        EmptyView()
                    case .caution(let note):
                        calloutBox(symbol: "exclamationmark.triangle.fill", tint: .orange, text: note)
                    case .protectedSystemPath(let reason):
                        calloutBox(symbol: "lock.shield.fill", tint: .red, text: reason)
                    }

                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Button {
                                viewModel.revealInFinder(node)
                            } label: {
                                Label("Reveal in Finder", systemImage: "folder")
                                    .frame(maxWidth: .infinity)
                            }

                            Button {
                                viewModel.toggleQuickLook(node)
                            } label: {
                                Label("Quick Look", systemImage: "eye")
                                    .frame(maxWidth: .infinity)
                            }
                        }

                        if node.isDirectory && node !== viewModel.zoomRoot {
                            Button {
                                viewModel.zoomIn(to: node)
                            } label: {
                                Label("Zoom Treemap Into Folder", systemImage: "plus.magnifyingglass")
                                    .frame(maxWidth: .infinity)
                            }
                        }

                        Button(role: .destructive) {
                            viewModel.requestMoveToTrash(node)
                        } label: {
                            Label("Move to Trash (\(ByteFormatting.format(node.allocatedSize)))…", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(!safety.isAllowed)
                    }
                    .padding(.top, 4)
                }
                .padding(14)
            } else {
                Text("Select a file or folder to inspect its metadata.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(24)
            }
        }
    }

    private func infoRow(label: String, value: String, bold: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12.5, weight: bold ? .semibold : .regular, design: .rounded).monospacedDigit())
        }
    }

    private func calloutBox(symbol: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.caption)
                .padding(.top, 2)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
    }
}

