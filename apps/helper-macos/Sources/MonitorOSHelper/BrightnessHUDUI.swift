import AppKit
import SwiftUI

enum MonitorOSBrightnessHUDMetrics {
    static let panelWidth: CGFloat = 292
    static let cornerRadius: CGFloat = 25
    static let windowMargin: CGFloat = 8
    static let screenInset: CGFloat = 8
    static let menuBarGap: CGFloat = 6

    static let closeDiameter: CGFloat = 19
    static let closeHostSize: CGFloat = 27
    static let closeCenterInset = CGSize(width: 5.5, height: 7.5)
    static let closeGlyphFont = Font.system(size: 8.5, weight: .bold)

    static let horizontalPadding: CGFloat = 17.5
    static let topPadding: CGFloat = 11
    static let bottomPadding: CGFloat = 14.5
    static let titleFont = Font.system(size: 12, weight: .bold)
    static let titleToSlider: CGFloat = 6.5

    static let sliderHeight: CGFloat = 16
    static let sliderSidePadding: CGFloat = 15
    static let sunToTrack: CGFloat = 6
    static let sunSmallFont = Font.system(size: 11, weight: .semibold)
    static let sunLargeFont = Font.system(size: 13, weight: .semibold)
    static let sunSmallWidth: CGFloat = 13
    static let sunLargeWidth: CGFloat = 13

    static let trackHeight: CGFloat = 5
    static let trackOpacity: Double = 0.15

    static let tickCount = 21
    static let tickInset: CGFloat = 4.5
    static let tickDiameter: CGFloat = 1.5
    static let tickOffset: CGFloat = 5.5
    static let tickOpacity: Double = 0.25

    static let knobSize = CGSize(width: 17.5, height: 14)
    static let knobColor = Color(white: 0.92)
    static let knobFadeDuration: Double = 0.18
    static let knobPressedScale: CGFloat = 1.2
    static let keyboardStep: Double = 1.0 / 16.0
}

@MainActor
final class MonitorOSBrightnessHUDModel: ObservableObject {
    @Published var brightness: Double = 0.52
    @Published var windowHovered = false
    var onUserBrightnessChange: ((Double) -> Void)?
    var onWindowHoverChange: ((Bool) -> Void)?

    func setBrightnessFromUser(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        brightness = clamped
        onUserBrightnessChange?(clamped)
    }

    func applyBrightness(_ value: Double) {
        brightness = min(max(value, 0), 1)
    }
}

@available(macOS 26.0, *)
struct MonitorOSCompactBrightnessHUDView: View {
    @ObservedObject var model: MonitorOSBrightnessHUDModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("iMac 5K")
                .font(MonitorOSBrightnessHUDMetrics.titleFont)
                .foregroundStyle(.primary)
                .padding(
                    .horizontal,
                    MonitorOSBrightnessHUDMetrics.horizontalPadding
                )

            MonitorOSCompactBrightnessSlider(
                value: Binding(
                    get: { model.brightness },
                    set: { model.setBrightnessFromUser($0) }
                ),
                windowHovered: model.windowHovered
            )
            .padding(
                .top,
                MonitorOSBrightnessHUDMetrics.titleToSlider
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, MonitorOSBrightnessHUDMetrics.topPadding)
        .padding(.bottom, MonitorOSBrightnessHUDMetrics.bottomPadding)
    }
}

@available(macOS 26.0, *)
private struct MonitorOSCompactBrightnessSlider: View {
    @Binding var value: Double
    var windowHovered: Bool
    @State private var dragging = false

    private var showsKnob: Bool {
        windowHovered || dragging
    }

    var body: some View {
        HStack(spacing: MonitorOSBrightnessHUDMetrics.sunToTrack) {
            Image(systemName: "sun.min.fill")
                .font(MonitorOSBrightnessHUDMetrics.sunSmallFont)
                .frame(width: MonitorOSBrightnessHUDMetrics.sunSmallWidth)

            track

            Image(systemName: "sun.max.fill")
                .font(MonitorOSBrightnessHUDMetrics.sunLargeFont)
                .frame(width: MonitorOSBrightnessHUDMetrics.sunLargeWidth)
        }
        .foregroundStyle(.primary)
        .padding(
            .horizontal,
            MonitorOSBrightnessHUDMetrics.sliderSidePadding
        )
        .frame(height: MonitorOSBrightnessHUDMetrics.sliderHeight)
        .animation(
            .easeOut(
                duration: MonitorOSBrightnessHUDMetrics.knobFadeDuration
            ),
            value: showsKnob
        )
    }

    private var track: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let middle = geometry.size.height / 2
            let trackY =
                middle - MonitorOSBrightnessHUDMetrics.trackHeight / 2
            let knob = MonitorOSBrightnessHUDMetrics.knobSize
            let fillEnd = width * CGFloat(value)
            let knobCenter = min(
                max(fillEnd, knob.width / 2),
                width - knob.width / 2
            )

            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(
                        Color.primary.opacity(
                            MonitorOSBrightnessHUDMetrics.trackOpacity
                        )
                    )
                    .frame(
                        width: width,
                        height: MonitorOSBrightnessHUDMetrics.trackHeight
                    )
                    .offset(y: trackY)

                Capsule()
                    .fill(Color.white)
                    .frame(
                        width: max(
                            MonitorOSBrightnessHUDMetrics.trackHeight,
                            showsKnob ? knobCenter : fillEnd
                        ),
                        height: MonitorOSBrightnessHUDMetrics.trackHeight
                    )
                    .offset(y: trackY)

                MonitorOSTickDots(
                    count: MonitorOSBrightnessHUDMetrics.tickCount,
                    inset: MonitorOSBrightnessHUDMetrics.tickInset
                )
                .fill(
                    Color.primary.opacity(
                        MonitorOSBrightnessHUDMetrics.tickOpacity
                    )
                )
                .opacity(showsKnob ? 0 : 1)
                .frame(
                    width: width,
                    height: MonitorOSBrightnessHUDMetrics.tickDiameter
                )
                .offset(
                    y:
                        middle
                        + MonitorOSBrightnessHUDMetrics.tickOffset
                        - MonitorOSBrightnessHUDMetrics.tickDiameter / 2
                )

                Capsule()
                    .fill(
                        MonitorOSBrightnessHUDMetrics.knobColor.opacity(
                            dragging ? 0 : 1
                        )
                    )
                    .frame(width: knob.width, height: knob.height)
                    .glassEffect(.clear, in: .capsule)
                    .shadow(
                        color: .black.opacity(dragging ? 0.12 : 0.3),
                        radius: 1.5,
                        y: 0.5
                    )
                    .scaleEffect(
                        showsKnob
                            ? (
                                dragging
                                    ? MonitorOSBrightnessHUDMetrics
                                        .knobPressedScale
                                    : 1
                            )
                            : 0.6
                    )
                    .animation(
                        .spring(response: 0.25, dampingFraction: 0.7),
                        value: dragging
                    )
                    .opacity(showsKnob ? 1 : 0)
                    .offset(
                        x: knobCenter - knob.width / 2,
                        y: middle - knob.height / 2
                    )
            }
            .frame(
                width: width,
                height: geometry.size.height,
                alignment: .topLeading
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        value = Double(
                            min(
                                max(drag.location.x / width, 0),
                                1
                            )
                        )
                    }
                    .onEnded { _ in
                        dragging = false
                    }
            )
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            value = max(
                value - MonitorOSBrightnessHUDMetrics.keyboardStep,
                0
            )
            return .handled
        }
        .onKeyPress(.rightArrow) {
            value = min(
                value + MonitorOSBrightnessHUDMetrics.keyboardStep,
                1
            )
            return .handled
        }
    }
}

@available(macOS 26.0, *)
private struct MonitorOSTickDots: Shape {
    var count: Int
    var inset: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard count > 1 else {
            return path
        }

        let diameter = rect.height
        let span = rect.width - 2 * inset
        for index in 0..<count {
            let centerX =
                rect.minX
                + inset
                + span * CGFloat(index) / CGFloat(count - 1)
            path.addEllipse(
                in: CGRect(
                    x: centerX - diameter / 2,
                    y: rect.minY,
                    width: diameter,
                    height: diameter
                )
            )
        }
        return path
    }
}

@available(macOS 26.0, *)
private struct MonitorOSBrightnessHUDCloseButton: View {
    @ObservedObject var model: MonitorOSBrightnessHUDModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(MonitorOSBrightnessHUDMetrics.closeGlyphFont)
                .foregroundStyle(.secondary)
                .frame(
                    width: MonitorOSBrightnessHUDMetrics.closeDiameter,
                    height: MonitorOSBrightnessHUDMetrics.closeDiameter
                )
                .glassEffect(.regular, in: .circle)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(model.windowHovered ? 1 : 0)
        .allowsHitTesting(model.windowHovered)
        .animation(
            .easeOut(
                duration: MonitorOSBrightnessHUDMetrics.knobFadeDuration
            ),
            value: model.windowHovered
        )
        .frame(
            width: MonitorOSBrightnessHUDMetrics.closeHostSize,
            height: MonitorOSBrightnessHUDMetrics.closeHostSize
        )
    }
}

final class MonitorOSBrightnessHUDHoverTrackingView: NSView {
    var hoverRect: NSRect = .zero {
        didSet {
            updateTrackingAreas()
        }
    }

    var onHoverChange: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: hoverRect,
                options: [.mouseEnteredAndExited, .activeAlways],
                owner: self
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }
}

@available(macOS 26.0, *)
final class MonitorOSBrightnessHUDGlassPanel: NSPanel {
    private let paneMargin = MonitorOSBrightnessHUDMetrics.windowMargin

    convenience init(
        model: MonitorOSBrightnessHUDModel,
        movable: Bool,
        acceptsInput: Bool,
        showsCloseButton: Bool
    ) {
        let width = MonitorOSBrightnessHUDMetrics.panelWidth
        let hosting = NSHostingView(
            rootView:
                MonitorOSCompactBrightnessHUDView(model: model)
                .frame(width: width)
        )
        hosting.sizingOptions = [.intrinsicContentSize]

        let paneSize = hosting.fittingSize
        let margin = MonitorOSBrightnessHUDMetrics.windowMargin
        let windowSize = NSSize(
            width: paneSize.width + 2 * margin,
            height: paneSize.height + 2 * margin
        )

        self.init(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // Match DisplayPane's actual window composition. A floating
        // nonactivating panel is high enough to sit above normal content
        // while remaining part of the display composition captured by SCK.
        level = .floating
        ignoresMouseEvents = !acceptsInput
        isMovable = movable
        isMovableByWindowBackground = movable
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
        ]

        let paneFrame = NSRect(
            x: margin,
            y: margin,
            width: paneSize.width,
            height: paneSize.height
        )

        let glass = NSGlassEffectView(frame: paneFrame)
        glass.style = .regular
        glass.cornerRadius = MonitorOSBrightnessHUDMetrics.cornerRadius
        glass.tintColor = nil
        glass.contentView = hosting

        let container = MonitorOSBrightnessHUDHoverTrackingView(
            frame: NSRect(origin: .zero, size: windowSize)
        )
        container.addSubview(glass)

        var hoverRect = paneFrame
        if showsCloseButton {
            let hostSize = MonitorOSBrightnessHUDMetrics.closeHostSize
            let center = NSPoint(
                x:
                    paneFrame.minX
                    + MonitorOSBrightnessHUDMetrics.closeCenterInset.width,
                y:
                    paneFrame.maxY
                    - MonitorOSBrightnessHUDMetrics.closeCenterInset.height
            )
            let closeHost = NSHostingView(
                rootView: MonitorOSBrightnessHUDCloseButton(
                    model: model,
                    action: {
                        NSApp.terminate(nil)
                    }
                )
            )
            closeHost.frame = NSRect(
                x: center.x - hostSize / 2,
                y: center.y - hostSize / 2,
                width: hostSize,
                height: hostSize
            )
            container.addSubview(closeHost)
            hoverRect = hoverRect.union(closeHost.frame)
        }

        container.hoverRect = hoverRect
        container.onHoverChange = { [weak self] hovered in
            Task { @MainActor in
                model.windowHovered = hovered
                model.onWindowHoverChange?(hovered)
                self?.invalidateShadow()
            }
        }

        contentView = container
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    func position(
        in visibleFrame: NSRect,
        verticalOffset: CGFloat
    ) {
        setFrameOrigin(
            NSPoint(
                x:
                    visibleFrame.maxX
                    - frame.width
                    - MonitorOSBrightnessHUDMetrics.screenInset
                    + paneMargin,
                y:
                    visibleFrame.maxY
                    - frame.height
                    - MonitorOSBrightnessHUDMetrics.menuBarGap
                    + paneMargin
                    - verticalOffset
            )
        )
    }

    func position(
        on screen: NSScreen,
        verticalOffset: CGFloat
    ) {
        position(
            in: screen.visibleFrame,
            verticalOffset: verticalOffset
        )
    }
}
