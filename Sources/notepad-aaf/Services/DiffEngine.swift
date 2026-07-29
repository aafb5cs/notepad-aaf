import Foundation

/// One aligned row of a side-by-side diff. `equal` rows have both sides; a line
/// present only in the left file is `removed`, only in the right file is `added`.
enum DiffKind {
    case equal, added, removed
}

struct DiffRow: Identifiable {
    let id = UUID()
    let leftNumber: Int?
    let rightNumber: Int?
    let leftText: String?
    let rightText: String?
    let kind: DiffKind
}

struct FileDiff {
    let rows: [DiffRow]
    let addedCount: Int
    let removedCount: Int
    /// True when the diff couldn't be computed line-by-line because the files are
    /// too large (see `lineCap`); the view shows a plain "too large" note instead.
    let tooLarge: Bool

    var isIdentical: Bool { addedCount == 0 && removedCount == 0 && !tooLarge }
}

/// Line-based diff using a longest-common-subsequence alignment — the same core
/// algorithm `diff(1)` uses. Output rows are ready to render side by side.
enum DiffEngine {
    /// Above this per-file line count the O(n·m) table gets too big to hold, so
    /// we bail out rather than allocate hundreds of MB.
    static let lineCap = 4000

    static func diff(left: String, right: String) -> FileDiff {
        let a = splitLines(left)
        let b = splitLines(right)
        let n = a.count, m = b.count

        if n > lineCap || m > lineCap {
            return FileDiff(rows: [], addedCount: 0, removedCount: 0, tooLarge: true)
        }

        // dp[i][j] = length of the LCS of a[i...] and b[j...].
        var dp = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1
                                            : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        var rows: [DiffRow] = []
        var i = 0, j = 0, added = 0, removed = 0
        while i < n && j < m {
            if a[i] == b[j] {
                rows.append(DiffRow(leftNumber: i + 1, rightNumber: j + 1,
                                    leftText: a[i], rightText: b[j], kind: .equal))
                i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                rows.append(DiffRow(leftNumber: i + 1, rightNumber: nil,
                                    leftText: a[i], rightText: nil, kind: .removed))
                i += 1; removed += 1
            } else {
                rows.append(DiffRow(leftNumber: nil, rightNumber: j + 1,
                                    leftText: nil, rightText: b[j], kind: .added))
                j += 1; added += 1
            }
        }
        while i < n {
            rows.append(DiffRow(leftNumber: i + 1, rightNumber: nil,
                                leftText: a[i], rightText: nil, kind: .removed))
            i += 1; removed += 1
        }
        while j < m {
            rows.append(DiffRow(leftNumber: nil, rightNumber: j + 1,
                                leftText: nil, rightText: b[j], kind: .added))
            j += 1; added += 1
        }
        return FileDiff(rows: rows, addedCount: added, removedCount: removed, tooLarge: false)
    }

    /// Split into lines without the trailing empty element `components` produces
    /// for text that ends in a newline (so "a\n" is one line, not two).
    private static func splitLines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.count > 1 && lines.last == "" {
            lines.removeLast()
        }
        return lines
    }
}
