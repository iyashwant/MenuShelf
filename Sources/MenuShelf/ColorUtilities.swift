import AppKit
import SwiftUI

extension NSColor {
    convenience init?(hexString: String) {
        var raw = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") {
            raw.removeFirst()
        }

        guard raw.count == 6, let value = Int(raw, radix: 16) else { return nil }
        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    var hexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        return String(
            format: "#%02X%02X%02X",
            Int(round(color.redComponent * 255)),
            Int(round(color.greenComponent * 255)),
            Int(round(color.blueComponent * 255))
        )
    }
}

extension Color {
    init(hexString: String?) {
        if let hexString, let color = NSColor(hexString: hexString) {
            self.init(nsColor: color)
        } else {
            self.init(nsColor: .controlAccentColor)
        }
    }

    var hexString: String? {
        NSColor(self).hexString
    }
}
