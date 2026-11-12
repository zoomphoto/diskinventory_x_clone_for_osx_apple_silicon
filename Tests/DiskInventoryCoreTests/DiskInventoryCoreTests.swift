import XCTest
import CoreGraphics
@testable import DiskInventoryCore

final class DiskInventoryCoreTests: XCTestCase {

    func testPathReconstructionAndDetachSubtraction() {
        let root = FileNode(
            id: 1,
            name: "Downloads",
            explicitPath: "/Users/test/Downloads",
            allocatedSize: 1_500,
            logicalSize: 1_500,
            fileCount: 3,
            flags: [.isDirectory]
        )
        let sub = FileNode(
            id: 2,
            name: "Archives",
            parent: root,
            allocatedSize: 1_000,
            logicalSize: 1_000,
            fileCount: 2,
            flags: [.isDirectory]
        )
        let f1 = FileNode(
            id: 3,
            name: "big.zip",
            parent: sub,
            allocatedSize: 700,
            logicalSize: 700,
            fileCount: 1
        )
        let f2 = FileNode(
            id: 4,
            name: "small.zip",
            parent: sub,
            allocatedSize: 300,
            logicalSize: 300,
            fileCount: 1
        )
        let f3 = FileNode(
            id: 5,
            name: "movie.mp4",
            parent: root,
            allocatedSize: 500,
            logicalSize: 500,
            fileCount: 1
        )
        sub.children = [f1, f2]
        root.children = [sub, f3]

        XCTAssertEqual(root.path, "/Users/test/Downloads")
        XCTAssertEqual(sub.path, "/Users/test/Downloads/Archives")
        XCTAssertEqual(f1.path, "/Users/test/Downloads/Archives/big.zip")

        // Detach f1 and verify ancestor sizes & counts update accurately
        XCTAssertTrue(f1.detachAndSubtractFromAncestors())
        XCTAssertEqual(sub.allocatedSize, 300)
        XCTAssertEqual(sub.fileCount, 1)
        XCTAssertEqual(root.allocatedSize, 800)
        XCTAssertEqual(root.fileCount, 2)
    }

    func testScannerHardLinksSymlinksAndPackages() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("DiskInvTest_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        // 1. Regular file + hard link to same inode
        let originalURL = tempDir.appendingPathComponent("weights.safetensors")
        let payload = Data(repeating: 0xAB, count: 65_536)
        try payload.write(to: originalURL)

        let hardLinkURL = tempDir.appendingPathComponent("weights_hardlink.safetensors")
        try fm.linkItem(at: originalURL, to: hardLinkURL)

        // 2. Symlink pointing outside (must NOT be followed into external dir!)
        let symlinkURL = tempDir.appendingPathComponent("outside_link")
        try fm.createSymbolicLink(at: symlinkURL, withDestinationURL: URL(fileURLWithPath: "/Applications"))

        // 3. Nested .app package bundle
        let appDir = tempDir.appendingPathComponent("Demo.app/Contents/MacOS", isDirectory: true)
        try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        try Data(repeating: 0xCD, count: 32_768).write(to: appDir.appendingPathComponent("DemoExec"))

        let scanner = DiskScanner()
        let result = try await scanner.scan(url: tempDir, sortMetric: .allocated)

        // Verify symlink was NOT traversed into /Applications
        let outsideNode = result.root.children.first { $0.name == "outside_link" }
        XCTAssertNotNil(outsideNode)
        XCTAssertTrue(outsideNode!.isSymlink)
        XCTAssertFalse(outsideNode!.isDirectory)

        // Verify hardlink deduplication: exactly one of the two hardlinked files has allocatedSize > 0
        let hardLinkedNodes = result.root.children.filter { $0.name.hasSuffix(".safetensors") }
        XCTAssertEqual(hardLinkedNodes.count, 2)
        let nonZeroHardLinks = hardLinkedNodes.filter { $0.allocatedSize > 0 }
        let duplicateHardLinks = hardLinkedNodes.filter { $0.isHardLinkDuplicate && $0.allocatedSize == 0 }
        XCTAssertEqual(nonZeroHardLinks.count, 1)
        XCTAssertEqual(duplicateHardLinks.count, 1)

        // Verify Demo.app is flagged as a package and aggregates its internal size
        let appNode = result.root.children.first { $0.name == "Demo.app" }
        XCTAssertNotNil(appNode)
        XCTAssertTrue(appNode!.isPackage)
        XCTAssertGreaterThanOrEqual(appNode!.logicalSize, 32_768)

        // Largest items with showPackageContents = false should surface Demo.app as a single item
        let largestCollapsed = result.root.collectLargestItems(limit: 10, metric: .logical, showPackageContents: false)
        XCTAssertTrue(largestCollapsed.contains(where: { $0.name == "Demo.app" }))
        XCTAssertFalse(largestCollapsed.contains(where: { $0.name == "DemoExec" }))

        // Largest items with showPackageContents = true should drill inside Demo.app to DemoExec
        let largestExpanded = result.root.collectLargestItems(limit: 10, metric: .logical, showPackageContents: true)
        XCTAssertTrue(largestExpanded.contains(where: { $0.name == "DemoExec" }))
    }

    func testTreemapSquarifiedAreaConservationAndColorByteOrder() {
        let registry = FileKindRegistry()
        let crimsonID = registry.classify(name: "ubuntu.iso", isDirectory: false, isPackage: false)
        let crimsonKind = registry.kind(for: crimsonID)

        let root = FileNode(
            id: 1,
            name: "Root",
            explicitPath: "/Root",
            allocatedSize: 1_000,
            logicalSize: 1_000,
            fileCount: 2,
            flags: [.isDirectory]
        )
        let iso = FileNode(
            id: 2,
            name: "ubuntu.iso",
            parent: root,
            allocatedSize: 750,
            logicalSize: 750,
            fileCount: 1,
            kindID: crimsonID
        )
        let mp4ID = registry.classify(name: "clip.mp4", isDirectory: false, isPackage: false)
        let mp4 = FileNode(
            id: 3,
            name: "clip.mp4",
            parent: root,
            allocatedSize: 250,
            logicalSize: 250,
            fileCount: 1,
            kindID: mp4ID
        )
        root.children = [iso, mp4]

        let bounds = CGRect(x: 0, y: 0, width: 400, height: 200)
        let layout = CushionTreemapEngine.buildLayout(rootNode: root, bounds: bounds, metric: .allocated, showPackageContents: false)

        XCTAssertEqual(layout.leaves.count, 2)
        let totalLeafArea = layout.leaves.reduce(CGFloat(0)) { $0 + $1.rect.width * $1.rect.height }
        XCTAssertEqual(totalLeafArea, 400 * 200, accuracy: 0.5)

        // Hit testing
        let isoCenter = CGPoint(x: layout.leaves[0].rect.midX, y: layout.leaves[0].rect.midY)
        XCTAssertTrue(layout.hitTest(at: isoCenter)?.node === iso)

        // Render flat image (no cushion shading) and read back center pixel to verify exact RGB channel order
        guard let cgImage = CushionTreemapEngine.renderImage(
            layout: layout,
            scale: 1.0,
            useCushionShading: false,
            highlightedKindID: nil,
            registry: registry
        ) else {
            XCTFail("Expected rendered CGImage")
            return
        }

        var pixel: [UInt8] = [0, 0, 0, 0]
        let ctx = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Draw isoCenter pixel into 1x1 context
        ctx.draw(
            cgImage,
            in: CGRect(
                x: -floor(isoCenter.x),
                y: -(CGFloat(cgImage.height) - 1.0 - floor(isoCenter.y)),
                width: CGFloat(cgImage.width),
                height: CGFloat(cgImage.height)
            )
        )
        XCTAssertEqual(pixel[0], crimsonKind.color.r, "Red channel should match kind color")
        XCTAssertEqual(pixel[1], crimsonKind.color.g, "Green channel should match kind color")
        XCTAssertEqual(pixel[2], crimsonKind.color.b, "Blue channel should match kind color")
    }

    func testDeletionSafetyGuardrails() {
        let sysParent = FileNode(id: 9, name: "System", explicitPath: "/System", flags: [.isDirectory])
        let sysNode = FileNode(id: 10, name: "Library", explicitPath: "/System/Library", parent: sysParent)
        sysParent.children = [sysNode]
        XCTAssertFalse(sysNode.evaluateDeletionSafety().isAllowed)

        let downloadsDir = FileNode(id: 19, name: "Downloads", explicitPath: NSHomeDirectory() + "/Downloads", flags: [.isDirectory])
        let homeDownloadsFile = FileNode(
            id: 20,
            name: "installer.dmg",
            parent: downloadsDir
        )
        downloadsDir.children = [homeDownloadsFile]
        XCTAssertEqual(homeDownloadsFile.evaluateDeletionSafety(), .safe)
    }

    func testRealAPFSSystemApplicationsScanAndCushionRender() async throws {
        let sysAppsURL = URL(fileURLWithPath: "/System/Applications", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sysAppsURL.path) else { return }

        let scanner = DiskScanner()
        let result = try await scanner.scan(url: sysAppsURL, sortMetric: .allocated)
        XCTAssertGreaterThan(result.totalFilesScanned, 100)
        XCTAssertGreaterThan(result.root.allocatedSize, 0)

        let bounds = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let layout = CushionTreemapEngine.buildLayout(
            rootNode: result.root,
            bounds: bounds,
            metric: .allocated,
            showPackageContents: false
        )
        XCTAssertFalse(layout.leaves.isEmpty)

        let cgImage = CushionTreemapEngine.renderImage(
            layout: layout,
            scale: 2.0,
            useCushionShading: true,
            highlightedKindID: nil
        )
        XCTAssertNotNil(cgImage)
        XCTAssertEqual(cgImage?.width, 2560)
        XCTAssertEqual(cgImage?.height, 1600)
    }

    func testCloudStorageDefaultExclusionAndCustomFolderExclusions() async throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory.appendingPathComponent("DiskInvExcl_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempHome) }

        // Simulate ~/Library/CloudStorage/GoogleDrive-test/preorder
        let cloudDir = tempHome.appendingPathComponent("Library/CloudStorage/GoogleDrive-test/preorder", isDirectory: true)
        try fm.createDirectory(at: cloudDir, withIntermediateDirectories: true)
        try Data(repeating: 0x11, count: 65_536).write(to: cloudDir.appendingPathComponent("remote_stub.bin"))

        // Simulate local ~/Downloads/local_movie.mp4
        let downloadsDir = tempHome.appendingPathComponent("Downloads", isDirectory: true)
        try fm.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        try Data(repeating: 0x22, count: 32_768).write(to: downloadsDir.appendingPathComponent("local_movie.mp4"))

        // Simulate custom excluded directory & folder-name pattern
        let customSkipDir = tempHome.appendingPathComponent("ArchiveMount", isDirectory: true)
        try fm.createDirectory(at: customSkipDir, withIntermediateDirectories: true)
        try Data(repeating: 0x33, count: 32_768).write(to: customSkipDir.appendingPathComponent("skip_me.dat"))

        let nodeModulesDir = tempHome.appendingPathComponent("Project/node_modules/pkg", isDirectory: true)
        try fm.createDirectory(at: nodeModulesDir, withIntermediateDirectories: true)
        try Data(repeating: 0x44, count: 16_384).write(to: nodeModulesDir.appendingPathComponent("index.js"))

        var config = ScanExclusionConfig(rules: ScanExclusionConfig.defaultRules(homeDirectory: tempHome.path))
        config.addCustomPath(customSkipDir.path)
        config.addCustomFolderName("node_modules")

        let scanner = DiskScanner()
        let result = try await scanner.scan(url: tempHome, sortMetric: .logical, exclusions: config)

        // Only local_movie.mp4 should be scanned; CloudStorage, ArchiveMount, and node_modules must all be skipped!
        XCTAssertEqual(result.totalFilesScanned, 1)
        XCTAssertEqual(result.excludedCount, 3)
        let largest = result.root.collectLargestItems(limit: 10, metric: .logical)
        XCTAssertEqual(largest.map(\.name), ["local_movie.mp4"])

        // If user explicitly chooses to scan CloudStorage directly, do not exclude the explicit scan root
        let explicitCloudScan = try await scanner.scan(
            url: tempHome.appendingPathComponent("Library/CloudStorage", isDirectory: true),
            sortMetric: .logical,
            exclusions: config
        )
        XCTAssertEqual(explicitCloudScan.totalFilesScanned, 1)
    }
}
