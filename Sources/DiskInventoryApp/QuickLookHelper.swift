import AppKit
import Quartz

/// Bridges macOS native Quick Look (`QLPreviewPanel`) so pressing Space or clicking Quick Look
/// previews the selected video, image, PDF, archive, or document right from Disk Inventory.
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private var previewURL: URL?

    func togglePreview(for url: URL) {
        self.previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self

        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
        }
    }

    func refreshIfVisible(with url: URL?) {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(),
              panel.isVisible else {
            return
        }
        self.previewURL = url
        panel.reloadData()
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated {
            previewURL == nil ? 0 : 1
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated {
            guard let url = previewURL else { return nil }
            return url as NSURL
        }
    }
}

