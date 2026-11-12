import SwiftUI
import DiskInventoryCore

extension DiskInventoryCore.RGBColor {
    var swiftUIColor: Color {
        Color(
            .sRGB,
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            opacity: 1.0
        )
    }
}
