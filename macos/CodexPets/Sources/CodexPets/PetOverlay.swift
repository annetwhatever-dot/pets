import Cocoa

final class PetOverlayController: NSObject {
    private static let defaultWindowSize = NSSize(width: 190, height: 235)

    private let panel: NSPanel
    private let rootView: PetOverlayView
    private var idleReset: Timer?

    private(set) var currentPet: PetPackage?
    private(set) var currentStateID = "idle"
    private(set) var scale: CGFloat = 0.76

    override init() {
        self.rootView = PetOverlayView(
            frame: NSRect(origin: .zero, size: Self.defaultWindowSize)
        )
        self.panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultWindowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.contentView = rootView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true
        panel.isMovableByWindowBackground = false
        panel.setFrameAutosaveName("CodexPetsOverlay")
        rootView.windowDragHandler = { [weak self] delta in
            self?.moveBy(delta)
        }
        placeDefault()
    }

    var isVisible: Bool {
        panel.isVisible
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func setPet(_ pet: PetPackage?) {
        currentPet = pet
        currentStateID = "idle"
        rootView.setPet(pet, state: PetAnimationState.named("idle", from: pet?.states ?? PetAnimationState.defaults), scale: scale)
        resizeForScale()
        if pet != nil { show() }
    }

    func setScale(_ newScale: CGFloat) {
        scale = newScale
        rootView.scale = newScale
        resizeForScale()
    }

    func setState(_ id: String, duration: TimeInterval? = nil) {
        guard let pet = currentPet else { return }
        currentStateID = id
        let state = PetAnimationState.named(id, from: pet.states)
        rootView.setState(state)
        idleReset?.invalidate()
        idleReset = nil

        if let duration, duration > 0, id != "idle" {
            idleReset = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                self?.setState("idle")
            }
        }
    }

    func setBubble(_ text: String) {
        rootView.bubbleText = text
    }

    private func resizeForScale() {
        let baseWidth = Self.defaultWindowSize.width
        let baseHeight = Self.defaultWindowSize.height
        let frame = panel.frame
        let nextSize = NSSize(
            width: max(baseWidth, 170 * scale + 50),
            height: max(baseHeight, 190 * scale + 80)
        )
        let nextFrame = NSRect(
            x: frame.midX - nextSize.width / 2,
            y: frame.maxY - nextSize.height,
            width: nextSize.width,
            height: nextSize.height
        )
        panel.setFrame(nextFrame, display: true)
        rootView.frame = NSRect(origin: .zero, size: nextSize)
    }

    private func placeDefault() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let frame = panel.frame
        let origin = NSPoint(
            x: visible.maxX - frame.width - 34,
            y: visible.minY + 42
        )
        panel.setFrameOrigin(origin)
    }

    private func moveBy(_ delta: NSPoint) {
        var frame = panel.frame
        frame.origin.x += delta.x
        frame.origin.y -= delta.y
        panel.setFrame(frame, display: true)
    }
}

final class PetOverlayView: NSView {
    var windowDragHandler: ((NSPoint) -> Void)?
    var scale: CGFloat = 1.0 {
        didSet { needsDisplay = true }
    }
    var bubbleText: String = "" {
        didSet { needsDisplay = true }
    }

    private var pet: PetPackage?
    private var spriteImage: NSImage?
    private var currentState = PetAnimationState.defaults[0]
    private var frameIndex = 0
    private var timer: Timer?

    override var isFlipped: Bool { true }

    func setPet(_ pet: PetPackage?, state: PetAnimationState, scale: CGFloat) {
        self.pet = pet
        self.scale = scale
        self.spriteImage = pet.flatMap { NSImage(contentsOf: $0.spritesheet) }
        setState(state)
    }

    func setState(_ state: PetAnimationState) {
        currentState = state
        frameIndex = 0
        timer?.invalidate()
        timer = nil

        if state.frames > 1 {
            timer = Timer.scheduledTimer(withTimeInterval: max(0.05, state.duration), repeats: true) { [weak self] _ in
                guard let self else { return }
                self.frameIndex = (self.frameIndex + 1) % max(1, self.currentState.frames)
                self.needsDisplay = true
            }
            RunLoop.main.add(timer!, forMode: .common)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.clear.setFill()
        dirtyRect.fill()

        if !bubbleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            drawBubble()
        }

        guard let pet, let spriteImage else {
            drawEmptyHint()
            return
        }

        drawSprite(pet: pet, image: spriteImage)
    }

    override func mouseDown(with event: NSEvent) {
        if event.type == .rightMouseDown { return }
    }

    override func mouseDragged(with event: NSEvent) {
        windowDragHandler?(NSPoint(x: event.deltaX, y: event.deltaY))
    }

    override func rightMouseDown(with event: NSEvent) {
        NSApp.activate(ignoringOtherApps: true)
    }

    private func drawSprite(pet: PetPackage, image: NSImage) {
        guard let context = NSGraphicsContext.current else { return }
        context.imageInterpolation = .none

        let frameWidth = CGFloat(pet.frameWidth)
        let frameHeight = CGFloat(pet.frameHeight)
        let drawWidth = frameWidth * 0.72 * scale
        let drawHeight = frameHeight * 0.72 * scale
        let target = NSRect(
            x: (bounds.width - drawWidth) / 2,
            y: bounds.height - drawHeight - 18,
            width: drawWidth,
            height: drawHeight
        )

        let imageHeight = image.size.height > 1 ? image.size.height : frameHeight * 9
        let sourceY = max(0, imageHeight - CGFloat(currentState.row + 1) * frameHeight)
        let source = NSRect(
            x: CGFloat(frameIndex % max(1, currentState.frames)) * frameWidth,
            y: sourceY,
            width: frameWidth,
            height: frameHeight
        )

        image.draw(in: target, from: source, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
    }

    private func drawBubble() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.08, alpha: 1),
            .paragraphStyle: paragraph,
        ]
        let text = NSString(string: bubbleText)
        let maxSize = NSSize(width: min(bounds.width - 28, 210), height: 80)
        let textSize = text.boundingRect(
            with: maxSize,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        ).size
        let bubbleRect = NSRect(
            x: (bounds.width - textSize.width - 22) / 2,
            y: 8,
            width: textSize.width + 22,
            height: textSize.height + 12
        )

        NSColor.white.withAlphaComponent(0.96).setFill()
        let path = NSBezierPath(roundedRect: bubbleRect, xRadius: 12, yRadius: 12)
        path.fill()

        NSColor.black.withAlphaComponent(0.22).setStroke()
        path.lineWidth = 1
        path.stroke()

        text.draw(
            with: bubbleRect.insetBy(dx: 11, dy: 6),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
    }

    private func drawEmptyHint() {
        let text = "Import a pet from the CP menu"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        let size = text.size(withAttributes: attributes)
        let rect = NSRect(
            x: (bounds.width - size.width - 24) / 2,
            y: (bounds.height - size.height - 16) / 2,
            width: size.width + 24,
            height: size.height + 16
        )
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        text.draw(at: NSPoint(x: rect.minX + 12, y: rect.minY + 8), withAttributes: attributes)
    }
}
