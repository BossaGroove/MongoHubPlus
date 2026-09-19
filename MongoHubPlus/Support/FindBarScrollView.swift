import AppKit

/// A scroll view that answers Edit ▸ Find on behalf of the text view it
/// scrolls (feature-spec 4.8).
///
/// The find bar is a sibling of the document, not an ancestor: with the
/// cursor in its search field the responder chain runs field editor →
/// search field → `NSTextFinderBarView` → *this scroll view* → window, and
/// never reaches the text view. Nothing in that chain answers
/// `performFindPanelAction:`, so ⌘G and ⇧⌘G grey out the moment ⌘F gives
/// the search field focus — you have to click back into the document before
/// you can step through matches, which is the opposite of what ⌘F just set
/// you up to do.
///
/// The scroll view *is* in that chain, and it knows the text view, so it
/// forwards. Whether the action is available stays the text view's call.
/// When the document has focus the text view is found first and this never
/// comes into play.
final class FindBarScrollView: NSScrollView, NSMenuItemValidation {
    private var findableTextView: NSTextView? { documentView as? NSTextView }

    @objc func performFindPanelAction(_ sender: Any?) {
        findableTextView?.performFindPanelAction(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(performFindPanelAction(_:)) else { return true }
        return findableTextView?.validateUserInterfaceItem(menuItem) ?? false
    }
}
