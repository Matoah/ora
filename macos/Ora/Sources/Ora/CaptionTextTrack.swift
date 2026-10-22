import Foundation

/// Presentation has a monotonic read boundary, independent of the model's
/// revisable full transcript. Map that boundary through text edits instead of
/// rewinding the reader whenever a rolling translation changes earlier words.
struct CaptionTextTrack {
    private var reference = ""
    private var readOffset = 0
    private(set) var consumed = ""
    private(set) var remaining = ""
    var text: String { consumed + remaining }

    mutating func update(_ candidate: String, final: Bool) {
        guard candidate != reference else { return }
        // A restarted stream begins at token one. It is not yet a replacement
        // for the already-read prefix; keep unread text until it catches up.
        guard final || candidate.count >= readOffset else { return }
        readOffset = Self.mapBoundary(readOffset, from: reference, to: candidate)
        reference = candidate
        remaining = String(candidate.dropFirst(readOffset))
    }

    mutating func consume(_ text: String) {
        precondition(remaining.hasPrefix(text))
        consumed += text
        remaining.removeFirst(text.count)
        readOffset += text.count
    }

    private static func mapBoundary(_ boundary: Int, from old: String, to new: String) -> Int {
        guard boundary > 0 else { return 0 }
        let before = Array(old), after = Array(new)
        // The overwhelmingly common streaming case is an unchanged read
        // prefix plus newly generated words; avoid computing a diff for it.
        if after.starts(with: before.prefix(boundary)) { return boundary }
        let difference = after.difference(from: before)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var i = 0, j = 0
        while i < before.count || j < after.count {
            // An insertion exactly at the read boundary is NEW unread text.
            if i == boundary { return j }
            if removed.contains(i) || inserted.contains(j) {
                let oldStart = i, newStart = j
                while removed.contains(i) { i += 1 }
                while inserted.contains(j) { j += 1 }
                if boundary <= i, i > oldStart {
                    // Replacements wholly before the boundary stay read.
                    // For an edit spanning the boundary, preserve its unread
                    // proportion; Unicode graphemes are never split.
                    return newStart + (j - newStart) * (boundary - oldStart) / (i - oldStart)
                }
            } else {
                i += 1
                j += 1
            }
        }
        return after.count
    }
}
