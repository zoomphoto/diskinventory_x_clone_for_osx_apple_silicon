import SwiftUI
import AppKit
import DiskInventoryCore

struct QuickScanPreset: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let accent: Color
    let url: URL
}

struct WelcomePickerView: View {
    @Bindable var viewModel: InventoryViewModel

    private var presets: [QuickScanPreset] {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return [
            QuickScanPreset(
                id: "home",
                title: "Home Folder (~)",
                subtitle: "Recommended — user files, Downloads, Library caches, Xcode & AI models",
                symbol: "house.fill",
                accent: .blue,
                url: home
            ),
            QuickScanPreset(
                id: "library",
                title: "User Library (~/Library)",
                subtitle: "Hidden space hogs: Caches, Application Support, DerivedData, Containers",
                symbol: "archivebox.fill",
                accent: .purple,
                url: home.appendingPathComponent("Library", isDirectory: true)
            ),
            QuickScanPreset(
                id: "downloads",
                title: "Downloads",
                subtitle: "Old disk images (.dmg, .iso), archives, videos, and installers",
                symbol: "arrow.down.circle.fill",
                accent: .teal,
                url: home.appendingPathComponent("Downloads", isDirectory: true)
            ),
            QuickScanPreset(
                id: "apps",
                title: "Applications (/Applications)",
                subtitle: "Installed macOS apps, creative suites, IDEs, and large bundles",
                symbol: "square.grid.2x2.fill",
                accent: .indigo,
                url: URL(fileURLWithPath: "/Applications", isDirectory: true)
            )
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                headerBanner

                if !viewModel.volumes.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Mounted Volumes", systemImage: "internaldrive.fill")
                                .font(.headline)
                            Spacer()
                            Button {
                                viewModel.refreshVolumes()
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }

                        ForEach(viewModel.volumes) { vol in
                            VolumeCardView(volume: vol) {
                                viewModel.startScan(url: vol.url)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Label("Targeted Space-Hog Locations", systemImage: "sparkle.magnifyingglass")
                        .font(.headline)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                        ForEach(presets) { preset in
                            Button {
                                viewModel.startScan(url: preset.url)
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: preset.symbol)
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundStyle(preset.accent)
                                        .frame(width: 36, height: 36)
                                        .background(preset.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(preset.title)
                                            .font(.system(.body, weight: .semibold))
                                            .foregroundStyle(.primary)
                                        Text(preset.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                        .padding(.top, 4)
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                exclusionsSummaryCard

                HStack(spacing: 12) {
                    Button {
                        viewModel.chooseFolderAndScan()
                    } label: {
                        Label("Choose Specific Folder…", systemImage: "folder.badge.plus")
                            .padding(.horizontal, 6)
                    }
                    .controlSize(.large)

                    if viewModel.scanResult != nil {
                        Button("Return to Current Scan") {
                            viewModel.phase = .workspace
                        }
                        .controlSize(.large)
                    }

                    Spacer()

                    Button {
                        viewModel.openFullDiskAccessSettings()
                    } label: {
                        Label("Full Disk Access Settings", systemImage: "lock.shield")
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                    .help("Grant Full Disk Access if you want to inspect protected ~/Library/Containers or Mail folders.")
                }
                .padding(.top, 4)
            }
            .padding(32)
            .frame(maxWidth: 880)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var headerBanner: some View {
        HStack(spacing: 18) {
            TreemapMiniEmblem()
                .frame(width: 60, height: 60)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Disk Inventory")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("Apple Silicon Native")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.blue.opacity(0.15), in: Capsule())
                        .foregroundStyle(.blue)
                }
                Text("Visual Cushion Treemap & Large-File Analyzer — accurately measures real APFS physical blocks on your drive.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var exclusionsSummaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Excluded from Scan", systemImage: "folder.badge.minus")
                    .font(.headline)

                Text("(\(viewModel.exclusionConfig.enabledRules.count) active)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    viewModel.addExcludedFoldersViaPanel()
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                        .font(.caption.weight(.medium))
                }
                .controlSize(.small)

                Button {
                    viewModel.showExclusionsSheet = true
                } label: {
                    Label("Manage All…", systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.medium))
                }
                .controlSize(.small)
            }

            Text("Click to toggle folders skipped during scanning (Cloud Storage is skipped by default so Google Drive / OneDrive / Dropbox mounts don't stall scans):")
                .font(.caption)
                .foregroundStyle(.secondary)

            FlowingRuleChipsView(viewModel: viewModel)
        }
        .padding(16)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
        )
    }
}

private struct FlowingRuleChipsView: View {
    @Bindable var viewModel: InventoryViewModel

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8)], spacing: 8) {
            ForEach(viewModel.exclusionConfig.rules) { rule in
                Button {
                    viewModel.toggleExclusionRule(id: rule.id)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: rule.isEnabled ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(rule.isEnabled ? Color.accentColor : .secondary)
                            .font(.system(size: 13))

                        Text(rule.title)
                            .font(.caption.weight(rule.isEnabled ? .semibold : .regular))
                            .foregroundStyle(rule.isEnabled ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        rule.isEnabled ? Color.accentColor.opacity(0.13) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(rule.isEnabled ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help(rule.subtitle)
            }
        }
    }
}

private struct VolumeCardView: View {
    let volume: VolumeSummary
    let onScan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: volume.url.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(volume.name)
                            .font(.title3.weight(.semibold))
                        Text(volume.fileSystemType)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 14) {
                        Text("**\(ByteFormatting.format(volume.usedBytes))** used of \(ByteFormatting.format(volume.totalBytes))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text("•")
                            .foregroundStyle(.tertiary)

                        Text("**\(ByteFormatting.format(volume.availableBytes))** free")
                            .font(.subheadline)
                            .foregroundStyle(volume.usedFraction > 0.85 ? .orange : .green)

                        if volume.purgeableBytes > 1_000_000_000 {
                            Text("(+\(ByteFormatting.format(volume.purgeableBytes)) purgeable)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                Button(action: onScan) {
                    Label(volume.url.path == "/" ? "Scan Entire Drive" : "Scan Volume", systemImage: "play.fill")
                        .fontWeight(.medium)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            GeometryReader { geo in
                let usedW = max(4, geo.size.width * volume.usedFraction)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: volume.usedFraction > 0.88
                                    ? [.orange, .red]
                                    : [.blue, .purple],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: usedW)
                }
            }
            .frame(height: 9)
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 1)
        )
    }
}

struct TreemapMiniEmblem: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.12, green: 0.14, blue: 0.18))
            GeometryReader { geo in
                let w = geo.size.width - 10
                let h = geo.size.height - 10
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(colors: [Color(red: 0.25, green: 0.56, blue: 0.96), Color(red: 0.14, green: 0.36, blue: 0.72)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: w * 0.56, height: h * 0.62)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(colors: [Color(red: 0.92, green: 0.34, blue: 0.30), Color(red: 0.66, green: 0.18, blue: 0.16)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: w * 0.40, height: h * 0.62)
                        .offset(x: w * 0.60, y: 0)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(colors: [Color(red: 0.66, green: 0.38, blue: 0.92), Color(red: 0.44, green: 0.22, blue: 0.68)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: w * 0.36, height: h * 0.34)
                        .offset(x: 0, y: h * 0.66)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(colors: [Color(red: 0.94, green: 0.68, blue: 0.22), Color(red: 0.72, green: 0.46, blue: 0.10)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: w * 0.34, height: h * 0.34)
                        .offset(x: w * 0.40, y: h * 0.66)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(colors: [Color(red: 0.24, green: 0.78, blue: 0.48), Color(red: 0.14, green: 0.52, blue: 0.30)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: w * 0.22, height: h * 0.34)
                        .offset(x: w * 0.78, y: h * 0.66)
                }
                .padding(5)
            }
        }
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
    }
}

struct ScanningProgressView: View {
    @Bindable var viewModel: InventoryViewModel
    let targetName: String
    let targetPath: String

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            TreemapMiniEmblem()
                .frame(width: 72, height: 72)

            VStack(spacing: 6) {
                Text("Scanning \(targetName)…")
                    .font(.title2.weight(.bold))
                Text(targetPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            ProgressView()
                .progressViewStyle(.linear)
                .frame(width: 380)

            HStack(spacing: 32) {
                statPill(
                    title: "Space Found",
                    value: ByteFormatting.format(viewModel.scanProgress.allocatedBytesFound)
                )
                statPill(
                    title: "Files",
                    value: NumberFormatter.localizedString(
                        from: NSNumber(value: viewModel.scanProgress.filesScanned),
                        number: .decimal
                    )
                )
                statPill(
                    title: "Folders",
                    value: NumberFormatter.localizedString(
                        from: NSNumber(value: viewModel.scanProgress.directoriesScanned),
                        number: .decimal
                    )
                )
                statPill(
                    title: "Elapsed",
                    value: String(format: "%.1fs", viewModel.scanProgress.elapsedSeconds)
                )
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))

            Text(viewModel.scanProgress.currentPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 540)

            if !viewModel.exclusionConfig.enabledRules.isEmpty {
                let names = viewModel.exclusionConfig.enabledRules.prefix(3).map(\.title).joined(separator: ", ")
                Text("Skipping: \(names)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(maxWidth: 540)
            }

            HStack(spacing: 12) {
                Button {
                    viewModel.showExclusionsSheet = true
                } label: {
                    Label("Excluded Folders…", systemImage: "folder.badge.minus")
                        .padding(.horizontal, 8)
                }
                .controlSize(.large)

                Button(role: .cancel) {
                    viewModel.cancelScan()
                } label: {
                    Text("Cancel Scan")
                        .padding(.horizontal, 12)
                }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
            }

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func statPill(title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(.title3, design: .rounded).monospacedDigit().weight(.semibold))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

