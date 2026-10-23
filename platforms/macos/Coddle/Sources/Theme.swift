import SwiftUI
import AppKit

/// Supported visual themes for Coddle.
public enum CoddleTheme: String, Codable, CaseIterable, Identifiable {
    /// Liquid Glass-inspired surfaces with native glass controls on macOS 26+:
    /// 14pt continuous squircle, multi-stop refractive specular rim,
    /// top-lit curved glass sheen, dual-layer ambient diffusion + contact shadow.
    case liquidGlass = "liquidGlass"

    /// Native macOS clean card look:
    /// 10pt continuous squircle, flat control surface fill, uniform separator stroke, subtle shadow.
    case classic = "classic"

    public var id: String { rawValue }

    /// The default theme for Coddle.
    public static let `default`: CoddleTheme = .liquidGlass

    /// Tolerant initializer with fallback to `.default` for unknown keys.
    public init(key: String) {
        self = CoddleTheme(rawValue: key) ?? .default
    }

    /// Key for localized name in strings catalog.
    public var localizationKey: String {
        switch self {
        case .liquidGlass: return "theme.liquidGlass"
        case .classic:     return "theme.classic"
        }
    }

    /// Design tokens for this theme.
    public var tokens: CoddleThemeTokens {
        switch self {
        case .liquidGlass: return LiquidGlassTokens()
        case .classic:     return ClassicTokens()
        }
    }
}

// MARK: - Strict 4-Tier Typography Scale

/// Unified typography tokens eliminating mixed font sizes across rows and cards.
public enum CoddleTypography {
    /// 28pt Bold Rounded — Hero battery percentage only.
    public static let heroMetric = Font.system(size: 28, weight: .bold, design: .rounded)
    /// 11pt Semibold — Card section headers.
    public static let sectionHeader = Font.system(size: 11, weight: .semibold)
    /// 12.5pt Regular — Primary label for ALL interactive rows (Toggle, Picker, Stepper).
    public static let controlLabel = Font.system(size: 12.5, weight: .regular)
    /// 11.5pt Medium — Right-aligned numeric values, segmented pills, and status pills.
    public static let controlValue = Font.system(size: 11.5, weight: .medium)
    /// 11pt Regular — Telemetry labels, compact status notes, and footnotes.
    public static let microMeta = Font.system(size: 11, weight: .regular)
    /// Navigation peers use identical metrics in selected and resting states.
    public static let settingsTab = Font.system(size: 12, weight: .medium)
}

// MARK: - Semantic Signal Colors

/// Restrained semantic color palette ("Precision Instrument" aesthetic).
/// Decorative icons stay monochrome (`.secondary`); color is reserved strictly for live state signals.
public enum CoddleSemanticColor {
    /// Active charging / positive power flow / switch ON state.
    public static func emerald(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.20, green: 0.84, blue: 0.38)
            : Color(red: 0.12, green: 0.68, blue: 0.28)
    }

    /// Charge limit holding / AC bypass active.
    public static func electricBlue(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.28, green: 0.66, blue: 1.00)
            : Color(red: 0.00, green: 0.48, blue: 1.00)
    }

    /// Calibration override / Away guard active / Warning.
    public static func amber(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 1.00, green: 0.66, blue: 0.16)
            : Color(red: 0.88, green: 0.48, blue: 0.00)
    }

    /// Error or critical low battery.
    public static func crimson(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 1.00, green: 0.34, blue: 0.30)
            : Color(red: 0.85, green: 0.18, blue: 0.15)
    }
}

// MARK: - Shared Shape Geometry

/// Keep nested glass contours parallel: inner radius = outer radius - inset.
/// Insets remain the existing layout values; only the corner treatment changes.
public enum CoddleGeometry {
    public static let glassCardRadius: CGFloat = 14
    public static let cardContentInset: CGFloat = 8.5
    public static let dropdownControlHeight: CGFloat = 22
    public static let glassWellRadius = glassCardRadius - cardContentInset
    public static let segmentedInset: CGFloat = 2.5
    public static let glassSegmentRadius = glassWellRadius - segmentedInset
    public static let tabBarRadius: CGFloat = 10.5
    public static let tabBarInset: CGFloat = 3.5
    public static let tabSelectionRadius = tabBarRadius - tabBarInset

    /// Classic keeps its established independent control shapes.
    public static func contentRadius(for theme: CoddleTheme, classic: CGFloat) -> CGFloat {
        theme == .liquidGlass ? glassWellRadius : classic
    }
}

// MARK: - Theme Tokens Protocol

/// Design tokens driving the geometry, fills, strokes, and shadows of cards and badges.
public protocol CoddleThemeTokens {
    var theme: CoddleTheme { get }
    var cornerRadius: CGFloat { get }
    var strokeWidth: CGFloat { get }
    var badgeStrokeWidth: CGFloat { get }

    func cardFill(colorScheme: ColorScheme, reduceTransparency: Bool) -> AnyShapeStyle
    func cardStroke(colorScheme: ColorScheme, reduceTransparency: Bool) -> AnyShapeStyle
    func applyShadow<V: View>(to view: V, colorScheme: ColorScheme, reduceTransparency: Bool) -> AnyView

    func badgeFill(tint: Color, colorScheme: ColorScheme) -> Color
    func badgeStroke(tint: Color, colorScheme: ColorScheme) -> Color
}

// MARK: - Liquid Glass Tokens (Apple Optical Spatial Glass)

public struct LiquidGlassTokens: CoddleThemeTokens {
    public let theme: CoddleTheme = .liquidGlass
    public let cornerRadius: CGFloat = CoddleGeometry.glassCardRadius
    public let strokeWidth: CGFloat = 0.75
    public let badgeStrokeWidth: CGFloat = 0.75

    public init() {}

    public func cardFill(colorScheme: ColorScheme, reduceTransparency: Bool) -> AnyShapeStyle {
        if reduceTransparency {
            return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
        }
        // High-translucency iOS Liquid Glass surface tint layered over frosted blur materials.
        if colorScheme == .dark {
            return AnyShapeStyle(
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.14), location: 0.0),
                        .init(color: Color(red: 0.52, green: 0.74, blue: 1.00).opacity(0.05), location: 0.50),
                        .init(color: Color.white.opacity(0.08), location: 1.0)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        } else {
            return AnyShapeStyle(
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.28), location: 0.0),
                        .init(color: Color.white.opacity(0.10), location: 0.52),
                        .init(color: Color(red: 0.90, green: 0.95, blue: 1.00).opacity(0.18), location: 1.0)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    public func cardStroke(colorScheme: ColorScheme, reduceTransparency: Bool) -> AnyShapeStyle {
        if reduceTransparency {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color.primary.opacity(0.18), Color.primary.opacity(0.08)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        if colorScheme == .dark {
            return AnyShapeStyle(
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.46), location: 0.0),
                        .init(color: Color.white.opacity(0.12), location: 0.46),
                        .init(color: Color(red: 0.62, green: 0.84, blue: 1.00).opacity(0.28), location: 1.0)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        } else {
            return AnyShapeStyle(
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.96), location: 0.0),
                        .init(color: Color.white.opacity(0.42), location: 0.48),
                        .init(color: Color(red: 0.68, green: 0.84, blue: 1.00).opacity(0.68), location: 1.0)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    public func applyShadow<V: View>(to view: V, colorScheme: ColorScheme, reduceTransparency: Bool) -> AnyView {
        if reduceTransparency {
            return AnyView(
                view.shadow(color: Color.black.opacity(0.06), radius: 1, x: 0, y: 1)
            )
        }
        let ambientOpacity: Double = (colorScheme == .dark ? 0.24 : 0.065)
        return AnyView(
            view.shadow(color: Color.black.opacity(ambientOpacity), radius: 5, x: 0, y: 2)
        )
    }

    public func badgeFill(tint: Color, colorScheme: ColorScheme) -> Color {
        tint.opacity(colorScheme == .dark ? 0.18 : 0.13)
    }

    public func badgeStroke(tint: Color, colorScheme: ColorScheme) -> Color {
        tint.opacity(colorScheme == .dark ? 0.52 : 0.38)
    }
}

// MARK: - Classic Tokens (macOS Native Clean)

public struct ClassicTokens: CoddleThemeTokens {
    public let theme: CoddleTheme = .classic
    public let cornerRadius: CGFloat = 10
    public let strokeWidth: CGFloat = 1.0
    public let badgeStrokeWidth: CGFloat = 1.0

    public init() {}

    public func cardFill(colorScheme: ColorScheme, reduceTransparency: Bool) -> AnyShapeStyle {
        if reduceTransparency {
            return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
        }
        if colorScheme == .dark {
            return AnyShapeStyle(Color(nsColor: .controlBackgroundColor).opacity(0.75))
        } else {
            return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
        }
    }

    public func cardStroke(colorScheme: ColorScheme, reduceTransparency: Bool) -> AnyShapeStyle {
        AnyShapeStyle(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.07))
    }

    public func applyShadow<V: View>(to view: V, colorScheme: ColorScheme, reduceTransparency: Bool) -> AnyView {
        let opacity: Double = (colorScheme == .dark ? 0.12 : 0.04)
        return AnyView(
            view.shadow(color: Color.black.opacity(opacity), radius: 2, x: 0, y: 1)
        )
    }

    public func badgeFill(tint: Color, colorScheme: ColorScheme) -> Color {
        tint.opacity(0.12)
    }

    public func badgeStroke(tint: Color, colorScheme: ColorScheme) -> Color {
        tint.opacity(0.20)
    }
}

// MARK: - Native macOS Window & In-Window Translucent Blur Views

/// AppKit `NSVisualEffectView` backdrop so the standalone window, popover, and
/// nested Liquid Glass cards refract desktop and ambient light with Gaussian blur.
public struct CoddleWindowBlurView: NSViewRepresentable {
    public var material: NSVisualEffectView.Material = .popover
    public var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    @Environment(\.colorScheme) private var colorScheme

    public init(
        material: NSVisualEffectView.Material = .popover,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.material = material
        self.blendingMode = blendingMode
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
        nsView.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    }
}

/// Full-panel iOS Liquid Glass backdrop combining behind-window desktop Gaussian blur,
/// diffused chromatic light blooms (so frosted cards always have spatial light to refract),
/// and an ultra-thin frosted glass veil.
public struct CoddleLiquidGlassBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public var body: some View {
        ZStack {
            CoddleWindowBlurView(
                material: colorScheme == .dark ? .hudWindow : .popover,
                blendingMode: .behindWindow
            )

            // Translucent glass base tint (leaves strong behind-window blur visibility)
            LinearGradient(
                colors: colorScheme == .dark
                    ? [
                        Color(red: 0.07, green: 0.10, blue: 0.16).opacity(0.16),
                        Color(red: 0.05, green: 0.07, blue: 0.12).opacity(0.20)
                    ]
                    : [
                        Color(red: 0.91, green: 0.95, blue: 1.00).opacity(0.16),
                        Color(red: 0.87, green: 0.92, blue: 0.99).opacity(0.22)
                    ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Diffused iOS Liquid Glass spatial light blooms refracted by frosted cards above
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 0.22, green: 0.64, blue: 1.00)
                                        .opacity(colorScheme == .dark ? 0.24 : 0.22),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 4,
                                endRadius: w * 0.58
                            )
                        )
                        .frame(width: w * 0.95, height: w * 0.95)
                        .position(x: w * 0.18, y: h * 0.14)

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 0.16, green: 0.84, blue: 0.62)
                                        .opacity(colorScheme == .dark ? 0.16 : 0.15),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 4,
                                endRadius: w * 0.52
                            )
                        )
                        .frame(width: w * 0.85, height: w * 0.85)
                        .position(x: w * 0.86, y: h * 0.36)

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 0.44, green: 0.52, blue: 1.00)
                                        .opacity(colorScheme == .dark ? 0.18 : 0.16),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 4,
                                endRadius: w * 0.56
                            )
                        )
                        .frame(width: w * 0.92, height: w * 0.92)
                        .position(x: w * 0.28, y: h * 0.78)
                }
                .blur(radius: 28)
            }

        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Shadow Modifier

public struct CardShadowModifier: ViewModifier {
    public let theme: CoddleTheme
    public let colorScheme: ColorScheme
    public let reduceTransparency: Bool

    public func body(content: Content) -> some View {
        switch theme {
        case .liquidGlass:
            if reduceTransparency {
                content.shadow(color: Color.black.opacity(0.06), radius: 1, x: 0, y: 1)
            } else {
                let ambientOpacity: Double = (colorScheme == .dark ? 0.24 : 0.065)
                content.shadow(color: Color.black.opacity(ambientOpacity), radius: 5, x: 0, y: 2)
            }
        case .classic:
            let opacity: Double = (colorScheme == .dark ? 0.12 : 0.04)
            content.shadow(color: Color.black.opacity(opacity), radius: 2, x: 0, y: 1)
        }
    }
}

// MARK: - Environment & ViewModifier

private struct CoddleThemeKey: EnvironmentKey {
    static let defaultValue: CoddleTheme = .default
}

private struct CoddleReduceTransparencyKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    /// Defaults to the live system preference; previews can exercise the fallback
    /// without changing the user's system-wide accessibility settings.
    public var coddleReduceTransparency: Bool {
        get { self[CoddleReduceTransparencyKey.self] ?? accessibilityReduceTransparency }
        set { self[CoddleReduceTransparencyKey.self] = newValue }
    }

    public var coddleTheme: CoddleTheme {
        get { self[CoddleThemeKey.self] }
        set { self[CoddleThemeKey.self] = newValue }
    }
}

/// Keep secondary labels opaque on dark glass: system secondary uses alpha,
/// which loses contrast when a bright desktop is refracted through the window.
private struct CoddleSecondaryContrastModifier: ViewModifier {
    var enabled: Bool
    var style: AnyShapeStyle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.coddleTheme) private var theme

    @ViewBuilder func body(content: Content) -> some View {
        if enabled && theme == .liquidGlass && colorScheme == .dark {
            content.foregroundStyle(Color(white: 0.96))
        } else {
            content.foregroundStyle(style)
        }
    }
}

extension View {
    func coddleSecondaryForeground<S: ShapeStyle>(_ style: S, when enabled: Bool = true) -> some View {
        modifier(CoddleSecondaryContrastModifier(enabled: enabled, style: AnyShapeStyle(style)))
    }
}

/// Shared background for an intrinsic-height popover or an entire Dock viewport.
struct CoddlePanelBackdrop: View {
    @Environment(\.coddleTheme) private var theme
    @Environment(\.coddleReduceTransparency) private var reduceTransparency

    var body: some View {
        if theme == .liquidGlass && !reduceTransparency {
            CoddleLiquidGlassBackdrop()
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }
}

/// Modifier that styles any view as a Coddle section card according to the selected theme.
/// In `.liquidGlass`, layers a single in-window frosted material,
/// translucent glass tint, a convex top-lit meniscus reflection, and a dual-ring refractive rim.
public struct CoddleCardModifier: ViewModifier {
    public var theme: CoddleTheme?
    public var explicitColorScheme: ColorScheme?
    public var explicitReduceTransparency: Bool?

    @Environment(\.coddleTheme) private var envTheme
    @Environment(\.colorScheme) private var envColorScheme
    @Environment(\.coddleReduceTransparency) private var envReduceTransparency

    public init(
        theme: CoddleTheme? = nil,
        explicitColorScheme: ColorScheme? = nil,
        explicitReduceTransparency: Bool? = nil
    ) {
        self.theme = theme
        self.explicitColorScheme = explicitColorScheme
        self.explicitReduceTransparency = explicitReduceTransparency
    }

    private var activeTheme: CoddleTheme {
        theme ?? envTheme
    }

    private var activeColorScheme: ColorScheme {
        explicitColorScheme ?? envColorScheme
    }

    private var activeReduceTransparency: Bool {
        explicitReduceTransparency ?? envReduceTransparency
    }

    public func body(content: Content) -> some View {
        let tokens = activeTheme.tokens
        let shape = RoundedRectangle(cornerRadius: tokens.cornerRadius, style: .continuous)
        let fill = tokens.cardFill(colorScheme: activeColorScheme, reduceTransparency: activeReduceTransparency)
        let stroke = tokens.cardStroke(colorScheme: activeColorScheme, reduceTransparency: activeReduceTransparency)
        let isGlass = (activeTheme == .liquidGlass && !activeReduceTransparency)

        content
            .background(
                ZStack {
                    if isGlass {
                        shape.fill(.ultraThinMaterial)
                    }
                    shape.fill(fill)
                    if isGlass {
                        // Top-lit curved liquid meniscus sheen + subtle bottom caustic reflection
                        shape.fill(
                            LinearGradient(
                                stops: [
                                    .init(color: Color.white.opacity(activeColorScheme == .dark ? 0.12 : 0.24), location: 0.0),
                                    .init(color: Color.white.opacity(activeColorScheme == .dark ? 0.02 : 0.05), location: 0.36),
                                    .init(color: Color.clear, location: 0.64),
                                    .init(color: Color.white.opacity(activeColorScheme == .dark ? 0.04 : 0.10), location: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }
                }
                .clipShape(shape)
                .modifier(CardShadowModifier(theme: activeTheme, colorScheme: activeColorScheme, reduceTransparency: activeReduceTransparency))
            )
            .overlay(
                ZStack {
                    shape.stroke(stroke, lineWidth: isGlass ? 0.85 : tokens.strokeWidth)
                    if isGlass {
                        shape
                            .inset(by: 0.75)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(activeColorScheme == .dark ? 0.18 : 0.65),
                                        Color.clear,
                                        Color.white.opacity(activeColorScheme == .dark ? 0.06 : 0.25)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.5
                            )
                    }
                }
            )
    }
}

extension View {
    /// Applies Coddle card styling using the current theme tokens.
    public func coddleCard(
        theme: CoddleTheme? = nil,
        colorScheme: ColorScheme? = nil,
        reduceTransparency: Bool? = nil
    ) -> some View {
        modifier(CoddleCardModifier(
            theme: theme,
            explicitColorScheme: colorScheme,
            explicitReduceTransparency: reduceTransparency
        ))
    }
}

// MARK: - Reusable Recessed Frosted Glass Well & Active Selection Lens

/// Concave frosted glass well used for inner instrument bars, slider tracks, and segmented tracks.
public struct CoddleRecessedGlassSurface: View {
    public var cornerRadius: CGFloat = 9
    public var isCapsule: Bool = false

    @Environment(\.coddleTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.coddleReduceTransparency) private var reduceTransparency

    public init(cornerRadius: CGFloat = 9, isCapsule: Bool = false) {
        self.cornerRadius = cornerRadius
        self.isCapsule = isCapsule
    }

    public var body: some View {
        let isGlass = (theme == .liquidGlass && !reduceTransparency)
        let fillColor: Color = {
            if isGlass {
                return colorScheme == .dark
                    ? Color.black.opacity(0.22)
                    : Color(red: 0.08, green: 0.18, blue: 0.36).opacity(0.055)
            }
            return Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.038)
        }()

        let strokeStyle: AnyShapeStyle = {
            if isGlass {
                return AnyShapeStyle(
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [Color.black.opacity(0.32), Color.white.opacity(0.22)]
                            : [Color(red: 0.10, green: 0.20, blue: 0.38).opacity(0.11), Color.white.opacity(0.82)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
            return AnyShapeStyle(Color.primary.opacity(colorScheme == .dark ? 0.095 : 0.065))
        }()

        if isCapsule {
            let shape = Capsule(style: .continuous)
            ZStack {
                if isGlass {
                    shape.fill(.ultraThinMaterial).opacity(0.65)
                }
                shape.fill(fillColor)
            }
            .overlay(shape.stroke(strokeStyle, lineWidth: 0.8))
        } else {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            ZStack {
                if isGlass {
                    shape.fill(.ultraThinMaterial).opacity(0.65)
                }
                shape.fill(fillColor)
            }
            .overlay(shape.stroke(strokeStyle, lineWidth: 0.75))
        }
    }
}

/// Optical treatment for small control surfaces. Content cards use material instead,
/// keeping native Liquid Glass on the control layer rather than stacking glass effects.
private struct CoddleOpticalSurface<S: Shape>: View {
    let shape: S
    var tint: Color = .clear
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if #available(macOS 26.0, *) {
            shape.fill(.clear)
                .glassEffect(.regular.tint(tint), in: shape)
        } else {
            shape.fill(.ultraThinMaterial)
                .overlay(shape.fill(tint))
                .overlay(shape.stroke(
                    LinearGradient(colors: [
                        .white.opacity(colorScheme == .dark ? 0.44 : 0.88),
                        .white.opacity(colorScheme == .dark ? 0.10 : 0.24)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.75))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.20 : 0.07), radius: 2, y: 1)
        }
    }
}

/// Raised glass selection, shared by the settings tabs and segmented controls.
public struct CoddleLiquidSelectionLens: View {
    public var cornerRadius: CGFloat = 7.5
    @Environment(\.coddleTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.coddleReduceTransparency) private var reduceTransparency

    public init(cornerRadius: CGFloat = 7.5) { self.cornerRadius = cornerRadius }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if theme == .liquidGlass && !reduceTransparency {
            CoddleOpticalSurface(shape: shape)
        } else {
            shape.fill(colorScheme == .dark ? Color(white: 0.24) : .white)
                .overlay(shape.stroke(Color.primary.opacity(0.16), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        }
    }
}

// MARK: - Tactile Spring Button Style

/// Physical spring button style that compresses slightly on press (`0.96` scale)
/// and rebounds with a crisp spring when released.
public struct CoddleScaleButtonStyle: ButtonStyle {
    public var pressedScale: CGFloat = 0.96
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(pressedScale: CGFloat = 0.96) {
        self.pressedScale = pressedScale
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1.0)
            .brightness(configuration.isPressed ? (0.03) : 0)
            .animation(
                reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.72),
                value: configuration.isPressed
            )
    }
}

// MARK: - Reusable Status Pill Badge

/// Refined capsule status badge respecting the active theme's geometry, fills, and strokes.
/// In `.liquidGlass`, combines frosted `.ultraThinMaterial` blur, translucent tint,
/// and a convex droplet meniscus highlight.
public struct StatusPillBadge: View {
    public let text: String
    public let color: Color
    public var theme: CoddleTheme?

    @Environment(\.coddleTheme) private var envTheme
    @Environment(\.colorScheme) private var envColorScheme
    @Environment(\.coddleReduceTransparency) private var reduceTransparency

    public init(
        _ text: String,
        color: Color,
        theme: CoddleTheme? = nil
    ) {
        self.text = text
        self.color = color
        self.theme = theme
    }

    public init(
        text: String,
        color: Color,
        theme: CoddleTheme? = nil
    ) {
        self.text = text
        self.color = color
        self.theme = theme
    }

    private var effectiveTheme: CoddleTheme {
        theme ?? envTheme
    }

    public var body: some View {
        let tokens = effectiveTheme.tokens
        let fill = tokens.badgeFill(tint: color, colorScheme: envColorScheme)
        let stroke = tokens.badgeStroke(tint: color, colorScheme: envColorScheme)
        let isGlass = (effectiveTheme == .liquidGlass && !reduceTransparency)

        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .shadow(color: isGlass ? color.opacity(0.80) : .clear, radius: 4)
                .frame(width: 6, height: 6)
            Text(text)
                .font(CoddleTypography.controlValue)
                .foregroundStyle(color)
                .lineLimit(1)
                .contentTransition(.interpolate)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3.5)
        .background(
            ZStack {
                if isGlass {
                    Capsule(style: .continuous).fill(.ultraThinMaterial)
                }
                Capsule(style: .continuous).fill(fill)
                if isGlass {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: Color.white.opacity(envColorScheme == .dark ? 0.32 : 0.68), location: 0.0),
                                    .init(color: Color.white.opacity(0.0), location: 0.56),
                                    .init(color: color.opacity(envColorScheme == .dark ? 0.14 : 0.08), location: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            }
            .compositingGroup()
            .shadow(
                color: isGlass ? color.opacity(envColorScheme == .dark ? 0.25 : 0.14) : .clear,
                radius: 4.5, x: 0, y: 1.5
            )
        )
        .overlay(
            Capsule(style: .continuous).stroke(
                isGlass
                    ? AnyShapeStyle(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(envColorScheme == .dark ? 0.62 : 0.96), location: 0.0),
                                .init(color: stroke, location: 0.55),
                                .init(color: color.opacity(envColorScheme == .dark ? 0.65 : 0.48), location: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    : AnyShapeStyle(stroke),
                lineWidth: isGlass ? 0.9 : tokens.badgeStrokeWidth
            )
        )
    }
}

// MARK: - Reusable Liquid Glass Capsule Surface Helper

/// Shared glass background for buttons, dropdown triggers and steppers.
public struct CoddleControlPillSurface: View {
    public var cornerRadius: CGFloat = 7
    public var isHovered: Bool = false
    public var isHighlighted: Bool = false
    @Environment(\.coddleTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.coddleReduceTransparency) private var reduceTransparency

    public init(cornerRadius: CGFloat = 7, isHovered: Bool = false, isHighlighted: Bool = false) {
        self.cornerRadius = cornerRadius
        self.isHovered = isHovered
        self.isHighlighted = isHighlighted
    }

    public var body: some View {
        let accent = CoddleSemanticColor.electricBlue(for: colorScheme)
        if theme == .liquidGlass && !reduceTransparency {
            CoddleOpticalSurface(shape: Capsule(), tint: isHighlighted ? accent.opacity(0.18) : .clear)
                .overlay(Capsule().fill(Color.primary.opacity(isHovered ? 0.06 : 0)))
        } else {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            shape.fill(Color.primary.opacity(isHovered ? 0.10 : 0.06))
                .overlay(shape.stroke(isHighlighted ? accent.opacity(0.55) : Color.primary.opacity(0.14), lineWidth: 0.75))
        }
    }
}

// MARK: - Precision Switch Toggle Style (macOS Tahoe Capsule Droplet Thumb)

/// Custom switch toggle style matching Apple's macOS Tahoe Liquid Glass HIG:
/// 1. 100% right-edge rail alignment (`Spacer` between label and switch).
/// 2. Consistent 12.5pt `.primary` typography on all toggle labels.
/// 3. Wide `38x19pt` Liquid Glass capsule track with an oblong `20x15pt` capsule droplet thumb
///    that stretches into a refractive glass lens (`23x15pt`) when pressed.
public struct CoddleSwitchToggleStyle: ToggleStyle {
    @Environment(\.coddleTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.coddleReduceTransparency) private var reduceTransparency

    @State private var isHovered = false
    @State private var isPressed = false

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        let isGlass = (theme == .liquidGlass && !reduceTransparency)

        Button {
            // Animate only the track below. A transaction around the binding
            // also animates unrelated layout and the menu window's sizing.
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .center, spacing: 10) {
                configuration.label
                    .font(CoddleTypography.controlLabel)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)

                let trackWidth: CGFloat = isGlass ? 38 : 34
                let trackHeight: CGFloat = 20
                let thumbHeight: CGFloat = 16
                let activeThumbWidth: CGFloat = isGlass
                    ? (isPressed && !reduceMotion ? 23 : 20)
                    : (isPressed && !reduceMotion ? 18.5 : 16)

                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    // Recessed frosted track channel
                    ZStack {
                        if isGlass && !configuration.isOn {
                            Capsule(style: .continuous)
                                .fill(.ultraThinMaterial)
                                .opacity(0.65)
                        }
                        Capsule(style: .continuous)
                            .fill(
                                configuration.isOn
                                    ? AnyShapeStyle(
                                        LinearGradient(
                                            colors: colorScheme == .dark
                                                ? [
                                                    Color(red: 0.16, green: 0.74, blue: 0.31).opacity(isGlass ? 0.86 : 1.0),
                                                    Color(red: 0.19, green: 0.84, blue: 0.36).opacity(isGlass ? 0.92 : 1.0)
                                                ]
                                                : [
                                                    Color(red: 0.18, green: 0.72, blue: 0.31).opacity(isGlass ? 0.88 : 1.0),
                                                    Color(red: 0.20, green: 0.80, blue: 0.36).opacity(isGlass ? 0.94 : 1.0)
                                                ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    : AnyShapeStyle(
                                        LinearGradient(
                                            colors: colorScheme == .dark
                                                ? [
                                                    Color.white.opacity(isHovered ? 0.16 : 0.11),
                                                    Color.white.opacity(isHovered ? 0.22 : 0.16)
                                                ]
                                                : [
                                                    Color.black.opacity(isHovered ? 0.11 : 0.08),
                                                    Color.black.opacity(isHovered ? 0.08 : 0.055)
                                                ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                            )
                    }
                    .overlay(
                        // Subtle concave inner-lip border (darker top lip, bright bottom rim)
                        Capsule(style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: configuration.isOn
                                        ? [
                                            Color.white.opacity(isGlass ? 0.38 : 0.12),
                                            Color.white.opacity(colorScheme == .dark ? 0.26 : 0.34)
                                        ]
                                        : (colorScheme == .dark
                                            ? [Color.black.opacity(0.32), Color.white.opacity(0.20)]
                                            : [Color.black.opacity(0.11), Color.white.opacity(0.82)]),
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.7
                            )
                    )
                    .frame(width: trackWidth, height: trackHeight)

                    // Raised convex iOS Liquid Glass droplet thumb
                    ZStack {
                        if isGlass {
                            Capsule(style: .continuous)
                                .fill(.ultraThinMaterial)
                        }
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    stops: isGlass
                                        ? [
                                            .init(color: Color.white.opacity(isPressed ? 0.82 : 0.92), location: 0.0),
                                            .init(color: Color.white.opacity(isPressed ? 0.58 : 0.74), location: 0.52),
                                            .init(color: Color(white: 0.96).opacity(isPressed ? 0.72 : 0.86), location: 1.0)
                                        ]
                                        : [
                                            .init(color: Color.white, location: 0.0),
                                            .init(color: Color(white: 0.965), location: 1.0)
                                        ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
                    .clipShape(Capsule(style: .continuous))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white,
                                        isGlass
                                            ? Color.white.opacity(colorScheme == .dark ? 0.42 : 0.65)
                                            : Color.black.opacity(colorScheme == .dark ? 0.14 : 0.07)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: isGlass ? 0.75 : 0.5
                            )
                    )
                    .frame(width: activeThumbWidth, height: thumbHeight)
                    .compositingGroup()
                    // Layer 1: Tight contact shadow (umbra) anchoring thumb to track
                    .shadow(
                        color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.14),
                        radius: 0.5, x: 0, y: 0.5
                    )
                    // Layer 2: Soft key elevation shadow (penumbra) confined within the track
                    .shadow(
                        color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.10),
                        radius: 1.75, x: 0, y: 1.0
                    )
                    .padding(.horizontal, 2)
                }
                .animation(
                    reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.78),
                    value: configuration.isOn
                )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Unified Control Rows (Right-Edge Rail Alignment)

/// Standardized toggle row with right-aligned switch and optional leading icon / tooltip.
public struct CoddleToggleRow: View {
    public let title: String
    public var systemImage: String? = nil
    public var helpText: String? = nil
    @Binding public var isOn: Bool

    public init(_ title: String, systemImage: String? = nil, isOn: Binding<Bool>, help: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self._isOn = isOn
        self.helpText = help
    }

    public var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .coddleSecondaryForeground(.secondary)
                        .frame(width: 14, alignment: .center)
                }
                Text(title)
            }
        }
        .toggleStyle(CoddleSwitchToggleStyle())
        .frame(minHeight: 22)
        .help(helpText ?? "")
        .accessibilityLabel(title)
        .accessibilityRepresentation {
            Toggle(title, isOn: $isOn).toggleStyle(.switch).accessibilityHint(helpText ?? "")
        }
    }
}

// MARK: - Liquid Glass Dropdown with Native AppKit Menu

/// Option item for `CoddleDropdownRow`.
public struct CoddleDropdownOption<Value: Hashable>: Identifiable {
    public let value: Value
    public let label: String
    public var id: Value { value }

    public init(_ value: Value, label: String) {
        self.value = value
        self.label = label
    }
}

/// Custom Liquid Glass dropdown picker row:
/// - **Closed state**: 100% custom SwiftUI Liquid Glass capsule (`CoddleControlPillSurface`) hugging its content on the right rail, with custom `chevron.up.chevron.down` indicator, hover brightening, and tactile press scale.
/// - **Open state**: Clicking anywhere on the pill invokes `NSMenu.popUp(positioning:at:in:)` anchored directly to the pill, opening a floating macOS frosted-glass popup menu aligned with the current selection—never shifting card layout, never clipping inside `ScrollView`, and supporting hover scrubbing, checkmarks, and click-outside dismissal.
public struct CoddleDropdownRow<Value: Hashable>: View {
    public let id: String
    public let title: String
    public let selection: Value
    public let options: [CoddleDropdownOption<Value>]
    public var minPillWidth: CGFloat? = nil
    @Binding public var activeDropdownID: String?
    public let onSelect: (Value) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTriggerHovered = false
    @State private var isMenuOpen = false
    @State private var menuCoordinator = CoddleMenuCoordinator<Value>()

    public init(
        id: String,
        _ title: String,
        selection: Value,
        options: [CoddleDropdownOption<Value>],
        minPillWidth: CGFloat? = nil,
        activeDropdownID: Binding<String?>,
        onSelect: @escaping (Value) -> Void
    ) {
        self.id = id
        self.title = title
        self.selection = selection
        self.options = options
        self.minPillWidth = minPillWidth
        self._activeDropdownID = activeDropdownID
        self.onSelect = onSelect
    }

    private var selectedLabel: String {
        options.first(where: { $0.value == selection })?.label ?? ""
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(CoddleTypography.controlLabel)
                .foregroundStyle(.primary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button {
                activeDropdownID = id
                isMenuOpen = true
                menuCoordinator.presentMenu(
                    options: options,
                    selection: selection
                ) { [onSelect, reduceMotion] chosenValue in
                    if reduceMotion {
                        onSelect(chosenValue)
                    } else {
                        withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                            onSelect(chosenValue)
                        }
                    }
                }
                isMenuOpen = false
                if activeDropdownID == id {
                    activeDropdownID = nil
                }
            } label: {
                HStack(spacing: 5) {
                    Text(selectedLabel)
                        .font(CoddleTypography.controlValue)
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .contentTransition(.numericText())
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .coddleSecondaryForeground((isTriggerHovered || isMenuOpen) ? .primary : .secondary, when: !(isTriggerHovered || isMenuOpen))
                }
                .padding(.leading, 11)
                .padding(.trailing, 9)
                .frame(minWidth: minPillWidth, minHeight: CoddleGeometry.dropdownControlHeight)
                .background(
                    CoddleControlPillSurface(
                        cornerRadius: 7,
                        isHovered: isTriggerHovered || isMenuOpen
                    )
                )
                .background(
                    CoddleMenuAnchorRepresentable(coordinator: menuCoordinator)
                )
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(CoddleScaleButtonStyle(pressedScale: 0.96))
            .onHover { hovering in
                isTriggerHovered = hovering
            }
        }
        .frame(minHeight: 22)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(selectedLabel)
    }
}

@MainActor
final class CoddleMenuCoordinator<Value: Hashable>: NSObject {
    weak var anchorView: NSView?
    private var optionValues: [Value] = []
    private var onSelect: ((Value) -> Void)?

    func presentMenu(
        options: [CoddleDropdownOption<Value>],
        selection: Value,
        onSelect: @escaping (Value) -> Void
    ) {
        guard let anchorView else {
            return
        }
        self.optionValues = options.map(\.value)
        self.onSelect = onSelect
        // AppKit tracks this menu synchronously. Release the callback and its
        // captured view state on both selection and cancellation.
        defer {
            self.onSelect = nil
            self.optionValues.removeAll()
        }

        let menu = NSMenu(title: "")
        menu.autoenablesItems = false
        menu.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        menu.minimumWidth = max(anchorView.bounds.width + 12, 104)

        var selectedItem: NSMenuItem?
        for (index, option) in options.enumerated() {
            let item = NSMenuItem(
                title: option.label,
                action: #selector(handleMenuSelection(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = index
            item.isEnabled = true
            if option.value == selection {
                item.state = .on
                selectedItem = item
            }
            menu.addItem(item)
        }

        let origin = NSPoint(x: -4, y: anchorView.bounds.height - 2)
        menu.popUp(positioning: selectedItem, at: origin, in: anchorView)
    }

    @objc private func handleMenuSelection(_ sender: NSMenuItem) {
        let index = sender.tag
        guard optionValues.indices.contains(index) else { return }
        onSelect?(optionValues[index])
    }
}

private struct CoddleMenuAnchorRepresentable<Value: Hashable>: NSViewRepresentable {
    let coordinator: CoddleMenuCoordinator<Value>

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        coordinator.anchorView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        coordinator.anchorView = nsView
    }
}


// MARK: - Stepped Magnetic Detent Slider (Node-Snapping + 1% Continuous Scrubber)

/// Hybrid magnetic detent + 1% continuous slider (带主刻度节点的 1% 连续磁吸滑轨):
/// - Displays major physical detent nodes (主刻度圆点) at key presets (`Off, 80%, 85%, 90%, 95%, 100%` or `10%, 15%, 20%, 25%, 30%`)
///   plus 1% micro-tick markers (1% 微刻度点) in every continuous interval between major nodes.
/// - Tracks the pointer at sub-pixel 120Hz precision during drag (`dragVisualX`) with a gentle magnetic well around major nodes,
///   avoiding quantized jumping or spring lag while dragging.
public struct CoddleDetentSlider: View {
    public let options: [CoddleDropdownOption<Int>]
    public let selection: Int
    public var accentColor: Color? = nil
    public var treatsFirstOptionAsOff: Bool = false
    public var valueFormatter: ((Int) -> String)? = nil
    public var helpText: String? = nil
    public var onPreviewChange: ((Int?) -> Void)? = nil
    public let accessibilityLabelText: String
    public let onSelect: (Int) -> Void

    @Environment(\.coddleTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.coddleReduceTransparency) private var reduceTransparency

    @State private var isKeyboardFocused = false
    @State private var isHovered = false
    @State private var isDragging = false
    @State private var hoveredIndex: Int? = nil
    @State private var dragPreviewValue: Int? = nil
    @State private var dragVisualX: CGFloat? = nil
    @State private var dragStartLocation: CGPoint? = nil

    public init(
        options: [CoddleDropdownOption<Int>],
        selection: Int,
        accentColor: Color? = nil,
        treatsFirstOptionAsOff: Bool = false,
        valueFormatter: ((Int) -> String)? = nil,
        onPreviewChange: ((Int?) -> Void)? = nil,
        helpText: String? = nil,
        accessibilityLabel: String,
        onSelect: @escaping (Int) -> Void
    ) {
        self.options = options
        self.selection = selection
        self.accentColor = accentColor
        self.treatsFirstOptionAsOff = treatsFirstOptionAsOff
        self.valueFormatter = valueFormatter
        self.onPreviewChange = onPreviewChange
        self.helpText = helpText
        self.accessibilityLabelText = accessibilityLabel
        self.onSelect = onSelect
    }

    private var activeValue: Int {
        dragPreviewValue ?? selection
    }

    private func formatValue(_ val: Int) -> String {
        if let f = valueFormatter {
            return f(val)
        }
        if let match = options.first(where: { $0.value == val }) {
            return match.label
        }
        return "\(val)%"
    }

    private func isMajorNode(_ val: Int) -> Bool {
        options.contains(where: { $0.value == val })
    }

    /// Piecewise-linear interpolation mapping any integer `val` onto the rail X coordinate.
    private func xForValue(_ val: Int, inset: CGFloat, stepX: CGFloat) -> CGFloat {
        let count = options.count
        guard count > 1, stepX > 0 else { return inset }
        if treatsFirstOptionAsOff && val <= 0 {
            return inset
        }
        let startIdx = treatsFirstOptionAsOff ? min(1, count - 1) : 0
        if val <= options[startIdx].value {
            return inset + CGFloat(startIdx) * stepX
        }
        if val >= options[count - 1].value {
            return inset + CGFloat(count - 1) * stepX
        }
        for i in startIdx..<(count - 1) {
            let v0 = options[i].value
            let v1 = options[i + 1].value
            if val >= v0 && val <= v1 {
                let t = CGFloat(val - v0) / CGFloat(max(1, v1 - v0))
                return inset + (CGFloat(i) + t) * stepX
            }
        }
        return inset
    }

    /// Computes both the continuous sub-pixel thumb X (with a soft magnetic well near major nodes)
    /// and the corresponding integer percentage `value`.
    private func resolveDragState(
        at loc: CGPoint,
        inset: CGFloat,
        stepX: CGFloat,
        isDirectClick: Bool
    ) -> (visualX: CGFloat, value: Int) {
        let count = options.count
        guard count > 1, stepX > 0 else {
            return (inset, options.first?.value ?? selection)
        }

        let minRailX = inset
        let maxRailX = inset + CGFloat(count - 1) * stepX
        let clampedX = min(maxRailX, max(minRailX, loc.x))

        let rawIdx = (clampedX - inset) / stepX
        let nearestIdx = min(count - 1, max(0, Int(rawIdx.rounded())))
        let nearestNodeX = inset + CGFloat(nearestIdx) * stepX
        let distToNode = clampedX - nearestNodeX

        // Direct click on bottom labels or directly on a major node circle snaps immediately
        if loc.y > 19 || (isDirectClick && abs(distToNode) <= 7.5) {
            let v = options[nearestIdx].value
            return (nearestNodeX, v)
        }

        // Gentle magnetic well (±3.5pt) around major nodes during continuous dragging
        let magneticRadius: CGFloat = 3.5
        if abs(distToNode) <= magneticRadius {
            let pulledX = nearestNodeX + distToNode * 0.22
            return (pulledX, options[nearestIdx].value)
        }

        let startIdx = treatsFirstOptionAsOff ? min(1, count - 1) : 0
        if treatsFirstOptionAsOff {
            let firstContinuousX = inset + CGFloat(startIdx) * stepX
            if clampedX < inset + stepX * 0.45 {
                return (clampedX, options[0].value)
            } else if clampedX <= firstContinuousX {
                return (clampedX, options[startIdx].value)
            }
        }

        let minContinuousX = inset + CGFloat(startIdx) * stepX
        let contX = min(maxRailX, max(minContinuousX, clampedX))
        let segFloat = (contX - inset) / stepX
        let segIdx = min(count - 2, max(startIdx, Int(floor(segFloat))))
        let t = min(1.0, max(0.0, Double(segFloat - CGFloat(segIdx))))
        let v0 = Double(options[segIdx].value)
        let v1 = Double(options[segIdx + 1].value)
        let intVal = Int((v0 + t * (v1 - v0)).rounded())
        return (clampedX, intVal)
    }

    public var body: some View {
        let isGlass = (theme == .liquidGlass && !reduceTransparency)
        let activeAccent = accentColor ?? CoddleSemanticColor.electricBlue(for: colorScheme)
        let val = activeValue
        let isOffState = treatsFirstOptionAsOff && val <= 0
        let count = max(1, options.count)
        let exactMajor = isMajorNode(val)
        let showValueOnThumb = !exactMajor || isDragging

        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let inset: CGFloat = 18
            let trackSpan = max(1, w - inset * 2)
            let stepX: CGFloat = count > 1 ? trackSpan / CGFloat(count - 1) : 0
            let committedX = xForValue(val, inset: inset, stepX: stepX)
            let thumbCenterX = dragVisualX ?? committedX
            let startIdx = treatsFirstOptionAsOff ? min(1, count - 1) : 0

            let thumbW: CGFloat = showValueOnThumb
                ? 33
                : (isGlass ? 20 : 14)
            let thumbH: CGFloat = showValueOnThumb
                ? 15.5
                : (isGlass ? 13.5 : thumbW)

            VStack(spacing: 4) {
                // Row 1: Rail + 1% Micro-Ticks + Major Detent Nodes + Liquid Glass Thumb
                ZStack(alignment: .leading) {
                    // Inactive track rail
                    Capsule(style: .continuous)
                        .fill(
                            colorScheme == .dark
                                ? Color.white.opacity(0.14)
                                : Color.black.opacity(0.09)
                        )
                        .frame(width: trackSpan, height: 5.5)
                        .offset(x: inset)

                    // Active progress fill from first node to active thumb position
                    if thumbCenterX > inset + 1 {
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: isGlass
                                        ? [activeAccent.opacity(0.85), activeAccent]
                                        : [activeAccent, activeAccent],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .overlay(
                                Group {
                                    if isGlass {
                                        Capsule(style: .continuous)
                                            .fill(
                                                LinearGradient(
                                                    colors: [Color.white.opacity(0.36), .clear],
                                                    startPoint: .top,
                                                    endPoint: .bottom
                                                )
                                            )
                                    }
                                }
                            )
                            .frame(width: max(5.5, thumbCenterX - inset), height: 5.5)
                            .offset(x: inset)
                    }

                    // 1% Micro-Tick Dots between major nodes
                    if count > 1 && startIdx < count - 1 {
                        ForEach(startIdx..<(count - 1), id: \.self) { segIdx in
                            let v0 = options[segIdx].value
                            let v1 = options[segIdx + 1].value
                            let span = v1 - v0
                            if span > 1 && span <= 10 {
                                ForEach(1..<span, id: \.self) { step in
                                    let subX = inset + (CGFloat(segIdx) + CGFloat(step) / CGFloat(span)) * stepX
                                    let isSubPassed = thumbCenterX >= subX - 0.5
                                    Circle()
                                        .fill(
                                            isSubPassed
                                                ? Color.white.opacity(0.68)
                                                : (colorScheme == .dark
                                                    ? Color.white.opacity(0.25)
                                                    : Color.black.opacity(0.18))
                                        )
                                        .frame(width: 2.2, height: 2.2)
                                        .position(x: subX, y: 9)
                                }
                            }
                        }
                    }

                    // Major Physical Detent Nodes along the rail
                    ForEach(Array(options.enumerated()), id: \.offset) { idx, option in
                        let nodeX = inset + CGFloat(idx) * stepX
                        let isPassed = !isOffState && thumbCenterX >= nodeX - 1.0
                        let isNodeHovered = (hoveredIndex == idx)
                        let nodeSize: CGFloat = isNodeHovered ? 8.0 : 7.0

                        Circle()
                            .fill(
                                isPassed
                                    ? activeAccent
                                    : (colorScheme == .dark
                                        ? Color(white: 0.38)
                                        : Color(white: 0.78))
                            )
                            .overlay(
                                Circle()
                                    .stroke(
                                        colorScheme == .dark
                                            ? Color.white.opacity(isPassed ? 0.75 : 0.35)
                                            : Color.white.opacity(0.95),
                                        lineWidth: 1.2
                                    )
                            )
                            .frame(width: nodeSize, height: nodeSize)
                            .shadow(
                                color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.10),
                                radius: 1, x: 0, y: 0.5
                            )
                            .position(x: nodeX, y: 9)
                    }

                    // Draggable iOS Liquid Glass Capsule Thumb
                    ZStack {
                        ZStack {
                            if isGlass {
                                Capsule(style: .continuous)
                                    .fill(.ultraThinMaterial)
                            }
                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        stops: isGlass
                                            ? [
                                                .init(color: Color.white.opacity(isDragging ? 0.80 : 0.92), location: 0.0),
                                                .init(color: Color.white.opacity(isDragging ? 0.56 : 0.76), location: 0.52),
                                                .init(color: Color(white: 0.96).opacity(isDragging ? 0.70 : 0.86), location: 1.0)
                                            ]
                                            : [
                                                .init(color: Color.white, location: 0.0),
                                                .init(color: Color(white: 0.965), location: 1.0)
                                            ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        }
                        .clipShape(Capsule(style: .continuous))
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            Color.white,
                                            isOffState
                                                ? Color.black.opacity(colorScheme == .dark ? 0.18 : 0.10)
                                                : activeAccent.opacity(isGlass ? 0.55 : 0.45)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: isGlass ? 0.75 : 0.65
                                )
                        )
                        .compositingGroup()
                        .shadow(
                            color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.14),
                            radius: 0.5, x: 0, y: 0.5
                        )
                        .shadow(
                            color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.10),
                            radius: isDragging ? 2.4 : 1.75, x: 0, y: 1.0
                        )

                        if showValueOnThumb {
                            // Live 1% value pill readout inside the glass thumb (e.g. "83%", "17%")
                            Text(formatValue(val))
                                .font(.system(size: 9.5, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(
                                    isOffState
                                        ? Color(red: 0.20, green: 0.22, blue: 0.26)
                                        : CoddleSemanticColor.electricBlue(for: .light)
                                )
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .padding(.horizontal, 2)
                        } else {
                            // Inner node lock indicator dot when resting on a major node
                            Circle()
                                .fill(isOffState ? Color.secondary.opacity(0.55) : activeAccent)
                                .frame(width: 4.5, height: 4.5)
                        }
                    }
                    .frame(width: thumbW, height: thumbH)
                    .position(x: thumbCenterX, y: 9)
                }
                .frame(height: 18)

                // Row 2: Major Node Labels aligned directly beneath each detent stop
                ZStack(alignment: .topLeading) {
                    ForEach(Array(options.enumerated()), id: \.offset) { idx, option in
                        let nodeX = inset + CGFloat(idx) * stepX
                        let isSelected = (option.value == val)
                        let isNodeHovered = (hoveredIndex == idx)

                        Text(option.label)
                            .font(.system(size: isSelected ? 11 : 10.5, weight: isSelected ? .semibold : .regular))
                            .monospacedDigit()
                            .coddleSecondaryForeground(
                                isSelected
                                    ? (isOffState ? Color.primary : activeAccent)
                                    : (isNodeHovered ? Color.primary : Color.secondary),
                                when: !isSelected && !isNodeHovered
                            )
                            .lineLimit(1)
                            .fixedSize()
                            .position(x: nodeX, y: 7)
                    }
                }
                .frame(height: 14)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard !isDragging else { return }
                switch phase {
                case .active(let loc):
                    isHovered = true
                    if stepX > 0 {
                        let rawIdx = (loc.x - inset) / stepX
                        let nearest = min(count - 1, max(0, Int(rawIdx.rounded())))
                        let nodeX = inset + CGFloat(nearest) * stepX
                        let newHover = abs(loc.x - nodeX) <= 12 ? nearest : nil
                        if newHover != hoveredIndex {
                            hoveredIndex = newHover
                        }
                    }
                case .ended:
                    isHovered = false
                    hoveredIndex = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if dragStartLocation == nil {
                            dragStartLocation = gesture.startLocation
                        }
                        let movedDist = hypot(
                            gesture.location.x - gesture.startLocation.x,
                            gesture.location.y - gesture.startLocation.y
                        )
                        let isDirectClick = movedDist < 2.0
                        let resolved = resolveDragState(
                            at: gesture.location,
                            inset: inset,
                            stepX: stepX,
                            isDirectClick: isDirectClick
                        )

                        // Update visual thumb X with animations disabled so it tracks the cursor 1:1 at 120Hz
                        var tx = Transaction()
                        tx.disablesAnimations = true
                        withTransaction(tx) {
                            if !isDragging && movedDist >= 1.0 {
                                isDragging = true
                                hoveredIndex = nil
                            }
                            if !isDirectClick {
                                dragVisualX = resolved.visualX
                            }
                            if resolved.value != activeValue {
                                if isMajorNode(resolved.value) {
                                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                                }
                                dragPreviewValue = resolved.value
                                onPreviewChange?(resolved.value)
                            }
                        }
                    }
                    .onEnded { gesture in
                        let movedDist = hypot(
                            gesture.location.x - gesture.startLocation.x,
                            gesture.location.y - gesture.startLocation.y
                        )
                        let isDirectClick = movedDist < 2.5
                        let resolved = resolveDragState(
                            at: gesture.location,
                            inset: inset,
                            stepX: stepX,
                            isDirectClick: isDirectClick
                        )
                        let finalVal = dragPreviewValue ?? resolved.value
                        dragStartLocation = nil
                        withAnimation(reduceMotion ? nil : .spring(response: 0.20, dampingFraction: 0.84)) {
                            isDragging = false
                            dragVisualX = nil
                            dragPreviewValue = nil
                            onPreviewChange?(nil)
                            if finalVal != selection {
                                onSelect(finalVal)
                            }
                        }
                    }
            )
        }
        .frame(height: 36)
        .accessibilityHidden(true)
        .overlay {
            let minimum = options.first?.value ?? 0
            let maximum = options.last?.value ?? 100
            CoddleSliderInput(
                value: Double(selection), range: Double(minimum)...Double(maximum),
                label: accessibilityLabelText, identifier: "detent-slider",
                helpText: helpText, onFocusChange: { isKeyboardFocused = $0 },
                valueDescription: { formatValue(Int($0.rounded())) },
                nextValue: { current, direction in
                    let firstActive = treatsFirstOptionAsOff && options.count > 1
                        ? options[1].value : minimum
                    if treatsFirstOptionAsOff && direction > 0 && current <= Double(minimum) {
                        return Double(firstActive)
                    }
                    if treatsFirstOptionAsOff && direction < 0 && current <= Double(firstActive) {
                        return Double(minimum)
                    }
                    return current + Double(direction)
                }
            ) { adjusted in
                let firstActive = treatsFirstOptionAsOff && options.count > 1 ? options[1].value : minimum
                let rounded = Int(adjusted.rounded())
                let resolved = treatsFirstOptionAsOff && rounded > minimum
                    ? max(firstActive, rounded) : rounded
                onSelect(resolved)
            }
        }
        .help(helpText ?? "")
        .overlay(alignment: .top) {
            if isKeyboardFocused, let helpText {
                Text(helpText)
                    .font(CoddleTypography.microMeta)
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: -28)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - CoddleConfig Extension

extension CoddleConfig {
    /// Active theme mapped from `theme` string, defaulting safely to `.liquidGlass`.
    public var activeTheme: CoddleTheme {
        CoddleTheme(key: theme)
    }
}
