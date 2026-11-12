# Disk Inventory (Apple Silicon Native Clone)

A clean-room, native `arm64` macOS rewrite of **Disk Inventory X** built with Swift, AppKit, and SwiftUI for modern macOS and Apple Silicon.

Designed specifically to help inspect storage usage and safely reclaim space on local APFS drives (such as 1 TB MacBooks) without legacy Intel/Rosetta dependencies.

## Highlights

- **Squarified 3D Cushion Treemaps**: Implements van Wijk & van de Wetering's parabolic cushion shading in a multi-core Retina rasterizer, color-coded by file Kind.
- **Accurate APFS Physical Space Accounting**:
  - Defaults to **Size on Disk** (`st_blocks * 512`), distinguishing real SSD space from sparse files and zero-byte cloud-evicted iCloud placeholders (`SF_DATALESS`).
  - Deduplicates hard links (`st_nlink > 1`) and skips duplicate APFS firmlink mounts (`/System/Volumes/Data`) so 1 TB drives are never double-counted.
  - **Configurable Folder Exclusions**: Automatically skips `~/Library/CloudStorage` (Google Drive, OneDrive, Dropbox, Box FileProvider mounts) by default so cloud directory enumeration never stalls local scans, with one-click presets (`iCloud Drive`, `Photos Library`, `.Trash`, `/System`, `.git`) plus custom folder paths and folder-name rules (`⌘,`).
  - Treats macOS bundles (`.app`, `.photoslibrary`, `.xcodeproj`, etc.) as unified items by default, with a toolbar toggle to drill inside package contents anytime.
- **Three-Pane Synchronized Workspace**:
  - **Left**: Virtualized hierarchical folder/file outline with inline usage bars.
  - **Center**: Interactive Cushion Treemap with zero-latency hover, selection highlights, double-click zoom, breadcrumb navigation, and right-click actions.
  - **Right**: Tabbed Inspector featuring **Kinds** (click any Kind to highlight across the treemap), **Largest** (instant branch-and-bound Top Space Hogs finder with size filters `50 MB+` to `5 GB+`), and **Info** (metadata, Quick Look, Reveal in Finder, and safe Move to Trash).
- **Safe Cleanup Guardrails**:
  - Protects critical macOS and top-level user directories from accidental removal.
  - Moves selected files/folders to **macOS Trash** after explicit confirmation and updates all ancestor directory sizes and the treemap instantaneously without rescanning.

## Build & Run

Build the signed native Apple Silicon `.app` bundle:

```bash
./scripts/build_app.sh
```

Launch the app:

```bash
open "dist/Disk Inventory.app"
```

Optionally install into `/Applications`:

```bash
cp -R "dist/Disk Inventory.app" /Applications/
```

## Run Unit Tests

```bash
swift test
```

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `⌘O` | Scan Specific Folder… |
| `⌘,` | Excluded Folders & Scan Settings… |
| `⇧⌘N` | Volume & Preset Picker |
| `⌘R` | Rescan Current Root |
| `⌘]` | Zoom Into Selected Folder |
| `⌘[` | Zoom Out to Parent Folder |
| `⌘↑` | Select Enclosing Folder |
| `⌘Y` | Quick Look Preview |
| `⇧⌘R` | Reveal in Finder |
| `⌘⌫` | Move Selected Item to Trash… |

## License

Released under the [MIT License](LICENSE). This project is an independent clean-room implementation inspired by—and not affiliated with—Tjark Derlien's original Disk Inventory X.


