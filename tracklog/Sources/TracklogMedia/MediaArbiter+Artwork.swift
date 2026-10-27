import Foundation
import TracklogCore

public extension MediaArbiter {
    /// The helper's embedded cover for one track. Automation has no artwork
    /// reading, so an Automation track falls back to the neutral sleeve; a
    /// helper answer for another track is a race with a skip and is discarded.
    func artwork(for track: Track) async -> Data? {
        guard mediaStatus.source == .helper, helper.isExecutable,
              case let .snapshot(snapshot) = await helper.readArtwork(),
              let data = snapshot.artwork,
              ListenMetadata(snapshot.sample.track).identity == ListenMetadata(track).identity
        else {
            return nil
        }
        return data
    }
}
