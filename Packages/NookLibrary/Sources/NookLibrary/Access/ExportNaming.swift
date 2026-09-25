import Foundation

public extension ObjectSnapshot {
    /// The name a copy of this object's original leaves Nook under — exported,
    /// shared or dragged out.
    ///
    /// It is the name the object carries in Nook. An object nobody has renamed
    /// goes out under the filename it came in with, exactly, because its title
    /// is only a relaxed reading of that filename. A renamed one goes out
    /// under its new name, keeping the original's extension so whatever opens
    /// it still knows what it is.
    ///
    /// `stored` is the file in the library, whose extension stands in when the
    /// original filename is unknown.
    func exportFilename(storedAs stored: URL) -> String {
        let original = originalFilename.map(Self.trimmed).flatMap { $0.isEmpty ? nil : $0 }
        let name = Self.trimmed(title)

        let chosen: String
        if let original, name.isEmpty || name == ImportClassifier.title(fromFilename: original) {
            chosen = original
        } else if name.isEmpty {
            chosen = stored.lastPathComponent
        } else {
            let ext = original.map { ($0 as NSString).pathExtension }.flatMap { $0.isEmpty ? nil : $0 }
                ?? stored.pathExtension
            let hasExtension = ext.isEmpty
                || (name as NSString).pathExtension.caseInsensitiveCompare(ext) == .orderedSame
            chosen = hasExtension ? name : "\(name).\(ext)"
        }

        // A name is data, not a path: a separator in it would otherwise aim the
        // copy at a directory that isn't there, and a leading dot would hide it.
        let safe = chosen
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let visible = String(safe.drop(while: { $0 == "." }))
        return visible.isEmpty ? stored.lastPathComponent : visible
    }

    private static func trimmed(_ string: String) -> String {
        string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
