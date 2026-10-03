import AppKit

/// The card that slides in at the top-right when a code arrives. It is a
/// non-activating panel, so the app you are typing in keeps focus and
/// "Type" can send the code straight into it.
@MainActor
final class Banner {
    static let shared = Banner()

    private lazy var panel: NSPanel = {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false  // the card draws its own (glass or material) shadow
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.sharingType = Prefs[Prefs.hideFromCapture] ? .none : .readOnly  // from its first frame; AppModel.tick keeps it current
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return p
    }()

    private var hideTask: Task<Void, Never>?

    func show(_ id: UUID) {
        let host = FirstClickHostingView(rootView: BannerCard(id: id))
        panel.contentView = host
        let size = host.fittingSize
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        let origin = NSPoint(x: frame.maxX - size.width, y: frame.maxY - size.height + 2)
        panel.setFrame(NSRect(origin: NSPoint(x: origin.x + slide, y: origin.y), size: size), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(NSRect(origin: origin, size: size), display: true)
        }
        hide(after: 25)
    }

    func hide(after delay: TimeInterval = 0) {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
                panel.animator().setFrameOrigin(NSPoint(x: panel.frame.minX + slide, y: panel.frame.minY))
            }
            guard !Task.isCancelled else { return }  // a new card arrived during the fade
            panel.orderOut(nil)
        }
    }

    /// Slides in from and out to the right like a notification; only fades with Reduce Motion.
    private var slide: CGFloat { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 24 }

    func setHovering(_ on: Bool) {
        if on { hideTask?.cancel() } else { hide(after: 6) }
    }
}
