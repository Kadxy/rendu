import SwiftUI

/// A Health category glyph, drawn as the Health app draws it: its symbol
/// (HKDisplayCategory) filled, in multicolor — the symbol's own colors
/// where it has them (red heart, gray magnifying glass, lighter pillows),
/// the category's color elsewhere. Checked against a screenshot of
/// Health's Browse page. Some symbols are private system symbols
/// (SwiftUI's internal lookup loads them); public look-alikes stand in if
/// that lookup ever fails.
struct CategoryIcon: View {
    let category: HealthCategory
    var size: CGFloat = 20
    /// Leading in list rows, so names line up; centered on a tile.
    var alignment: Alignment = .leading

    var body: some View {
        symbol
            .symbolRenderingMode(.multicolor)
            .foregroundStyle(category.color)
            .font(.system(size: size, weight: .semibold))
            .frame(width: size * 1.4, height: size * 1.2, alignment: alignment)
    }

    /// The filled variant where there is one, as symbolVariant(.fill) picks
    /// it (which doesn't reach private symbols).
    private var symbol: Image {
        for name in [category.symbol + ".fill", category.symbol] {
            if UIImage(systemName: name) != nil {
                return Image(systemName: name)
            }
            if PrivateSymbols.exists(name) {
                return Image(_internalSystemName: name)
            }
        }
        return Image(systemName: category.fallbackSymbol)
    }
}

@MainActor
private enum PrivateSymbols {
    private static var known: [String: Bool] = [:]

    static func exists(_ name: String) -> Bool {
        if let cached = known[name] { return cached }
        let selector = NSSelectorFromString("_systemImageNamed:")
        let found = UIImage.responds(to: selector) && UIImage.perform(selector, with: name)?.takeUnretainedValue() != nil
        known[name] = found
        return found
    }
}

/// A white glyph on a tinted Liquid Glass circle, for the Summary cards.
struct GlassIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 52

    var body: some View {
        Image(systemName: symbol)
            .glassIcon(tint: tint, size: size)
    }
}

extension View {
    func glassIcon(tint: Color, size: CGFloat) -> some View {
        font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .tintedGlass(tint)
    }

    /// A circle of Liquid Glass tinted `tint`, whose tint animates: a glass
    /// tint changes at once, so the color is interpolated here, frame by
    /// frame, and handed to the glass each time.
    func tintedGlass(_ tint: Color) -> some View {
        modifier(TintedGlass(tint: tint))
    }
}

private struct TintedGlass: ViewModifier {
    let tint: Color
    @Environment(\.self) private var environment

    func body(content: Content) -> some View {
        content.modifier(AnimatedTint(color: tint.resolve(in: environment)))
    }

    private struct AnimatedTint: ViewModifier, Animatable {
        var color: Color.Resolved

        var animatableData: Color.Resolved.AnimatableData {
            get { color.animatableData }
            set { color.animatableData = newValue }
        }

        func body(content: Content) -> some View {
            content.glassEffect(.regular.tint(Color(color)), in: .circle)
        }
    }
}

/// A settings row's icon, as in iOS Settings: a white glyph on a rounded
/// square of tinted Liquid Glass.
struct SettingsIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .glassEffect(.regular.tint(tint), in: .rect(cornerRadius: size * 0.26, style: .continuous))
    }
}

/// A tinted glyph on a pale square of the same tint, for list rows (logs).
struct SoftIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

/// Apple's own display name in the app's language as the title, the
/// HealthKit identifier (without its prefix) underneath. Types Apple doesn't
/// name show the identifier alone — never a home-made translation.
struct TypeName: View {
    let identifier: String
    var subtitle = true

    var body: some View {
        let short = DisplayNames.shortName(identifier)
        let localized = DisplayNames.localized(identifier)
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: localized ?? short)
                .lineLimit(1)
            if subtitle, localized != nil {
                Text(verbatim: short)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

/// A type row: names and a trailing count (compact, or with a spinner while
/// that type is uploading).
struct TypeRow: View {
    let identifier: String
    let count: Int
    var active = false
    var subtitle = true

    var body: some View {
        HStack(spacing: 12) {
            TypeName(identifier: identifier, subtitle: subtitle)
            Spacer(minLength: 8)
            if active {
                ProgressView()
                    .controlSize(.small)
            }
            Text(verbatim: SampleFormat.compactCount(count))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// A Health "Details" row: small secondary label above the value, at
/// Health's row height. Long-press copies the value.
struct DetailRow: View {
    let label: Text
    let value: String
    var monospaced = false
    @State private var copied = HapticEvent()

    init(_ label: LocalizedStringKey, _ value: String, monospaced: Bool = false) {
        self.label = Text(label)
        self.value = value
        self.monospaced = monospaced
    }

    init(verbatim label: String, _ value: String, monospaced: Bool = false) {
        self.label = Text(verbatim: label)
        self.value = value
        self.monospaced = monospaced
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            label
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(monospaced ? .body.monospaced() : .body)
        }
        .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
        .contextMenu {
            Button {
                UIPasteboard.general.string = value
                copied.play(.impact(weight: .light))
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
        .haptic(copied)
    }
}

/// A tappable area in a card: shows a clear gray highlight while pressed,
/// like a list row (SwiftUI's plain style only dims the text).
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(.systemGray4) : .clear)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { .init() }
}

extension View {
    /// A card row's padding, filling the card's width so all of it is
    /// tappable.
    func cardRow() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
    }

    /// The card itself; clips pressed highlights to its corners.
    /// iOS Settings' grouped sections: 25 pt continuous corners (matched
    /// against a screenshot of Settings, pixel for pixel).
    func cardBackground() -> some View {
        background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
    }
}

extension Date {
    /// "13:05" today, "Yesterday 13:05", "Sep 18 13:05" — like Health lists.
    var listStamp: String {
        let calendar = Calendar.current
        let time = formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(self) { return time }
        if calendar.isDateInYesterday(self) {
            return "\(String(localized: "Yesterday")) \(time)"
        }
        let sameYear = calendar.isDate(self, equalTo: .now, toGranularity: .year)
        return sameYear
            ? formatted(.dateTime.month().day().hour().minute()) : formatted(.dateTime.year().month().day().hour().minute())
    }
}

/// Health's Browse search field: a gray capsule in the page that turns to
/// floating Liquid Glass once it's pinned at the top or in use. While
/// searching, a close button beside it clears and ends the search.
struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    /// Searching: focused, or holding a query.
    var active: Bool
    /// Pinned over scrolled content.
    var floating: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.primary)
                TextField(HealthUIStrings.localized("SEARCH_PLACEHOLDER") ?? "Search", text: $text)
                    .fontWeight(.medium)
                    .focused(focused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Clear"))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(Color(.tertiarySystemFill).opacity(floating || active ? 0 : 1), in: .capsule)
            .glassEffect(floating || active ? .regular.interactive() : .identity, in: .capsule)
            if active {
                Button {
                    text = ""
                    focused.wrappedValue = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel(Text("Cancel"))
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: active)
        .animation(.smooth(duration: 0.2), value: floating)
    }
}

/// The disclosure chevron of a navigation row, for rows built by hand.
struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
    }
}

/// Pretty, syntax-colored JSON (keys in a sensible order), for reading what
/// the server stores.
struct JSONText: View {
    let json: JSON

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(Self.render(json))
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.vertical, 4)
        }
    }

    private static let leadingKeys = [
        "uuid", "kind", "type", "startDate", "endDate", "quantity", "value", "valueName",
        "objects", "sourceRevision", "device", "metadata",
    ]

    static func render(_ json: JSON, indent: Int = 0) -> AttributedString {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        func plain(_ text: String) -> AttributedString { AttributedString(text) }
        func colored(_ text: String, _ color: Color) -> AttributedString {
            var string = AttributedString(text)
            string.foregroundColor = color
            return string
        }
        switch json {
        case .string(let value): return colored(quoted(value), Color(red: 0.77, green: 0.25, blue: 0.20))
        case .number(let value):
            return colored(
                value.formatted(
                    .number.grouping(.never).precision(.fractionLength(0 ... 6)).locale(Locale(identifier: "en_US_POSIX"))), .blue
            )
        case .bool(let value): return colored(value ? "true" : "false", .purple)
        case .null: return colored("null", .purple)
        case .array(let items):
            guard !items.isEmpty else { return plain("[]") }
            var out = plain("[\n")
            for (index, item) in items.enumerated() {
                out += plain(inner) + render(item, indent: indent + 1) + plain(index < items.count - 1 ? ",\n" : "\n")
            }
            return out + plain(pad + "]")
        case .object(let object):
            guard !object.isEmpty else { return plain("{}") }
            let keys = leadingKeys.filter { object[$0] != nil } + object.keys.filter { !leadingKeys.contains($0) }.sorted()
            var out = plain("{\n")
            for (index, key) in keys.enumerated() {
                out += plain(inner) + colored(quoted(key), .secondary) + plain(": ")
                out += render(object[key]!, indent: indent + 1) + plain(index < keys.count - 1 ? ",\n" : "\n")
            }
            return out + plain(pad + "}")
        }
    }

    private static func quoted(_ string: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let data = (try? encoder.encode(string)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The same layout as plain text, for copying.
    static func text(_ json: JSON) -> String {
        String(render(json).characters)
    }
}

/// A brief confirmation at the bottom of the screen ("Copied JSON"). Each
/// show() counts, even of the same message: it plays again and stays its
/// full time.
struct Toast: Equatable {
    private(set) var message: LocalizedStringKey?
    private(set) var id = 0

    mutating func show(_ message: LocalizedStringKey) {
        self.message = message
        id += 1
    }

    mutating func hide() {
        message = nil
    }
}

struct ToastModifier: ViewModifier {
    @Binding var toast: Toast

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message = toast.message {
                Label {
                    Text(message)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolEffect(.bounce, value: toast.id)
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect()
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: toast.message != nil)
        // Restarted by every show(); the last one hides it.
        .task(id: toast.id) {
            guard toast.message != nil else { return }
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation { toast.hide() }
        }
        // Copying, mostly: a light tap with each confirmation.
        .haptic(trigger: toast.id) { _, _ in toast.message == nil ? nil : .impact(weight: .light) }
    }
}

extension View {
    func toast(_ toast: Binding<Toast>) -> some View {
        modifier(ToastModifier(toast: toast))
    }
}
