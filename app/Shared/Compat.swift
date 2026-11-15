import SwiftUI
import Combine
import WidgetKit

/// `Animation.snappy` and `.smooth` are iOS 17; springs and ease-in-out carry the same feel before.
extension Animation {
    static var compatSnappy: Animation { compatSnappy(duration: 0.4) }

    static func compatSnappy(duration: TimeInterval = 0.4) -> Animation {
        if #available(iOS 17.0, *) {
            return .snappy(duration: duration)
        }
        return .spring(response: duration, dampingFraction: 0.85)
    }

    static func compatSmooth(duration: TimeInterval = 0.4) -> Animation {
        if #available(iOS 17.0, *) {
            return .smooth(duration: duration)
        }
        return .easeInOut(duration: duration)
    }
}

/// iOS 16 backports.
///
/// The app used to be an iOS 17 project, so a handful of SwiftUI APIs were taken for granted.
/// Each shim below either calls the system API (when the running system has it) or rebuilds it
/// from iOS 16 building blocks. Call sites keep their shape, which keeps the diff readable.

// MARK: - ContentUnavailableView (iOS 17)

/// Stand-in for `ContentUnavailableView`: a symbol, a title, a line of detail and optional
/// actions, centred in the space it is given.
struct CompatContentUnavailableView: View {
    private let label: AnyView
    private let detail: AnyView?
    private let actions: AnyView?

    private init(label: AnyView, detail: AnyView? = nil, actions: AnyView? = nil) {
        self.label = label
        self.detail = detail
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 10) {
            label
            if let detail {
                detail
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let actions {
                actions.padding(.top, 8)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension CompatContentUnavailableView {
    init(_ title: LocalizedStringKey, systemImage: String, description: Text? = nil) {
        self.init(
            label: AnyView(VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 46, weight: .regular))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title3.weight(.semibold))
            }),
            detail: description.map { AnyView($0) }
        )
    }

    init<S: StringProtocol>(_ title: S, systemImage: String, description: Text? = nil) {
        self.init(
            label: AnyView(VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 46, weight: .regular))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title3.weight(.semibold))
            }),
            detail: description.map { AnyView($0) }
        )
    }

    init<L: View>(@ViewBuilder label: () -> L) {
        self.init(label: AnyView(label()))
    }

    init<L: View, D: View>(@ViewBuilder label: () -> L, @ViewBuilder description: () -> D) {
        self.init(label: AnyView(label()), detail: AnyView(description()))
    }

    init<L: View, A: View>(@ViewBuilder label: () -> L, @ViewBuilder actions: () -> A) {
        self.init(label: AnyView(label()), actions: AnyView(actions()))
    }

    init<L: View, D: View, A: View>(
        @ViewBuilder label: () -> L,
        @ViewBuilder description: () -> D,
        @ViewBuilder actions: () -> A
    ) {
        self.init(label: AnyView(label()), detail: AnyView(description()), actions: AnyView(actions()))
    }

    static func search(text: String) -> CompatContentUnavailableView {
        CompatContentUnavailableView(
            label: AnyView(VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 46, weight: .regular))
                    .foregroundStyle(.secondary)
                Text("没有找到“\(text)”")
                    .font(.title3.weight(.semibold))
            })
        )
    }

    static var search: CompatContentUnavailableView { search(text: "") }
}

// MARK: - onChange, two-parameter form (iOS 17)

/// The two-parameter `onChange` (old value, new value) arrived in iOS 17. The one-parameter
/// system version is still there on iOS 16, so only those call sites that read the old value
/// are routed through this modifier.
struct OnChangeCompat<V: Equatable>: ViewModifier {
    let value: V
    let initial: Bool
    let action: (V, V) -> Void

    @State private var previous: V?
    @State private var seen = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !seen else { return }
                seen = true
                previous = value
                if initial { action(value, value) }
            }
            .onChange(of: value) { new in
                let old = previous ?? new
                previous = new
                if seen {
                    action(old, new)
                } else {
                    seen = true
                    if initial { action(new, new) }
                }
            }
    }
}

extension View {
    func onChangeCompat<V: Equatable>(
        of value: V,
        initial: Bool = false,
        _ action: @escaping (V, V) -> Void
    ) -> some View {
        modifier(OnChangeCompat(value: value, initial: initial, action: action))
    }
}

// MARK: - onGeometryChange (iOS 18)

/// `onGeometryChange` arrived in iOS 18. A background `GeometryReader` feeding a preference
/// gives the same "tell me this measurement when it changes" contract on iOS 16.
struct OnGeometryChangeCompat<T: Equatable>: ViewModifier {
    let transform: (GeometryProxy) -> T
    let action: (T) -> Void

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: GeometryValueKey<T>.self, value: transform(proxy))
                }
            )
            .onPreferenceChange(GeometryValueKey<T>.self) { value in
                // The key's default is nil, so "no measurement yet" never fires the action.
                if let value { action(value) }
            }
    }
}

struct GeometryValueKey<T: Equatable>: PreferenceKey {
    static var defaultValue: T? { nil }
    static func reduce(value: inout T?, nextValue: () -> T?) {
        if let next = nextValue() { value = next }
    }
}

extension View {
    func onGeometryChangeCompat<T: Equatable>(
        for type: T.Type,
        of transform: @escaping (GeometryProxy) -> T,
        action: @escaping (T) -> Void
    ) -> some View {
        modifier(OnGeometryChangeCompat(transform: transform, action: action))
    }
}

// MARK: - Sheet presentation (iOS 16.4)

extension View {
    /// `presentationBackground` is iOS 16.4; before that the sheet keeps the system background.
    @ViewBuilder
    func compatPresentationBackground<S: ShapeStyle>(_ style: S) -> some View {
        if #available(iOS 16.4, *) {
            presentationBackground(style)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatPresentationCornerRadius(_ radius: CGFloat) -> some View {
        if #available(iOS 16.4, *) {
            presentationCornerRadius(radius)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatPresentationBackgroundInteraction() -> some View {
        if #available(iOS 16.4, *) {
            presentationBackgroundInteraction(.enabled)
        } else {
            self
        }
    }

    /// `scrollBounceBehavior` is iOS 16.4 too. Before that the default bounce is kept.
    @ViewBuilder
    func compatScrollBounceBehavior(always: Bool = false) -> some View {
        if #available(iOS 16.4, *) {
            scrollBounceBehavior(always ? .always : .basedOnSize)
        } else {
            self
        }
    }

    /// `symbolEffect` is iOS 17: without it the symbol simply stays still.
    @ViewBuilder
    func compatSymbolEffectBounce<V: Equatable>(value: V) -> some View {
        if #available(iOS 17.0, *) {
            symbolEffect(.bounce, value: value)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatSymbolEffectVariableColor(active: Bool) -> some View {
        if #available(iOS 17.0, *) {
            symbolEffect(.variableColor.iterative, isActive: active)
        } else {
            self
        }
    }

    /// `defaultScrollAnchor` is iOS 17. Before that a scroll view keeps its own default,
    /// which is the top: the timeline is scrolled to its end by `ConversationView` instead.
    @ViewBuilder
    func compatDefaultScrollAnchor(_ anchor: UnitPoint) -> some View {
        if #available(iOS 17.0, *) {
            defaultScrollAnchor(anchor)
        } else {
            self
        }
    }

    /// `scrollIndicatorsFlash` is iOS 17: without it the indicators are simply left alone.
    @ViewBuilder
    func compatScrollIndicatorsFlash() -> some View {
        if #available(iOS 17.0, *) {
            scrollIndicatorsFlash(onAppear: true)
        } else {
            self
        }
    }

    /// `containerBackground(_:for: .widget)` is iOS 17. Before that a widget paints its own
    /// background: the system still clips it to the widget's shape, so the same colour goes
    /// behind the content instead.
    @ViewBuilder
    func compatWidgetBackground<S: View>(_ background: S) -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(background, for: .widget)
        } else {
            self.background(background)
        }
    }

    /// The accessory families ask for a clear container background: on iOS 16 there is no
    /// container to clear, and painting nothing is the same thing.
    @ViewBuilder
    func compatWidgetClearBackground() -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(for: .widget) { Color.clear }
        } else {
            self
        }
    }
}
