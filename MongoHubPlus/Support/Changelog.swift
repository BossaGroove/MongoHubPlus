import Foundation

/// The bundled `CHANGELOG.md`, sliced into per-version entries.
///
/// The release workflow slices the same file with the same section rule to
/// feed Sparkle's appcast, so the in-app "What's New" and the update
/// notification always show identical text.
enum Changelog {
    /// One rendered line of a version's entry. Markdown inside a bullet or a
    /// paragraph (`**bold**`, `` `code` ``, links) is left for the view to
    /// render inline; only the block structure is parsed here.
    enum Line: Equatable {
        /// A `###` group heading, e.g. "Fixed".
        case heading(String)
        /// A `-` list item.
        case bullet(String)
        case paragraph(String)
    }

    /// The entry for the running app, or an empty array when the changelog
    /// has no section for this version (a development build between
    /// releases, say).
    static func entryForCurrentVersion() -> [Line] {
        guard
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String,
            let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
            let markdown = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return entry(for: version, in: markdown)
    }

    /// Slices out `## <version> …` up to the next `## ` heading.
    ///
    /// Bullets and paragraphs may be hard-wrapped in the source file: a line
    /// that continues one folds back into it, and a blank line ends the block.
    static func entry(for version: String, in markdown: String) -> [Line] {
        var lines: [Line] = []
        var inSection = false
        /// Whether the last block can still absorb a continuation line.
        var blockIsOpen = false

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if let heading = line.headingBody(level: "## ") {
                if inSection { break }
                // The heading reads "<version> — <date>"; only the leading
                // version token identifies the section.
                inSection = heading.split(separator: " ").first.map(String.init) == version
                blockIsOpen = false
            } else if !inSection {
                continue
            } else if let heading = line.headingBody(level: "### ") {
                lines.append(.heading(heading))
                blockIsOpen = false
            } else if line.hasPrefix("- ") {
                lines.append(.bullet(String(line.dropFirst(2))))
                blockIsOpen = true
            } else if line.isEmpty {
                blockIsOpen = false
            } else if blockIsOpen, let last = lines.last {
                switch last {
                case .bullet(let text): lines[lines.count - 1] = .bullet(text + " " + line)
                case .paragraph(let text): lines[lines.count - 1] = .paragraph(text + " " + line)
                case .heading: lines.append(.paragraph(line))
                }
            } else {
                lines.append(.paragraph(line))
                blockIsOpen = true
            }
        }
        return lines
    }
}

extension String {
    /// The text after a markdown heading marker, or nil if this line isn't a
    /// heading at exactly that level.
    fileprivate func headingBody(level: String) -> String? {
        guard hasPrefix(level) else { return nil }
        return String(dropFirst(level.count)).trimmingCharacters(in: .whitespaces)
    }
}
