import Foundation

// MARK: - Search and play settings

public extension CaptureRuntime {
    /// Saves a validated playback URL template. An invalid template changes
    /// nothing and is reported to the Settings page.
    func savePlaybackTemplate(_ raw: String) throws {
        let template = try SearchTemplate.parse(raw).get()
        state.playbackTemplate = template
        persistPlaybackTemplate?(template.rawValue)
    }

    func removePlaybackTemplate() {
        guard state.playbackTemplate != nil else { return }
        state.playbackTemplate = nil
        persistPlaybackTemplate?("")
    }
}
