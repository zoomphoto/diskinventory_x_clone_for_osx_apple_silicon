import Foundation
import CoreGraphics

public struct CushionCoeffs: Sendable, Equatable {
    public var ax: Float
    public var bx: Float
    public var ay: Float
    public var by: Float

    public init(ax: Float = 0, bx: Float = 0, ay: Float = 0, by: Float = 0) {
        self.ax = ax
        self.bx = bx
        self.ay = ay
        self.by = by
    }

    @inlinable
    public func addingRidge(rect: CGRect, height: Float) -> CushionCoeffs {
        var next = self
        let x1 = Float(rect.minX)
        let x2 = Float(rect.maxX)
        let y1 = Float(rect.minY)
        let y2 = Float(rect.maxY)

        let w = x2 - x1
        if w > 0.5 {
            let invW = 1.0 / w
            next.ax -= 2.0 * height * invW
            next.bx += height * (x2 + x1) * invW
        }

        let h = y2 - y1
        if h > 0.5 {
            let invH = 1.0 / h
            next.ay -= 2.0 * height * invH
            next.by += height * (y2 + y1) * invH
        }
        return next
    }
}

public struct TreemapLeaf: Sendable {
    public let node: FileNode?
    public let rect: CGRect
    public let kindID: UInt16
    public let bytes: Int64
    public let coeffs: CushionCoeffs
    public let isFreeSpace: Bool
    public let topBranchNode: FileNode?

    public init(
        node: FileNode?,
        rect: CGRect,
        kindID: UInt16,
        bytes: Int64,
        coeffs: CushionCoeffs,
        isFreeSpace: Bool = false,
        topBranchNode: FileNode? = nil
    ) {
        self.node = node
        self.rect = rect
        self.kindID = kindID
        self.bytes = bytes
        self.coeffs = coeffs
        self.isFreeSpace = isFreeSpace
        self.topBranchNode = topBranchNode
    }
}

public struct TreemapGroupFrame: Sendable {
    public let node: FileNode
    public let rect: CGRect
    public let depth: Int

    public init(node: FileNode, rect: CGRect, depth: Int) {
        self.node = node
        self.rect = rect
        self.depth = depth
    }
}

public struct TreemapLayout: Sendable {
    public let rootNode: FileNode
    public let bounds: CGRect
    public let leaves: [TreemapLeaf]
    public let topLevelFrames: [TreemapGroupFrame]
    public let nodeRectsByID: [UInt64: CGRect]

    public init(
        rootNode: FileNode,
        bounds: CGRect,
        leaves: [TreemapLeaf],
        topLevelFrames: [TreemapGroupFrame],
        nodeRectsByID: [UInt64: CGRect]
    ) {
        self.rootNode = rootNode
        self.bounds = bounds
        self.leaves = leaves
        self.topLevelFrames = topLevelFrames
        self.nodeRectsByID = nodeRectsByID
    }

    /// Finds the leaf containing `point` in logical coordinates.
    public func hitTest(at point: CGPoint) -> TreemapLeaf? {
        guard bounds.contains(point) else { return nil }
        // Reverse scan or direct scan (leaves partition bounds cleanly)
        for leaf in leaves {
            if leaf.rect.contains(point) {
                return leaf
            }
        }
        return nil
    }

    /// Look up the bounding rectangle of any visible file or directory node (for selection highlights!).
    public func rect(for node: FileNode) -> CGRect? {
        if node === rootNode { return bounds }
        if let direct = nodeRectsByID[node.id] {
            return direct
        }
        // If `node` was coalesced into an ancestor leaf due to sub-pixel size, walk up until found
        var cursor = node.parent
        while let anc = cursor, anc !== rootNode {
            if let r = nodeRectsByID[anc.id] {
                return r
            }
            cursor = anc.parent
        }
        return nil
    }
}

public enum CushionTreemapEngine {
    private struct WeightedEntry {
        let node: FileNode?
        let bytes: Int64
        let isFreeSpace: Bool
    }

    /// Builds a Squarified Cushion Treemap layout for `rootNode` within `bounds`.
    public static func buildLayout(
        rootNode: FileNode,
        bounds: CGRect,
        metric: SizeMetric = .allocated,
        showPackageContents: Bool = false,
        freeSpaceBytes: Int64 = 0,
        minSubdivideArea: CGFloat = 6.0,
        maxDepth: Int = 14,
        initialHeight: Float = 0.48,
        heightDecay: Float = 0.76
    ) -> TreemapLayout {
        guard bounds.width >= 2, bounds.height >= 2 else {
            return TreemapLayout(
                rootNode: rootNode,
                bounds: bounds,
                leaves: [],
                topLevelFrames: [],
                nodeRectsByID: [:]
            )
        }

        var leaves: [TreemapLeaf] = []
        leaves.reserveCapacity(4096)
        var topFrames: [TreemapGroupFrame] = []
        var nodeRects: [UInt64: CGRect] = [:]
        nodeRects.reserveCapacity(4096)
        nodeRects[rootNode.id] = bounds

        // Build top-level entries
        var topEntries: [WeightedEntry] = []
        if rootNode.isDirectory {
            for child in rootNode.children {
                let sz = child.size(for: metric)
                if sz > 0 {
                    topEntries.append(WeightedEntry(node: child, bytes: sz, isFreeSpace: false))
                }
            }
        } else {
            let sz = rootNode.size(for: metric)
            if sz > 0 {
                topEntries.append(WeightedEntry(node: rootNode, bytes: sz, isFreeSpace: false))
            }
        }

        if freeSpaceBytes > 0 {
            topEntries.append(WeightedEntry(node: nil, bytes: freeSpaceBytes, isFreeSpace: true))
        }

        topEntries.sort { $0.bytes > $1.bytes }
        guard !topEntries.isEmpty else {
            return TreemapLayout(
                rootNode: rootNode,
                bounds: bounds,
                leaves: [],
                topLevelFrames: [],
                nodeRectsByID: nodeRects
            )
        }

        let topLaidOut = squarifyEntries(entries: topEntries, in: bounds)

        func dominantKindID(in node: FileNode) -> UInt16 {
            if !node.isDirectory || node.isPackage {
                return node.kindID
            }
            var cur = node
            while cur.isDirectory && !cur.children.isEmpty {
                if cur.isPackage && !showPackageContents {
                    return cur.kindID
                }
                cur = cur.children[0] // children are sorted largest-first!
            }
            return cur.kindID
        }

        func subdivide(
            node: FileNode,
            rect: CGRect,
            depth: Int,
            parentCoeffs: CushionCoeffs,
            topBranch: FileNode
        ) {
            guard rect.width > 0.25, rect.height > 0.25 else { return }
            nodeRects[node.id] = rect

            let levelHeight = initialHeight * pow(heightDecay, Float(depth))
            let isAtomicLeaf = node.actsAsLeaf(showPackageContents: showPackageContents, currentRoot: rootNode)
            let area = rect.width * rect.height

            if isAtomicLeaf || depth >= maxDepth || area < minSubdivideArea {
                let leafCoeffs = parentCoeffs.addingRidge(rect: rect, height: levelHeight * 1.15)
                let kindID = isAtomicLeaf ? node.kindID : dominantKindID(in: node)
                leaves.append(
                    TreemapLeaf(
                        node: node,
                        rect: rect,
                        kindID: kindID,
                        bytes: node.size(for: metric),
                        coeffs: leafCoeffs,
                        isFreeSpace: false,
                        topBranchNode: topBranch
                    )
                )
                return
            }

            // Directory cushion dome
            let dirCoeffs = parentCoeffs.addingRidge(rect: rect, height: levelHeight)

            if depth <= 1 && rect.width >= 28 && rect.height >= 20 {
                topFrames.append(TreemapGroupFrame(node: node, rect: rect, depth: depth))
            }

            var childEntries: [WeightedEntry] = []
            childEntries.reserveCapacity(node.children.count)
            for child in node.children {
                let sz = child.size(for: metric)
                if sz > 0 {
                    childEntries.append(WeightedEntry(node: child, bytes: sz, isFreeSpace: false))
                }
            }

            guard !childEntries.isEmpty else {
                let leafCoeffs = parentCoeffs.addingRidge(rect: rect, height: levelHeight)
                leaves.append(
                    TreemapLeaf(
                        node: node,
                        rect: rect,
                        kindID: node.kindID,
                        bytes: node.size(for: metric),
                        coeffs: leafCoeffs,
                        isFreeSpace: false,
                        topBranchNode: topBranch
                    )
                )
                return
            }

            // Ensure descending order even if metric was switched
            if childEntries.count > 1 && childEntries[0].bytes < childEntries[childEntries.count - 1].bytes {
                childEntries.sort { $0.bytes > $1.bytes }
            }

            let childBoxes = squarifyEntries(entries: childEntries, in: rect)
            for (entry, childRect) in childBoxes {
                if let childNode = entry.node {
                    subdivide(
                        node: childNode,
                        rect: childRect,
                        depth: depth + 1,
                        parentCoeffs: dirCoeffs,
                        topBranch: topBranch
                    )
                }
            }
        }

        let baseCoeffs = CushionCoeffs()
        for (entry, rect) in topLaidOut {
            if entry.isFreeSpace {
                let coeffs = baseCoeffs.addingRidge(rect: rect, height: initialHeight * 0.65)
                leaves.append(
                    TreemapLeaf(
                        node: nil,
                        rect: rect,
                        kindID: FileKindRegistry.freeSpaceKindID,
                        bytes: entry.bytes,
                        coeffs: coeffs,
                        isFreeSpace: true,
                        topBranchNode: nil
                    )
                )
            } else if let node = entry.node {
                subdivide(
                    node: node,
                    rect: rect,
                    depth: 0,
                    parentCoeffs: baseCoeffs,
                    topBranch: node
                )
            }
        }

        return TreemapLayout(
            rootNode: rootNode,
            bounds: bounds,
            leaves: leaves,
            topLevelFrames: topFrames,
            nodeRectsByID: nodeRects
        )
    }

    /// Classic Bruls-Huizing-van Wijk Squarified Treemap subdivision.
    private static func squarifyEntries(
        entries: [WeightedEntry],
        in bounds: CGRect
    ) -> [(WeightedEntry, CGRect)] {
        let totalWeight = entries.reduce(0.0) { $0 + Double($1.bytes) }
        let totalArea = Double(bounds.width * bounds.height)
        guard totalWeight > 0, totalArea > 0 else { return [] }

        let areaScale = totalArea / totalWeight
        var results: [(WeightedEntry, CGRect)] = []
        results.reserveCapacity(entries.count)

        var freeRect = bounds
        var currentRow: [(WeightedEntry, Double)] = []
        currentRow.reserveCapacity(16)
        var currentRowAreaSum: Double = 0

        func worstRatio(row: [(WeightedEntry, Double)], rowSum: Double, nextArea: Double?, side: Double) -> Double {
            let s = rowSum + (nextArea ?? 0)
            guard s > 0, side > 0 else { return .infinity }
            var minA = row.first?.1 ?? (nextArea ?? 0)
            var maxA = minA
            for item in row {
                if item.1 < minA { minA = item.1 }
                if item.1 > maxA { maxA = item.1 }
            }
            if let nextArea {
                if nextArea < minA { minA = nextArea }
                if nextArea > maxA { maxA = nextArea }
            }
            guard minA > 0 else { return .infinity }
            let w2 = side * side
            let s2 = s * s
            return max((w2 * maxA) / s2, s2 / (w2 * minA))
        }

        func commitRow() {
            guard !currentRow.isEmpty else { return }
            let horizontalStrip = freeRect.width >= freeRect.height
            // Lay out along the SHORTER side of freeRect
            if horizontalStrip {
                // Shorter side is height -> vertical column on the left of freeRect
                let side = Double(freeRect.height)
                let colWidth = side > 0 ? CGFloat(currentRowAreaSum / side) : 0
                let clampedW = min(freeRect.width, max(0, colWidth))
                var cursorY = freeRect.minY
                for (idx, item) in currentRow.enumerated() {
                    let itemH: CGFloat
                    if idx == currentRow.count - 1 {
                        itemH = max(0, freeRect.maxY - cursorY)
                    } else {
                        itemH = currentRowAreaSum > 0 ? CGFloat(item.1 / currentRowAreaSum) * freeRect.height : 0
                    }
                    let r = CGRect(x: freeRect.minX, y: cursorY, width: clampedW, height: itemH)
                    results.append((item.0, r))
                    cursorY += itemH
                }
                freeRect = CGRect(
                    x: freeRect.minX + clampedW,
                    y: freeRect.minY,
                    width: max(0, freeRect.width - clampedW),
                    height: freeRect.height
                )
            } else {
                // Shorter side is width -> horizontal bar at the top of freeRect
                let side = Double(freeRect.width)
                let barHeight = side > 0 ? CGFloat(currentRowAreaSum / side) : 0
                let clampedH = min(freeRect.height, max(0, barHeight))
                var cursorX = freeRect.minX
                for (idx, item) in currentRow.enumerated() {
                    let itemW: CGFloat
                    if idx == currentRow.count - 1 {
                        itemW = max(0, freeRect.maxX - cursorX)
                    } else {
                        itemW = currentRowAreaSum > 0 ? CGFloat(item.1 / currentRowAreaSum) * freeRect.width : 0
                    }
                    let r = CGRect(x: cursorX, y: freeRect.minY, width: itemW, height: clampedH)
                    results.append((item.0, r))
                    cursorX += itemW
                }
                freeRect = CGRect(
                    x: freeRect.minX,
                    y: freeRect.minY + clampedH,
                    width: freeRect.width,
                    height: max(0, freeRect.height - clampedH)
                )
            }

            currentRow.removeAll(keepingCapacity: true)
            currentRowAreaSum = 0
        }

        var index = 0
        while index < entries.count {
            let entry = entries[index]
            let area = Double(entry.bytes) * areaScale
            if area <= 0 {
                index += 1
                continue
            }

            let shorterSide = Double(min(freeRect.width, freeRect.height))
            if shorterSide <= 0.0001 {
                break
            }

            if currentRow.isEmpty {
                currentRow.append((entry, area))
                currentRowAreaSum = area
                index += 1
            } else {
                let currentWorst = worstRatio(row: currentRow, rowSum: currentRowAreaSum, nextArea: nil, side: shorterSide)
                let candidateWorst = worstRatio(row: currentRow, rowSum: currentRowAreaSum, nextArea: area, side: shorterSide)
                if candidateWorst <= currentWorst {
                    currentRow.append((entry, area))
                    currentRowAreaSum += area
                    index += 1
                } else {
                    commitRow()
                }
            }
        }

        commitRow()
        return results
    }

    /// Renders a `TreemapLayout` to a Retina-sharp `CGImage` using parallel horizontal band rasterization.
    public static func renderImage(
        layout: TreemapLayout,
        scale: CGFloat = 2.0,
        useCushionShading: Bool = true,
        highlightedKindID: UInt16? = nil,
        registry: FileKindRegistry = .shared
    ) -> CGImage? {
        let clampedScale = max(1.0, min(3.0, scale))
        let pixelWidth = Int((layout.bounds.width * clampedScale).rounded(.toNearestOrAwayFromZero))
        let pixelHeight = Int((layout.bounds.height * clampedScale).rounded(.toNearestOrAwayFromZero))
        guard pixelWidth >= 2, pixelHeight >= 2 else { return nil }

        let invScale = Float(1.0 / clampedScale)
        let originX = Float(layout.bounds.minX)
        let originY = Float(layout.bounds.minY)

        // Normalized light direction from top-left-front: (-1, -1.15, 2.65)
        let rawLx: Float = -1.0
        let rawLy: Float = -1.15
        let rawLz: Float = 2.65
        let lLen = sqrt(rawLx * rawLx + rawLy * rawLy + rawLz * rawLz)
        let lx = rawLx / lLen
        let ly = rawLy / lLen
        let lz = rawLz / lLen

        let ambient: Float = 0.24
        let diffuse: Float = 0.84

        // Pre-resolve colors by kindID so worker threads perform zero lock lookups
        let allKinds = registry.allKindsSnapshot()
        let colorTable: [RGBColor] = allKinds.map { kind in
            if let highlightedKindID, kind.id != highlightedKindID {
                return kind.color.dimmed
            }
            return kind.color
        }
        let fallbackColor = RGBColor(134, 144, 158)

        // Precompute pixel rects for each leaf and bin into horizontal bands for lock-free concurrency
        struct PreparedLeaf {
            let px0: Int
            let py0: Int
            let px1: Int
            let py1: Int
            let color: RGBColor
            let coeffs: CushionCoeffs
        }

        var prepared: [PreparedLeaf] = []
        prepared.reserveCapacity(layout.leaves.count)

        let scaleD = Double(clampedScale)
        let minXD = Double(layout.bounds.minX)
        let minYD = Double(layout.bounds.minY)

        for leaf in layout.leaves {
            let x0 = max(0, min(pixelWidth, Int(((Double(leaf.rect.minX) - minXD) * scaleD).rounded(.toNearestOrAwayFromZero))))
            let x1 = max(0, min(pixelWidth, Int(((Double(leaf.rect.maxX) - minXD) * scaleD).rounded(.toNearestOrAwayFromZero))))
            let y0 = max(0, min(pixelHeight, Int(((Double(leaf.rect.minY) - minYD) * scaleD).rounded(.toNearestOrAwayFromZero))))
            let y1 = max(0, min(pixelHeight, Int(((Double(leaf.rect.maxY) - minYD) * scaleD).rounded(.toNearestOrAwayFromZero))))
            guard x1 > x0, y1 > y0 else { continue }

            let kIdx = Int(leaf.kindID)
            let baseColor = (kIdx >= 0 && kIdx < colorTable.count) ? colorTable[kIdx] : fallbackColor
            prepared.append(
                PreparedLeaf(
                    px0: x0,
                    py0: y0,
                    px1: x1,
                    py1: y1,
                    color: baseColor,
                    coeffs: leaf.coeffs
                )
            )
        }

        let bandCount = min(16, max(1, pixelHeight / 32))
        let rowsPerBand = (pixelHeight + bandCount - 1) / bandCount
        var bandLeaves: [[Int]] = Array(repeating: [], count: bandCount)
        for (idx, item) in prepared.enumerated() {
            let b0 = max(0, min(bandCount - 1, item.py0 / rowsPerBand))
            let b1 = max(0, min(bandCount - 1, (item.py1 - 1) / rowsPerBand))
            for b in b0...b1 {
                bandLeaves[b].append(idx)
            }
        }

        let bgPixel = packRGBX(26, 28, 33)
        var pixels = [UInt32](repeating: bgPixel, count: pixelWidth * pixelHeight)

        pixels.withUnsafeMutableBufferPointer { buffer in
            guard let basePtr = buffer.baseAddress else { return }
            // Explicitly convert pointer address to Int to cross Sendable closure cleanly
            let rawBaseAddress = Int(bitPattern: basePtr)

            DispatchQueue.concurrentPerform(iterations: bandCount) { band in
                let outPtr = UnsafeMutablePointer<UInt32>(bitPattern: rawBaseAddress)!
                let bandY0 = band * rowsPerBand
                let bandY1 = min(pixelHeight, bandY0 + rowsPerBand)
                guard bandY1 > bandY0 else { return }

                for leafIndex in bandLeaves[band] {
                    let item = prepared[leafIndex]
                    let yStart = max(bandY0, item.py0)
                    let yEnd = min(bandY1, item.py1)
                    guard yEnd > yStart else { continue }

                    if !useCushionShading {
                        let flatBorder = packRGBX(
                            UInt8(clamping: Int(item.color.r) * 7 / 10),
                            UInt8(clamping: Int(item.color.g) * 7 / 10),
                            UInt8(clamping: Int(item.color.b) * 7 / 10)
                        )
                        let fill = packRGBX(item.color.r, item.color.g, item.color.b)
                        let hasBorder = (item.px1 - item.px0 >= 4) && (item.py1 - item.py0 >= 4)
                        for py in yStart..<yEnd {
                            let rowOffset = py * pixelWidth
                            let isBorderY = hasBorder && (py == item.py0 || py == item.py1 - 1)
                            for px in item.px0..<item.px1 {
                                let isEdge = isBorderY || (hasBorder && (px == item.px0 || px == item.px1 - 1))
                                outPtr[rowOffset + px] = isEdge ? flatBorder : fill
                            }
                        }
                    } else {
                        let rf = Float(item.color.r)
                        let gf = Float(item.color.g)
                        let bf = Float(item.color.b)
                        let ax = item.coeffs.ax
                        let bx = item.coeffs.bx
                        let ay = item.coeffs.ay
                        let by = item.coeffs.by

                        for py in yStart..<yEnd {
                            let rowOffset = py * pixelWidth
                            let logicalY = originY + (Float(py) + 0.5) * invScale
                            let ny = -(ay * logicalY + by)
                            let nySqPlus1 = ny * ny + 1.0
                            let nyDotLyPlusLz = ny * ly + lz

                            var logicalX = originX + (Float(item.px0) + 0.5) * invScale
                            for px in item.px0..<item.px1 {
                                let nx = -(ax * logicalX + bx)
                                let normInv = 1.0 / sqrt(nx * nx + nySqPlus1)
                                let cosAngle = max(0.0, (nx * lx + nyDotLyPlusLz) * normInv)
                                let intensity = min(1.18, ambient + diffuse * cosAngle)

                                let r = UInt8(clamping: Int(rf * intensity))
                                let g = UInt8(clamping: Int(gf * intensity))
                                let b = UInt8(clamping: Int(bf * intensity))
                                outPtr[rowOffset + px] = packRGBX(r, g, b)
                                logicalX += invScale
                            }
                        }
                    }
                }
            }
        }

        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )

        return CGImage(
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: pixelWidth * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    @inline(__always)
    private static func packRGBX(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt32 {
        // Memory byte layout on little-endian arm64: [r, g, b, 255] -> matches byteOrder32Big | noneSkipLast
        return UInt32(r) | (UInt32(g) << 8) | (UInt32(b) << 16) | 0xFF00_0000
    }
}
