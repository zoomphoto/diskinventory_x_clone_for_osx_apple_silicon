import AppKit
import UniformTypeIdentifiers
import DiskInventoryCore

/// Caches native macOS Finder icons by file type / extension so virtualized lists scroll at 120Hz
/// without hitting the filesystem per row.
@MainActor
final class FileIconCache {
    static let shared = FileIconCache()

    private var extCache: [String: NSImage] = [:]
    private let folderIcon: NSImage
    private let appBundleIcon: NSImage
    private let genericDocIcon: NSImage

    private init() {
        let ws = NSWorkspace.shared
        if #available(macOS 12.0, *) {
            folderIcon = ws.icon(for: .folder)
            appBundleIcon = ws.icon(for: .applicationBundle)
            genericDocIcon = ws.icon(for: .data)
        } else {
            folderIcon = NSImage(named: NSImage.folderName) ?? NSImage()
            appBundleIcon = NSImage(named: NSImage.applicationIconName) ?? NSImage()
            genericDocIcon = NSImage()
        }
    }

    func icon(for node: FileNode) -> NSImage {
        if node.isDirectory && !node.isPackage {
            return folderIcon
        }
        guard let ext = FileKindRegistry.extractLowercaseExtension(from: node.name) else {
            return node.isPackage ? appBundleIcon : genericDocIcon
        }
        if let cached = extCache[ext] {
            return cached
        }
        let img: NSImage
        if ext == "app" {
            // For .app bundles, fetch actual app icon if accessible fast, else generic app icon
            let realIcon = NSWorkspace.shared.icon(forFile: node.path)
            img = realIcon
            // Don't cache one specific app's icon for all .app bundles! Return directly:
            return img
        }
        if let utType = UTType(filenameExtension: ext) {
            img = NSWorkspace.shared.icon(for: utType)
        } else {
            img = node.isPackage ? appBundleIcon : genericDocIcon
        }
        extCache[ext] = img
        return img
    }
}

