import AppKit
import SwiftUI

/// Host the content *inside* AppKit's glass, so the system can composite the
/// desktop, refractive rim and content correctly. An empty glass background
/// behind a separate SwiftUI hosting view does not establish that relationship.
final class QuickPasteSurface<Content: View>: NSView {
    let hostingView: NSHostingView<Content>
    private(set) var materialView: NSView

    init(rootView: Content) {
        hostingView = QuickPasteTransparentHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 26
            glass.contentView = hostingView
            materialView = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 26
            material.layer?.masksToBounds = true
            material.addSubview(hostingView)
            materialView = material
        }
        super.init(frame: .zero)
        materialView.autoresizingMask = [.width, .height]
        addSubview(materialView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isOpaque: Bool { false }
    override func layout() {
        super.layout()
        materialView.frame = bounds
        hostingView.frame = materialView.bounds
    }
}

private final class QuickPasteTransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}
