// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DaemonProtocol

/// "+" new tab button: circular and visually tied to the tab strip via
/// the same three-level white-alpha hierarchy the tab pills use
/// (track 5% at rest → hover 10% → pressed 16% matching the active
/// tab). Subclasses `NSControl` rather than `NSButton` so no
/// `NSButtonCell` participates in layout: image-only NSButtons with
/// a bezelStyle (or even a default cell) impose their own minimum
/// height regardless of `intrinsicContentSize` overrides or required
/// width/height constraints, which forces a vertical-pill shape.
final class NewTabButton: NSControl {
    private var hovered = false {
        didSet { refreshFill() }
    }
    private var pressed = false {
        didSet { refreshFill() }
    }
    private let plusImageView = NSImageView()

    override var intrinsicContentSize: NSSize {
        NSSize(width: 28, height: 28)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        toolTip = "New Tab"
        // An NSControl carrying no cell publishes nothing to the
        // accessibility tree, and AppKit prunes a view that is not an
        // accessibility element, so the plus image below never surfaces
        // either. Sidestepping NSButtonCell for layout costs the role and
        // label a button would have supplied; declare them here instead, or
        // this affordance is reachable by mouse only.
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("New Tab")
        // The label is also the New Tab menu item's exact title, so a search
        // by label matches two real elements. The identifier is what names
        // this one.
        setAccessibilityIdentifier(TabAccessibilityIdentity.newTabButton)

        plusImageView.translatesAutoresizingMaskIntoConstraints = false
        plusImageView.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        plusImageView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 12,
            weight: .medium
        )
        plusImageView.contentTintColor = .secondaryLabelColor
        plusImageView.imageScaling = .scaleNone
        addSubview(plusImageView)

        let widthConstraint = widthAnchor.constraint(equalToConstant: 28)
        widthConstraint.priority = .required
        let heightConstraint = heightAnchor.constraint(equalToConstant: 28)
        heightConstraint.priority = .required
        let aspect = widthAnchor.constraint(equalTo: heightAnchor)
        aspect.priority = .required

        NSLayoutConstraint.activate([
            widthConstraint,
            heightConstraint,
            aspect,
            plusImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            plusImageView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        setContentHuggingPriority(.required, for: .vertical)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        refreshFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    /// Route an accessibility press through the same dispatch the mouse path
    /// uses. With no cell there is nothing to turn a press into target/action
    /// on its own, so publishing the button role without this would leave the
    /// affordance visible to assistive technology and inert.
    override func accessibilityPerformPress() -> Bool {
        guard let action else { return false }
        return sendAction(action, to: target)
    }

    /// Track press / release manually since there's no NSButtonCell
    /// driving the click cycle. mouseUp inside bounds fires the
    /// target/action; `super.sendAction(_:to:)` routes through
    /// NSControl's standard dispatch.
    override func mouseDown(with event: NSEvent) {
        pressed = true
        var dragging = true
        while dragging {
            guard let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else {
                break
            }
            switch next.type {
            case .leftMouseDragged:
                let point = convert(next.locationInWindow, from: nil)
                pressed = bounds.contains(point)

            case .leftMouseUp:
                let point = convert(next.locationInWindow, from: nil)
                let inside = bounds.contains(point)
                dragging = false
                pressed = false
                if inside, let action {
                    _ = sendAction(action, to: target)
                }

            default:
                break
            }
        }
    }

    private func refreshFill() {
        let alpha: CGFloat
        if pressed {
            alpha = 0.16
        } else if hovered {
            alpha = 0.10
        } else {
            alpha = 0.05
        }
        layer?.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
    }
}
