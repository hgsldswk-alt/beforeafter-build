import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum Theme {
    static let paper = Color(uiColor: Palette.paper)
    static let surface = Color(uiColor: Palette.surface)
    static let ink = Color(uiColor: Palette.ink)
    static let muted = Color(uiColor: Palette.muted)
    static let green = Color(uiColor: Palette.green)
    static let soft = Color(uiColor: Palette.soft)
    static let line = Color(uiColor: Palette.line)
    static let tile = Color(uiColor: Palette.tile)
}

struct PrimaryButton: View {
    let title: String
    let id: String
    var symbol: String?
    let action: () -> Void

    init(_ title: String, id: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.id = id
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
                Text(L.t(title)).multilineTextAlignment(.center)
            }
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(Theme.green, in: RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .modifier(DisabledOpacity())
    }
}

private struct DisabledOpacity: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    func body(content: Content) -> some View { content.opacity(enabled ? 1 : 0.45) }
}

struct TextAction: View {
    let title: String
    let id: String
    var symbol: String?
    let action: () -> Void

    init(_ title: String, id: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.id = id
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
                Text(L.t(title))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.green)
            .padding(.horizontal, 5)
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .modifier(DisabledOpacity())
    }
}

struct TopBar<Leading: View, Trailing: View>: View {
    let title: String?
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            leading()
            Spacer(minLength: 0)
            if let title {
                Text(L.t(title))
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            trailing()
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 49)
    }
}

struct InlineMessage: View {
    let key: String
    var body: some View {
        Text(L.t(key))
            .font(.footnote)
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("status.message")
    }
}

struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL
    let close: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in close() }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct SaveToFiles: UIViewControllerRepresentable {
    let url: URL
    let close: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(close: close) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let close: () -> Void
        init(close: @escaping () -> Void) { self.close = close }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { close() }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { close() }
    }
}

struct PanelFrame<Content: View>: View {
    let title: String
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: title) {
                Color.clear.frame(width: 44, height: 1).accessibilityHidden(true)
            } trailing: {
                TextAction("action.done", id: "panel.done") { dismiss() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14, content: content)
                    .frame(maxWidth: 590, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Theme.paper.ignoresSafeArea())
        .foregroundStyle(Theme.ink)
    }
}

struct RowAction: View {
    let title: String
    let id: String
    var detail: String?
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.body.weight(.semibold))
                    if let detail { Text(detail).font(.footnote).foregroundStyle(Theme.muted) }
                }
                Spacer()
                Image(systemName: selected ? "checkmark" : "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.green)
                    .accessibilityHidden(true)
            }
            .multilineTextAlignment(.leading)
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(selected ? Theme.soft : Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line) }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .modifier(DisabledOpacity())
    }
}
