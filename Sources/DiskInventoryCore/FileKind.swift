import Foundation

public struct RGBColor: Sendable, Equatable, Hashable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    public var rf: Float { Float(r) / 255.0 }
    public var gf: Float { Float(g) / 255.0 }
    public var bf: Float { Float(b) / 255.0 }

    /// Produces a muted version for unselected blocks when filtering by Kind.
    public var dimmed: RGBColor {
        let luma = UInt8(clamping: Int(Float(r) * 0.299 + Float(g) * 0.587 + Float(b) * 0.114))
        let base = Int(luma) / 3 + 28
        return RGBColor(
            UInt8(clamping: (base * 3 + Int(r)) / 4),
            UInt8(clamping: (base * 3 + Int(g)) / 4),
            UInt8(clamping: (base * 3 + Int(b)) / 4)
        )
    }
}

public struct FileKind: Sendable, Identifiable, Equatable, Hashable {
    public let id: UInt16
    public let name: String
    public let detail: String
    public let color: RGBColor

    public init(id: UInt16, name: String, detail: String, color: RGBColor) {
        self.id = id
        self.name = name
        self.detail = detail
        self.color = color
    }
}

public struct KindStatistic: Identifiable, Equatable, Sendable {
    public let kind: FileKind
    public var totalBytes: Int64
    public var fileCount: Int
    public var fraction: Double

    public var id: UInt16 { kind.id }

    public init(kind: FileKind, totalBytes: Int64, fileCount: Int, fraction: Double = 0) {
        self.kind = kind
        self.totalBytes = totalBytes
        self.fileCount = fileCount
        self.fraction = fraction
    }
}

/// Thread-safe registry mapping file extensions and bundle types to distinct colors and labels,
/// inspired by Disk Inventory X's classic Kind palette and modernized for macOS / Apple Silicon.
public final class FileKindRegistry: @unchecked Sendable {
    public static let shared = FileKindRegistry()

    public static let directoryKindID: UInt16 = 0
    public static let freeSpaceKindID: UInt16 = 1

    private let lock = NSLock()
    private var kindsByID: [FileKind] = []
    private var extToKindID: [String: UInt16] = [:]
    private var dynamicExtToKindID: [String: UInt16] = [:]

    private var appBundleKindID: UInt16 = 0
    private var mediaLibraryBundleKindID: UInt16 = 0
    private var devBundleKindID: UInt16 = 0
    private var genericPackageKindID: UInt16 = 0
    private var extensionlessBinaryKindID: UInt16 = 0

    // Classic high-contrast palette for dynamic unknown extensions
    private let dynamicPalette: [RGBColor] = [
        RGBColor(78, 154, 224),
        RGBColor(218, 118, 72),
        RGBColor(92, 184, 138),
        RGBColor(178, 114, 212),
        RGBColor(216, 174, 68),
        RGBColor(80, 182, 194),
        RGBColor(214, 96, 134),
        RGBColor(142, 184, 78),
        RGBColor(116, 128, 216),
        RGBColor(204, 138, 96)
    ]

    public init() {
        registerDefaults()
    }

    private func addKind(name: String, detail: String, color: RGBColor, extensions: [String] = []) -> UInt16 {
        let id = UInt16(kindsByID.count)
        let kind = FileKind(id: id, name: name, detail: detail, color: color)
        kindsByID.append(kind)
        for ext in extensions {
            extToKindID[ext] = id
        }
        return id
    }

    private func registerDefaults() {
        // 0: Folder (aggregate fallback when sub-pixel coalescing occurs)
        _ = addKind(
            name: "Folder",
            detail: "Directory container",
            color: RGBColor(124, 146, 172)
        )

        // 1: Free Space
        _ = addKind(
            name: "Free Space",
            detail: "Available capacity on volume",
            color: RGBColor(82, 88, 96)
        )

        // Applications & Packages
        appBundleKindID = addKind(
            name: "Applications & Installers",
            detail: ".app, .pkg, .ipa",
            color: RGBColor(46, 126, 236),
            extensions: ["app", "pkg", "mpkg", "ipa", "xip"]
        )

        // Disk Images & Virtual Machines (crimson/red-orange — classic space hog highlight)
        _ = addKind(
            name: "Disk Images & VMs",
            detail: ".dmg, .iso, .raw, .qcow2, .vmdk, .ipsw",
            color: RGBColor(226, 68, 62),
            extensions: [
                "dmg", "iso", "img", "toast", "cdr", "sparseimage", "sparsebundle",
                "raw", "qcow2", "vmdk", "vdi", "vhd", "vhdx", "ova", "ovf",
                "vmwarevm", "pvm", "utm", "ipsw"
            ]
        )

        // Video & Movies (rich purple/violet)
        _ = addKind(
            name: "Video & Movies",
            detail: ".mp4, .mov, .mkv, .webm, .avi",
            color: RGBColor(156, 84, 226),
            extensions: [
                "mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "flv",
                "mpg", "mpeg", "mts", "m2ts", "ts", "vob", "ogv", "3gp",
                "braw", "r3d", "mxf"
            ]
        )

        // AI / ML Models & Checkpoints (hot magenta — major space consumer on Apple Silicon Macs)
        _ = addKind(
            name: "AI & ML Models",
            detail: ".safetensors, .gguf, .pt, .onnx, .mlmodelc",
            color: RGBColor(224, 72, 158),
            extensions: [
                "safetensors", "gguf", "ggml", "pt", "pth", "onnx", "ckpt",
                "pb", "tflite", "mlmodel", "mlpackage", "mlmodelc", "npz", "npy", "h5", "hdf5"
            ]
        )

        // Archives & Compressed Files (warm amber/gold)
        _ = addKind(
            name: "Archives & Compressed",
            detail: ".zip, .tar, .gz, .zst, .7z, .rar",
            color: RGBColor(230, 162, 44),
            extensions: [
                "zip", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz",
                "zst", "tzst", "7z", "rar", "lz4", "lzma", "cab", "cpio", "sit", "jar", "war"
            ]
        )

        // Developer & Build Artifacts (vivid cyan/teal)
        devBundleKindID = addKind(
            name: "Developer & Build Files",
            detail: "Xcode archives, binaries, dylibs, git packs, caches",
            color: RGBColor(38, 178, 186),
            extensions: [
                "o", "a", "dylib", "so", "dll", "exe", "framework", "xcframework",
                "xcarchive", "dSYM", "dsym", "xcodeproj", "xcworkspace", "playground",
                "swiftmodule", "swiftdoc", "swiftsourceinfo", "pch", "dia", "tbd",
                "pyc", "pyo", "whl", "wasm", "node", "rlib", "rmeta", "pack", "idx", "car", "nib"
            ]
        )

        // Audio & Music (emerald green)
        _ = addKind(
            name: "Audio & Music",
            detail: ".mp3, .m4a, .flac, .wav, .aiff",
            color: RGBColor(54, 188, 106),
            extensions: [
                "mp3", "m4a", "aac", "flac", "alac", "wav", "aiff", "aif",
                "ogg", "oga", "opus", "wma", "caf", "mid", "midi", "stem"
            ]
        )

        // Photos, Images & Design (coral/salmon)
        _ = addKind(
            name: "Images & Design",
            detail: ".heic, .jpg, .png, .raw, .psd, .fig",
            color: RGBColor(234, 112, 76),
            extensions: [
                "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "avif",
                "tiff", "tif", "bmp", "ico", "icns", "svg", "eps",
                "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "raf",
                "psd", "psb", "ai", "indd", "sketch", "fig", "afphoto", "afdesign", "exr", "hdr"
            ]
        )

        // Media Libraries (Photos Library, Logic, Final Cut, iMovie)
        mediaLibraryBundleKindID = addKind(
            name: "Media Libraries & Projects",
            detail: "Photos, Final Cut, Logic, Music libraries",
            color: RGBColor(216, 88, 116),
            extensions: [
                "photoslibrary", "aplibrary", "imovielibrary", "fcpbundle",
                "fcpproject", "logicx", "band", "musiclibrary", "tvlibrary", "ableton"
            ]
        )

        // Databases & Data Tables (indigo)
        _ = addKind(
            name: "Databases & Datasets",
            detail: ".sqlite, .db, .parquet, .duckdb, .csv",
            color: RGBColor(102, 108, 228),
            extensions: [
                "sqlite", "sqlite3", "db", "db3", " sqlite-wal", "wal", "shm",
                "realm", "duckdb", "parquet", "arrow", "feather", "avro", "orc",
                "ldb", "sst", "mdb", "accdb", "rdata", "rds", "csv", "tsv", "jsonl", "ndjson"
            ]
        )

        // Documents & E-Books (sky blue)
        _ = addKind(
            name: "Documents & Books",
            detail: ".pdf, .docx, .pptx, .xlsx, .epub, iWork",
            color: RGBColor(82, 168, 238),
            extensions: [
                "pdf", "epub", "mobi", "azw3", "djvu", "cbz", "cbr",
                "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp",
                "pages", "numbers", "key", "rtf", "rtfd", "txt", "md", "markdown", "tex"
            ]
        )

        // Source Code & Configuration (lime/mint)
        _ = addKind(
            name: "Source Code & Config",
            detail: ".swift, .py, .ts, .rs, .go, .json, .yaml",
            color: RGBColor(126, 196, 82),
            extensions: [
                "swift", "m", "mm", "c", "cc", "cpp", "cxx", "h", "hpp",
                "rs", "go", "py", "pyi", "js", "jsx", "ts", "tsx", "mjs", "cjs",
                "java", "kt", "kts", "scala", "rb", "php", "cs", "fs", "lua", "zig",
                "sh", "zsh", "bash", "fish", "ps1", "sql", "graphql", "proto",
                "html", "htm", "css", "scss", "less", "vue", "svelte",
                "json", "yaml", "yml", "toml", "xml", "plist", "ini", "cfg", "conf", "lock"
            ]
        )

        // 3D & Game Assets
        _ = addKind(
            name: "3D & Game Assets",
            detail: ".usdz, .blend, .fbx, .obj, .pak",
            color: RGBColor(182, 128, 72),
            extensions: [
                "usdz", "usd", "usda", "usdc", "blend", "fbx", "obj", "gltf", "glb",
                "stl", "dae", "3ds", "c4d", "ma", "mb", "pak", "assets", "unity3d", "uasset", "umap"
            ]
        )

        // Logs, Traces & Crash Dumps
        _ = addKind(
            name: "Logs & Diagnostics",
            detail: ".log, .trace, .ips, .crash, .har",
            color: RGBColor(168, 152, 76),
            extensions: [
                "log", "ips", "crash", "spin", "diag", "trace", "har", "pcap", "pcapng", "core", "dmp"
            ]
        )

        // Fonts
        _ = addKind(
            name: "Fonts",
            detail: ".ttf, .otf, .woff, .woff2",
            color: RGBColor(148, 134, 198),
            extensions: ["ttf", "otf", "ttc", "woff", "woff2", "dfont"]
        )

        // Generic macOS Bundles / Packages
        genericPackageKindID = addKind(
            name: "macOS Bundles & Plugins",
            detail: ".bundle, .plugin, .appex, .prefPane",
            color: RGBColor(74, 144, 198),
            extensions: ["bundle", "plugin", "appex", "qlgenerator", "mdimporter", "prefpane", "saver", "kext", "systemextension"]
        )

        // Raw Data / Binaries / Extensionless files
        extensionlessBinaryKindID = addKind(
            name: "Binary & Data Files",
            detail: ".bin, .dat, .cache, or extensionless files",
            color: RGBColor(134, 144, 158),
            extensions: ["bin", "dat", "data", "cache", "tmp", "temp", "bak", "old", "part", "crdownload", "download"]
        )
    }

    /// Known macOS package extensions treated as atomic bundles when "Show Package Contents" is disabled.
    public static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "xcframework", "plugin", "appex",
        "xcodeproj", "xcworkspace", "playground", "xcarchive", "dsym",
        "photoslibrary", "aplibrary", "imovielibrary", "fcpbundle", "logicx", "band",
        "musiclibrary", "tvlibrary", "pages", "numbers", "key", "rtfd",
        "vmwarevm", "pvm", "utm", "sparsebundle", "mpkg", "qlgenerator",
        "prefpane", "saver", "kext", "systemextension", "mlpackage", "mlmodelc"
    ]

    public static func isPackageDirectory(name: String) -> Bool {
        guard let ext = extractLowercaseExtension(from: name) else { return false }
        return packageExtensions.contains(ext)
    }

    public static func extractLowercaseExtension(from fileName: String) -> String? {
        // Ignore leading dot for dotfiles like ".DS_Store" or ".zshrc"
        guard let dotIdx = fileName.lastIndex(of: "."),
              dotIdx > fileName.startIndex else {
            return nil
        }
        let afterDot = fileName.index(after: dotIdx)
        guard afterDot < fileName.endIndex else { return nil }
        let ext = fileName[afterDot...].lowercased()
        guard ext.count <= 24 else { return nil }
        return ext
    }

    public func classify(name: String, isDirectory: Bool, isPackage: Bool) -> UInt16 {
        if isDirectory && !isPackage {
            return Self.directoryKindID
        }

        let ext = Self.extractLowercaseExtension(from: name)

        lock.lock()
        defer { lock.unlock() }

        if let ext {
            if let known = extToKindID[ext] {
                return known
            }
            if isPackage {
                return genericPackageKindID
            }
            if let dyn = dynamicExtToKindID[ext] {
                return dyn
            }
            // Cap dynamic kinds so memory stays bounded even on pathological drives
            if kindsByID.count < 512 {
                var hash: UInt64 = 5381
                for byte in ext.utf8 {
                    hash = ((hash << 5) &+ hash) &+ UInt64(byte)
                }
                let color = dynamicPalette[Int(hash % UInt64(dynamicPalette.count))]
                let id = UInt16(kindsByID.count)
                let label = ".\(ext) Files"
                let kind = FileKind(id: id, name: label, detail: "Files with .\(ext) extension", color: color)
                kindsByID.append(kind)
                dynamicExtToKindID[ext] = id
                return id
            }
            return extensionlessBinaryKindID
        }

        if isPackage {
            return appBundleKindID
        }
        return extensionlessBinaryKindID
    }

    public func kind(for id: UInt16) -> FileKind {
        lock.lock()
        defer { lock.unlock() }
        let idx = Int(id)
        if idx >= 0 && idx < kindsByID.count {
            return kindsByID[idx]
        }
        return kindsByID[Int(extensionlessBinaryKindID)]
    }

    public func allKindsSnapshot() -> [FileKind] {
        lock.lock()
        defer { lock.unlock() }
        return kindsByID
    }
}

