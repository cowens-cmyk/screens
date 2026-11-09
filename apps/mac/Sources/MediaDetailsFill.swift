import Foundation
import PresenterCore

/// Fills in what the browser editor couldn't say about a picture or video
/// (MediaDetails) once its file is on this Mac.
extension AppModel {
    func fillMediaDetails() {
        guard let blobs else { return }
        let due = resident.media.values.filter { item in
            MediaDetails.needsProbe(item) && !MediaDetailsFilling.inFlight.contains(item.id)
                && blobs.url(forHash: item.fileHash) != nil
        }
        for item in due {
            guard let url = blobs.url(forHash: item.fileHash) else { continue }
            MediaDetailsFilling.inFlight.insert(item.id)
            Task { @MainActor in
                defer { MediaDetailsFilling.inFlight.remove(item.id) }
                let probe = await MediaImporter.probe(fileURL: url, kind: item.mediaKind)
                // Only an item still waiting is written, with what was found.
                guard let current = self.media(item.id), MediaDetails.needsProbe(current) else { return }
                let filled = MediaDetails.applying(probe, to: current)
                guard filled != current else { return }
                self.updateMedia(item.id) { $0 = MediaDetails.applying(probe, to: $0) }
            }
        }
    }
}

@MainActor
enum MediaDetailsFilling {
    static var inFlight: Set<String> = []
}
