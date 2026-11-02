import SwiftUI
import RelayCore

/// A card or drawer drawn inside the window, above the current page. Used instead of `.sheet` for panels opened
/// from the dashboard and the sidebar: a sheet disables the window's close button and dims the title bar, which
/// reads as broken traffic lights; this keeps the window chrome untouched and the page visible underneath.
struct RelayOverlay: Identifiable {
    enum Style { case card, drawer }
    var id: String
    var style: Style = .card
    var width: CGFloat = 560
    var content: AnyView
}

extension RelayAppModel {
    /// Shows `content` above the page, replacing any overlay already open. Content should read live state from
    /// `model` in its own body (pass ids, not run values) so it keeps updating while it is open.
    func present<Content: View>(_ id: String, style: RelayOverlay.Style = .card, width: CGFloat = 560, @ViewBuilder _ content: () -> Content) {
        overlay = RelayOverlay(id: id, style: style, width: width, content: AnyView(content()))
    }
    func dismissOverlay() { overlay = nil }
}

/// Draws `model.overlay` and the composer: a dimmed backdrop (click to close), Esc closes, and the card or drawer
/// springs in. Lives at the root so it covers the sidebar and page but never the title bar buttons.
struct RelayOverlayHost: View {
    @Bindable var model: RelayAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let available = geometry.size.height - 48
            ZStack {
                if model.overlay != nil || model.showsComposer {
                    Color.black.opacity(0.22).ignoresSafeArea()
                        .onTapGesture { close() }
                        .transition(.opacity)
                    Button("", action: close).keyboardShortcut(.cancelAction).opacity(0).allowsHitTesting(false)
                }
                // A card keeps its own height (up to the window); the outer frame only centres it.
                if model.showsComposer, !model.legacyComposer, model.workforce != nil {
                    RelayDispatchComposer(model: model)
                        .modifier(RelayOverlayChrome())
                        .frame(height: available)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else if model.showsComposer {
                    RelayComposer(model: model)
                        .modifier(RelayOverlayChrome())
                        .frame(height: available)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else if let overlay = model.overlay {
                    switch overlay.style {
                    case .card:
                        overlay.content
                            .frame(width: min(overlay.width, geometry.size.width - 48))
                            .modifier(RelayOverlayChrome())
                            .frame(height: available)
                            .id(overlay.id)
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    case .drawer:
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            overlay.content
                                .frame(width: min(overlay.width, geometry.size.width - 60))
                                .frame(maxHeight: .infinity)
                                .background(RelayStyle.canvas)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(RelayStyle.border))
                                .shadow(color: .black.opacity(0.18), radius: 28, x: -6)
                                .padding(10)
                                .id(overlay.id)
                        }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.9), value: model.overlay?.id)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.9), value: model.showsComposer)
    }

    private func close() {
        if model.showsComposer { model.showsComposer = false } else { model.overlay = nil }
    }
}

private struct RelayOverlayChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RelayStyle.canvas)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(RelayStyle.border))
            .shadow(color: .black.opacity(0.2), radius: 30, y: 12)
    }
}

/// Title row of an overlay card: icon tile, title and subtitle, trailing accessory, close button.
struct RelayOverlayHeader<Trailing: View>: View {
    var icon: String
    var color: Color = .primary
    var title: String
    var subtitle: String = ""
    var close: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            DravionIcon(name: icon, duotone: true, size: 18).foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                if !subtitle.isEmpty { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            trailing
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 26, height: 26).background(Color.primary.opacity(0.06), in: Circle())
            }.buttonStyle(.plain).help("关闭（Esc）").accessibilityLabel("关闭")
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }
}

extension RelayOverlayHeader where Trailing == EmptyView {
    init(icon: String, color: Color = .primary, title: String, subtitle: String = "", close: @escaping () -> Void) {
        self.init(icon: icon, color: color, title: title, subtitle: subtitle, close: close) { EmptyView() }
    }
}

/// Content at its natural height when it fits, scrolling once it does not: a card sized to what it shows.
struct RelayFitScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
    }
}
