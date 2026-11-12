import SwiftUI
import DiskInventoryCore

struct ScanExclusionsSheet: View {
    @Bindable var viewModel: InventoryViewModel
    @State private var folderNameInput: String = ""
    @State private var initialConfigSnapshot: ScanExclusionConfig?

    private var hasUnsavedScanChanges: Bool {
        guard let initialConfigSnapshot else { return false }
        return initialConfigSnapshot != viewModel.exclusionConfig
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "folder.badge.minus")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Excluded Folders & Locations")
                        .font(.title3.weight(.bold))
                    Text("Skipped directories are never opened during scanning—preventing slow cloud mounts from stalling scans.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Built-in Presets
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Common Presets")
                            .font(.subheadline.weight(.semibold))

                        ForEach(viewModel.exclusionConfig.rules.filter(\.isBuiltIn)) { rule in
                            ruleRow(rule: rule)
                        }
                    }

                    Divider()

                    // Custom Folder Paths & Names
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Custom Excluded Folders")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Button {
                                viewModel.addExcludedFoldersViaPanel()
                            } label: {
                                Label("Add Folder…", systemImage: "folder.badge.plus")
                                    .font(.caption.weight(.medium))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }

                        // Exclude by folder name anywhere
                        HStack(spacing: 8) {
                            TextField("Or exclude folder name everywhere (e.g. node_modules, .venv)…", text: $folderNameInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                                .onSubmit {
                                    submitFolderName()
                                }

                            Button("Add Name") {
                                submitFolderName()
                            }
                            .controlSize(.small)
                            .disabled(folderNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        let customRules = viewModel.exclusionConfig.rules.filter { !$0.isBuiltIn }
                        if customRules.isEmpty {
                            Text("No custom folders excluded yet. Click “Add Folder…” to pick any folder on your Mac to skip.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                        } else {
                            ForEach(customRules) { rule in
                                ruleRow(rule: rule)
                            }
                        }
                    }

                    if let result = viewModel.scanResult, !result.sampleExcludedPaths.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Skipped in Current Scan (\(result.excludedCount))")
                                .font(.subheadline.weight(.semibold))
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(result.sampleExcludedPaths, id: \.self) { path in
                                    Text(path)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 410)

            Divider()

            HStack {
                Button("Reset to Defaults") {
                    viewModel.resetExclusionsToDefaults()
                }
                .font(.caption)

                Spacer()

                if hasUnsavedScanChanges && viewModel.lastScanTargetURL != nil {
                    Button("Close Without Rescanning") {
                        viewModel.showExclusionsSheet = false
                    }

                    Button {
                        viewModel.showExclusionsSheet = false
                        viewModel.restartLastScan()
                    } label: {
                        Label("Apply & Rescan Now", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") {
                        viewModel.showExclusionsSheet = false
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 600)
        .onAppear {
            initialConfigSnapshot = viewModel.exclusionConfig
        }
    }

    private func submitFolderName() {
        let trimmed = folderNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        viewModel.addExcludedFolderName(trimmed)
        folderNameInput = ""
    }

    private func ruleRow(rule: ScanExclusionRule) -> some View {
        HStack(spacing: 10) {
            Toggle(
                "",
                isOn: Binding(
                    get: { rule.isEnabled },
                    set: { _ in viewModel.toggleExclusionRule(id: rule.id) }
                )
            )
            .labelsHidden()
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(rule.isEnabled ? .primary : .secondary)
                Text(rule.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if !rule.isBuiltIn {
                Button {
                    viewModel.removeCustomExclusionRule(id: rule.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove custom exclusion")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

