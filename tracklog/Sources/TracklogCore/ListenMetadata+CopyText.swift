import Foundation

public extension ListenMetadata {
    /// The text Copy metadata puts on the pasteboard: artist and title, with
    /// the album in parentheses when there is one.
    var copyText: String {
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = artist.isEmpty ? title : "\(artist) - \(title)"
        if !album.isEmpty {
            text += " (\(album))"
        }
        return text
    }
}
