import Foundation

/// Note arithmetic for laying a piano keyboard out in more than one piece.
public enum KeyboardMath {
    private static let whiteSemitones = [0, 2, 4, 5, 7, 9, 11]

    /// The note `count` white keys above `first` (which should be a white key): where a second group of keys continues after
    /// a first group of `count` white keys that starts at `first`.
    public static func whiteKeyNote(from first: Int, count: Int) -> Int {
        let startIndex = whiteSemitones.firstIndex(of: first % 12) ?? 0
        let index = startIndex + count
        return first - (first % 12) + 12 * (index / 7) + whiteSemitones[index % 7]
    }
}
