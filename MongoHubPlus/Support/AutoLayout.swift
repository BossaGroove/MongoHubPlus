import AppKit

extension NSView {
    /// Lets a text control fill the free space in its row without ever forcing
    /// the window (or sheet) wider.
    ///
    /// Lowering only the hugging priority is not enough: a control keeps its
    /// default compression resistance, so once the text's intrinsic width
    /// exceeds the space available, auto layout raises the window's minimum
    /// width and AppKit grows the window mid-edit — which also leaves the
    /// field editor sized for the old, narrower cell (dead space at the end,
    /// the tail of the text clipped). Pasting a long query or connection
    /// string hit this every time.
    ///
    /// The minimum width keeps the control usable in a narrow window.
    func fillsRowWidth(minimumWidth: CGFloat = 120) {
        setContentHuggingPriority(.init(1), for: .horizontal)
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
        widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth).isActive = true
    }
}
