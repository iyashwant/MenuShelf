import SwiftUI

struct VisualEffectView: NSViewRepresentable {
  let visualEffectView = NSVisualEffectView()

  var material: NSVisualEffectView.Material = .popover
  var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

  func makeNSView(context: Context) -> NSVisualEffectView {
    return visualEffectView
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {
    visualEffectView.material = material
    visualEffectView.blendingMode = blendingMode
  }
}

@available(macOS 26.0, *)
struct GlassEffectView: NSViewRepresentable {
  let glassEffectView = NSGlassEffectView()

  var style: NSGlassEffectView.Style = .regular

  func makeNSView(context: Context) -> NSGlassEffectView {
    return glassEffectView
  }

  func updateNSView(_ view: NSGlassEffectView, context: Context) {
    glassEffectView.style = style
  }
}

// MenuShelf: the list and the preview card each get their own glass, and
// both sit in one `GlassEffectContainer`. Where the card touches the list the
// two merge into a single piece; the space around the card stays see-through.
enum PanelGlass {
  static let cornerRadius = Popup.cornerRadius + Popup.horizontalPadding
}

#Preview {
  VisualEffectView(
    material: .popover,
    blendingMode: .behindWindow
  )
}
