//
//  MenuShelfPickerSupport.swift
//  MenuShelf
//
//  Tiny helpers used by the picker view. Ported from Browserino. MIT.
//

import SwiftUI
import AppKit

// MARK: - Background

struct MenuShelfBlurredView: NSViewRepresentable {
    func makeNSView(context: Context) -> some NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        return view
    }

    func updateNSView(_ nsView: NSViewType, context: Context) {}
}

// MARK: - View+If

extension View {
    @ViewBuilder
    func msIf<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// MARK: - Button styles

struct MSBackgroundOnHover: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(isHovered ? Color.secondary.opacity(0.5) : .clear)
            .onHover { isHovered in
                withAnimation { self.isHovered = isHovered }
            }
    }
}

struct MSSelectButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Self.Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerSize: CGSize(width: 8, height: 8)))
            .foregroundStyle(self.selected ? Color.white : Color.primary)
            .background(configuration.isPressed || selected ? Color.accentColor : .clear)
            .modifier(MSBackgroundOnHover())
            .cornerRadius(8)
    }
}

// MARK: - Tooltip

struct MSTooltip: NSViewRepresentable {
    let tooltip: String

    func makeNSView(context: NSViewRepresentableContext<MSTooltip>) -> NSView {
        let view = NSView()
        view.toolTip = tooltip
        return view
    }

    func updateNSView(_ nsView: NSView, context: NSViewRepresentableContext<MSTooltip>) {}
}

extension View {
    func msToolTip(_ tip: String) -> some View {
        self.overlay(MSTooltip(tooltip: tip))
    }
}
