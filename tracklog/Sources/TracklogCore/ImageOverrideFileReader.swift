import Foundation

public enum ImageOverrideFileReadError: Error, Equatable, Sendable {
    case tooLarge
    case unreadable
}

/// Reads a chosen image before it reaches the runtime. The file is opened with
/// its security scope before the size check, so a picker URL that needs that
/// scope reports the real file rather than "too large". The read happens on
/// the caller's executor; the droplet calls it off the main actor.
public enum ImageOverrideFileReader {
    public static func read(_ url: URL) -> Result<Data, ImageOverrideFileReadError> {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize, size > 0 else {
                return .failure(.unreadable)
            }
            guard size <= ImageOverridePolicy.maximumSourceBytes else {
                return .failure(.tooLarge)
            }
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else {
                return .failure(.unreadable)
            }
            guard data.count <= ImageOverridePolicy.maximumSourceBytes else {
                return .failure(.tooLarge)
            }
            return .success(data)
        } catch {
            return .failure(.unreadable)
        }
    }
}
