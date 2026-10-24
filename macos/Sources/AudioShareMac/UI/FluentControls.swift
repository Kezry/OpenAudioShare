import AppKit
import SwiftUI

// MARK: - Toggle

struct FluentToggle: View {
    @Binding var isOn: Bool
    let theme: FluentTheme
    var enabled: Bool = true

    var body: some View {
        Button {
            guard enabled else { return }
            withAnimation(.easeOut(duration: 0.12)) { isOn.toggle() }
        } label: {
            ZStack {
                Capsule()
                    .fill(isOn ? theme.accent : theme.toggleOff)
                    .frame(width: 40, height: 20)
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                    .offset(x: isOn ? 10 : -10)
            }
            .frame(width: 40, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

// MARK: - Button

struct FluentButton: View {
    let title: String
    let color: Color
    let theme: FluentTheme
    var width: CGFloat? = nil
    var height: CGFloat = 30
    var enabled: Bool = true
    var fontSize: CGFloat = 12
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: fontSize, weight: .regular))
                .foregroundStyle(enabled ? Color.white : theme.textDisabled)
                .lineLimit(1)
                .frame(maxWidth: width == nil ? .infinity : nil)
                .frame(width: width, height: height)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(enabled ? (hovered ? color.opacity(0.88) : color) : theme.buttonDisabled)
                )
                .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovered = $0 && enabled }
    }
}

// MARK: - Combo box

struct FluentComboBox<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let label: (Item) -> String
    let theme: FluentTheme
    var width: CGFloat
    var enabled: Bool = true
    var fontSize: CGFloat = 12
    @State private var hovered = false

    var body: some View {
        Menu {
            ForEach(items, id: \.self) { item in
                Button {
                    selection = item
                } label: {
                    if item == selection {
                        Label(label(item), systemImage: "checkmark")
                    } else {
                        Text(label(item))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(label(selection))
                    .font(.system(size: fontSize))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(enabled ? theme.textPrimary : theme.textDisabled)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(.horizontal, 8)
            .frame(width: width, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(theme.fieldBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(hovered && enabled ? theme.fieldHoverBorder : theme.fieldBorder,
                            lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovered = $0 }
        .opacity(enabled ? 1 : 0.62)
    }
}

// MARK: - Text field

struct FluentTextField: View {
    @Binding var text: String
    let theme: FluentTheme
    var enabled: Bool = true
    var readOnly: Bool = false
    var fontSize: CGFloat = 12
    var onSubmit: () -> Void = {}
    @State private var hovered = false

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: fontSize))
            .foregroundStyle(enabled ? theme.textPrimary : theme.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(theme.fieldBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(hovered && enabled && !readOnly ? theme.fieldHoverBorder : theme.fieldBorder,
                            lineWidth: 1)
            )
            .disabled(!enabled)
            .onSubmit(onSubmit)
            .onHover { hovered = $0 }
    }
}

// MARK: - Slider

struct FluentSlider: View {
    @Binding var value: Double
    let theme: FluentTheme
    var range: ClosedRange<Double>
    var width: CGFloat
    var enabled: Bool = true

    var body: some View {
        Slider(value: $value, in: range)
            .tint(theme.accent)
            .controlSize(.small)
            .frame(width: width, height: 16)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
    }
}

// MARK: - Labels

struct SectionLabel: View {
    let text: String
    let theme: FluentTheme
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 1)
    }
}

struct InlineLabel: View {
    let text: String
    let theme: FluentTheme
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(theme.textSecondary)
            .fixedSize()
    }
}

// MARK: - Progress

struct SmallSpinner: View {
    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.small)
            .scaleEffect(0.55)
            .frame(width: 14, height: 14)
    }
}

// MARK: - Window drag

struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            self
        }
    }

    func makeNSView(context: Context) -> DragView {
        DragView()
    }

    func updateNSView(_ nsView: DragView, context: Context) {}
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}
