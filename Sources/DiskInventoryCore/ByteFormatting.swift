import Foundation

public enum ByteFormatting {
    /// Fast, allocation-light human-readable byte formatter using decimal macOS Finder units (1 GB = 1,000,000,000 bytes).
    public static func format(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 B" }
        let absBytes = Double(bytes)

        if absBytes < 1_000 {
            return "\(bytes) B"
        } else if absBytes < 1_000_000 {
            let kb = absBytes / 1_000.0
            return kb >= 100 ? String(format: "%.0f KB", kb) : String(format: "%.1f KB", kb)
        } else if absBytes < 1_000_000_000 {
            let mb = absBytes / 1_000_000.0
            return mb >= 100 ? String(format: "%.0f MB", mb) : String(format: "%.1f MB", mb)
        } else if absBytes < 1_000_000_000_000 {
            let gb = absBytes / 1_000_000_000.0
            return gb >= 100 ? String(format: "%.1f GB", gb) : String(format: "%.2f GB", gb)
        } else {
            let tb = absBytes / 1_000_000_000_000.0
            return String(format: "%.2f TB", tb)
        }
    }

    public static func formatCount(_ count: Int, singular: String = "item", plural: String = "items") -> String {
        let formatted = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
        return "\(formatted) \(count == 1 ? singular : plural)"
    }
}

