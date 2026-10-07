import AppKit
import CoreGraphics
import QuartzCore

@MainActor
final class MonitorOSBrightnessHUD {
    private static let holdDuration: TimeInterval = 1.4
    private static let fadeDuration: TimeInterval = 0.5
    private static let entranceDuration: TimeInterval = 0.20

    private let movable: Bool
    private let acceptsInput: Bool
    private let showsCloseButton: Bool
    private let model = MonitorOSBrightnessHUDModel()
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    private var autoHideEnabled = false

    var onBrightnessChange: ((Double) -> Void)? {
        didSet {
            model.onUserBrightnessChange = { [weak self] value in
                self?.onBrightnessChange?(value)
                self?.rescheduleHideAfterInteraction()
            }
        }
    }

    init(
        movable: Bool = false,
        acceptsInput: Bool = true,
        showsCloseButton: Bool = false
    ) {
        self.movable = movable
        self.acceptsInput = acceptsInput
        self.showsCloseButton = showsCloseButton
        model.onWindowHoverChange = { [weak self] hovered in
            guard let self else {
                return
            }
            if hovered {
                self.hideWorkItem?.cancel()
                self.hideWorkItem = nil
            } else if self.autoHideEnabled {
                self.scheduleHide()
            }
        }
    }

    func show(
        value: Float,
        on displayID: CGDirectDisplayID,
        autoHide: Bool = true,
        verticalOffset: CGFloat = 0
    ) {
        guard #available(macOS 26.0, *) else {
            return
        }

        let screen = NSScreen.screens.first(where: { screen in
            (screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber)?.uint32Value == displayID
        })
        let fallbackFrame =
            screen == nil ? Self.appKitFrame(for: displayID) : nil

        guard screen != nil || fallbackFrame != nil else {
            fputs(
                "monitorOS Helper: brightness HUD cannot resolve display " +
                "\(displayID)\n",
                stderr
            )
            return
        }

        model.applyBrightness(Double(value))

        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
        } else {
            let created = MonitorOSBrightnessHUDGlassPanel(
                model: model,
                movable: movable,
                acceptsInput: acceptsInput,
                showsCloseButton: showsCloseButton
            )
            self.panel = created
            panel = created
        }

        if let glassPanel = panel as? MonitorOSBrightnessHUDGlassPanel {
            if let screen {
                glassPanel.position(
                    on: screen,
                    verticalOffset: verticalOffset
                )
            } else if let fallbackFrame {
                glassPanel.position(
                    in: fallbackFrame,
                    verticalOffset: verticalOffset
                )
            }
        }

        hideWorkItem?.cancel()
        hideWorkItem = nil
        autoHideEnabled = autoHide

        let wasVisible = panel.isVisible && panel.alphaValue > 0.01
        if !panel.isVisible {
            panel.alphaValue = 0
            if movable {
                panel.makeKeyAndOrderFront(nil)
                NSApp.activate()
            } else {
                // Keep the app itself nonactivating, but make this
                // .nonactivatingPanel the helper's key window immediately.
                // Liquid Glass then renders in its active-window state from
                // the first frame instead of waiting for a click.
                panel.orderFrontRegardless()
                panel.makeKey()
            }
            panel.invalidateShadow()
        } else if !movable, !panel.isKeyWindow {
            // A transient panel can lose key status while it remains on
            // screen. Every brightness change should restore the same active
            // glass state without activating monitorOS.
            panel.makeKey()
        }

        if wasVisible {
            panel.alphaValue = 1
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.entranceDuration
                context.timingFunction = CAMediaTimingFunction(
                    controlPoints: 0.22,
                    1,
                    0.36,
                    1
                )
                panel.animator().alphaValue = 1
            }
        }

        if autoHide && !model.windowHovered {
            scheduleHide()
        }
    }

    func update(value: Float) {
        model.applyBrightness(Double(value))
    }

    private static func appKitFrame(
        for displayID: CGDirectDisplayID
    ) -> NSRect? {
        guard CGDisplayIsOnline(displayID) == 1 else {
            return nil
        }

        let bounds = CGDisplayBounds(displayID)
        guard !bounds.isNull,
              bounds.width > 0,
              bounds.height > 0 else {
            return nil
        }

        // CoreGraphics uses a top-left global Y axis. AppKit uses a
        // bottom-left global Y axis whose zero is the main display.
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        return NSRect(
            x: bounds.origin.x,
            y:
                mainBounds.height
                - bounds.origin.y
                - bounds.height,
            width: bounds.width,
            height: bounds.height
        )
    }

    private func rescheduleHideAfterInteraction() {
        guard autoHideEnabled, !model.windowHovered else {
            return
        }
        scheduleHide()
    }

    private func scheduleHide() {
        hideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.fadeOut()
            }
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.holdDuration,
            execute: workItem
        )
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        autoHideEnabled = false
        panel?.alphaValue = 0
        panel?.orderOut(nil)
    }

    private func fadeOut() {
        guard let panel, panel.isVisible else {
            return
        }

        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = Self.fadeDuration
                panel.animator().alphaValue = 0
            },
            completionHandler: {
                panel.orderOut(nil)
            }
        )
    }
}
