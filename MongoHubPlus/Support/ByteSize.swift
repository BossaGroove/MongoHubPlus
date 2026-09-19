import Foundation

/// Byte counts as a person reads them: `842 B`, `20 KB`, `1.5 MB`, `5 TB`.
///
/// `ByteCountFormatter` in `.binary` style already does the 1024 steps, the
/// unit choice and the rounding (whole numbers for `4 KB`, one decimal for
/// `20.3 MB`), and localizes the units. The one thing it does differently is
/// spelling small counts as "512 bytes", which is both long for a table
/// column and not what a size column elsewhere in the world shows — so under
/// a kilobyte this says `512 B`.
@MainActor
enum ByteSize {
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func string(_ bytes: Int) -> String {
        guard bytes >= 1024 else {
            return String(format: String(localized: "%d B"), bytes)
        }
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
