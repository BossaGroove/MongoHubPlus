import AppKit

/// Base class for content shown in a connection window tab
/// (legacy MHTabItemViewController).
@MainActor
class TabItemViewController: NSViewController {
    weak var tabHost: TabHostViewController?

    override var title: String? {
        didSet { tabHost?.titleDidChange(for: self) }
    }

    /// Called before the tab is removed (cancel timers/queries here).
    func willRemoveFromTabHost() {}
}

/// The custom tab bar + content host (legacy MHTabViewController): tabs split
/// the width equally, hover reveals a close button, drag reorders, titles
/// truncate in the middle and live-update.
@MainActor
final class TabHostViewController: NSViewController {
    static let tabBarHeight: CGFloat = 30

    private(set) var tabs: [TabItemViewController] = []
    private(set) var selectedIndex: Int = NSNotFound

    var onSelectionChange: ((TabItemViewController?) -> Void)?
    var onTabRemoved: ((TabItemViewController) -> Void)?

    private let barView = TabBarView()
    private let contentContainer = NSView()

    override func loadView() {
        let root = NSView()
        barView.host = self
        barView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(barView)
        root.addSubview(contentContainer)
        NSLayoutConstraint.activate([
            barView.topAnchor.constraint(equalTo: root.topAnchor),
            barView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            barView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            barView.heightAnchor.constraint(equalToConstant: Self.tabBarHeight),
            contentContainer.topAnchor.constraint(equalTo: barView.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    var selectedTab: TabItemViewController? {
        tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : nil
    }

    /// Adds (idempotently) and selects the tab (legacy auto-selected new tabs).
    func addTab(_ tab: TabItemViewController) {
        if let existing = tabs.firstIndex(where: { $0 === tab }) {
            select(index: existing)
            return
        }
        tab.tabHost = self
        addChild(tab)
        tabs.append(tab)
        select(index: tabs.count - 1)
        barView.needsLayout = true
    }

    func removeTab(_ tab: TabItemViewController) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.willRemoveFromTabHost()
        tab.view.removeFromSuperview()
        tab.removeFromParent()
        tab.tabHost = nil
        tabs.remove(at: index)

        if tabs.isEmpty {
            selectedIndex = NSNotFound
            onSelectionChange?(nil)
        } else {
            // Legacy reselection rule.
            let newIndex = index == 0 ? 0 : (index > selectedIndex ? selectedIndex : selectedIndex - 1)
            selectedIndex = NSNotFound  // force re-install
            select(index: max(0, min(newIndex, tabs.count - 1)))
        }
        barView.needsLayout = true
        onTabRemoved?(tab)
    }

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        guard index != selectedIndex else {
            barView.needsDisplay = true
            return
        }
        selectedTab?.view.removeFromSuperview()
        selectedIndex = index
        let tab = tabs[index]
        tab.view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(tab.view)
        NSLayoutConstraint.activate([
            tab.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            tab.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            tab.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            tab.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        barView.needsLayout = true
        barView.needsDisplay = true
        onSelectionChange?(tab)
    }

    func select(tab: TabItemViewController) {
        if let index = tabs.firstIndex(where: { $0 === tab }) {
            select(index: index)
        }
    }

    func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to), from != to else { return }
        tabs.swapAt(from, to)
        if selectedIndex == from {
            selectedIndex = to
        } else if selectedIndex == to {
            selectedIndex = from
        }
        barView.needsLayout = true
        barView.needsDisplay = true
    }

    fileprivate func titleDidChange(for tab: TabItemViewController) {
        barView.needsDisplay = true
    }
}

// MARK: - The bar itself

@MainActor
private final class TabBarView: NSView {
    weak var host: TabHostViewController?

    private var hoveredIndex: Int? {
        didSet { if hoveredIndex != oldValue { needsDisplay = true } }
    }
    private var draggingIndex: Int?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    private var tabCount: Int { host?.tabs.count ?? 0 }
    private static let minTabWidth: CGFloat = 60

    private func tabRect(at index: Int) -> NSRect {
        guard tabCount > 0 else { return .zero }
        let width = max(Self.minTabWidth, bounds.width / CGFloat(tabCount))
        return NSRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
    }

    private func tabIndex(at point: NSPoint) -> Int? {
        for index in 0..<tabCount where tabRect(at: index).contains(point) {
            return index
        }
        return nil
    }

    private func closeButtonRect(at index: Int) -> NSRect {
        let rect = tabRect(at: index)
        return NSRect(x: rect.minX + 6, y: rect.midY - 7, width: 14, height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let host else { return }
        // Safari/Xcode-style flat bar: the bar is recessed, the active tab
        // takes the window background so it visually connects to the content
        // below (no bottom hairline under it, no accent fill). The recess is
        // a darken overlay rather than underPageBackgroundColor, which is
        // far too dark in the light appearance.
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.black.withAlphaComponent(0.09).setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

        let selectedRect: NSRect? =
            host.tabs.indices.contains(host.selectedIndex)
            ? tabRect(at: host.selectedIndex) : nil

        for (index, tab) in host.tabs.enumerated() {
            let rect = tabRect(at: index)
            let selected = index == host.selectedIndex

            if selected {
                NSColor.windowBackgroundColor.setFill()
                rect.fill()
            } else if hoveredIndex == index {
                NSColor.labelColor.withAlphaComponent(0.06).setFill()
                NSRect(x: rect.minX, y: 0, width: rect.width, height: rect.height - 1).fill()
            }

            // Title, middle-truncated (legacy behavior)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingMiddle
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: selected ? .medium : .regular),
                .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
            let title = tab.title ?? "Loading…"
            var titleRect = rect.insetBy(dx: 22, dy: 0)
            titleRect.origin.y = rect.midY - 7
            titleRect.size.height = 14
            (title as NSString).draw(in: titleRect, withAttributes: attributes)

            // Close button on hover
            if hoveredIndex == index {
                let closeRect = closeButtonRect(at: index)
                let symbol = NSImage(
                    systemSymbolName: "xmark", accessibilityDescription: "Close")!
                symbol.withSymbolConfiguration(
                    .init(pointSize: 9, weight: .semibold)
                        .applying(.init(paletteColors: [.secondaryLabelColor])))?
                    .draw(in: closeRect.insetBy(dx: 2, dy: 2))
            }

            // Hairline between tabs, except against the active tab's edges.
            let touchesSelected =
                selectedRect.map { abs(rect.maxX - $0.minX) < 0.5 || rect.maxX <= $0.maxX && rect.minX >= $0.minX } ?? false
            if index < host.tabs.count - 1, !touchesSelected {
                NSColor.separatorColor.setFill()
                NSRect(x: rect.maxX - 0.5, y: 7, width: 1, height: rect.height - 14).fill()
            }
        }
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        hoveredIndex = tabIndex(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let host else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let index = tabIndex(at: point) else { return }

        if hoveredIndex == index, closeButtonRect(at: index).contains(point) {
            host.removeTab(host.tabs[index])
            return
        }
        host.select(index: index)
        draggingIndex = index
    }

    override func mouseDragged(with event: NSEvent) {
        guard let host, let dragging = draggingIndex else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let over = tabIndex(at: point), over != dragging {
            host.moveTab(from: dragging, to: over)
            draggingIndex = over
        }
    }

    override func mouseUp(with event: NSEvent) {
        draggingIndex = nil
    }
}
