import SwiftUI
import AppKit
import DiskInventoryCore

@MainActor
final class DiskInventoryAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct DiskInventoryMainApp: App {
    @NSApplicationDelegateAdaptor(DiskInventoryAppDelegate.self) private var appDelegate
    @State private var viewModel = InventoryViewModel()

    var body: some Scene {
        WindowGroup("Disk Inventory") {
            RootContentView(viewModel: viewModel)
                .onAppear {
                    // Support passing a target directory on the command line: e.g. DiskInventoryApp ~/Downloads
                    let args = CommandLine.arguments
                    if args.count >= 2 {
                        let candidate = args[1]
                        if !candidate.hasPrefix("-") {
                            var isDir: ObjCBool = false
                            let expanded = (candidate as NSString).expandingTildeInPath
                            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                                viewModel.startScan(url: URL(fileURLWithPath: expanded, isDirectory: true))
                            }
                        }
                    }
                }
        }
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan Folder…") {
                    viewModel.chooseFolderAndScan()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Volume & Preset Picker") {
                    viewModel.showWelcomePicker()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("Rescan Current Folder") {
                    viewModel.rescanCurrentRoot()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(viewModel.scanResult == nil)
            }

            CommandGroup(replacing: .appSettings) {
                Button("Excluded Folders & Scan Settings…") {
                    viewModel.showExclusionsSheet = true
                }
                .keyboardShortcut(",", modifiers: [.command])
            }

            CommandMenu("Inventory") {
                Button("Zoom Into Selected Folder") {
                    if let sel = viewModel.selectedNode {
                        viewModel.zoomIn(to: sel)
                    }
                }
                .keyboardShortcut("]", modifiers: [.command])
                .disabled(!viewModel.canZoomIntoSelection)

                Button("Zoom Out to Parent Folder") {
                    viewModel.zoomOut()
                }
                .keyboardShortcut("[", modifiers: [.command])
                .disabled(!viewModel.canZoomOut)

                Button("Select Enclosing Folder") {
                    viewModel.selectParentOfSelection()
                }
                .keyboardShortcut(.upArrow, modifiers: [.command])
                .disabled(viewModel.selectedNode == nil)

                Divider()

                Button("Quick Look Selected Item") {
                    viewModel.toggleQuickLook()
                }
                .keyboardShortcut("y", modifiers: [.command])
                .disabled(viewModel.selectedNode == nil)

                Button("Reveal in Finder") {
                    viewModel.revealInFinder()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(viewModel.selectedNode == nil)

                Button("Copy Path") {
                    viewModel.copyPathToClipboard()
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(viewModel.selectedNode == nil)

                Divider()

                let canTrash = viewModel.selectedNode?.evaluateDeletionSafety(scanRoot: viewModel.scanResult?.root).isAllowed ?? false
                Button("Move Selected Item to Trash…") {
                    viewModel.requestMoveToTrash()
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(!canTrash)
            }
        }
    }
}

DiskInventoryMainApp.main()
