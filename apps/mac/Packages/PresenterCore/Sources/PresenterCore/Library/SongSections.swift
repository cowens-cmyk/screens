import Foundation

/// Splitting a song's section in two and taking a section header away, in
/// the slide editor. A song's orders (arrangements) only play slides whose
/// section they list, so both keep every slide that played still playing,
/// in the same place. An order sync keeps in Shepherd's order is marked
/// as edited by hand when it changes, so sync leaves it.
public enum SongSections {

    /// Start New Section Here…: the slide at `start` and the ones after it
    /// in the same section move into `section`, a new one. Every order that
    /// sings the old section sings the new one right after it, so the
    /// moved slides are still sung where they were.
    public static func split(_ song: inout Presentation, at start: Int, into section: PresentationSection) {
        guard song.slides.indices.contains(start) else { return }
        let previous = song.slides[start].sectionId
        song.sections = (song.sections ?? []) + [section]
        var index = start
        repeat {
            song.slides[index].sectionId = section.id
            index += 1
        } while index < song.slides.count && song.slides[index].sectionId == previous
        guard let previous, var arrangements = song.arrangements else { return }
        for i in arrangements.indices {
            let before = arrangements[i]
            arrangements[i].sectionIds = before.sectionIds.flatMap { id in
                id == previous ? [id, section.id] : [id]
            }
            // Sync would put Shepherd's order back and drop the new section.
            arrangements[i] = ShepherdArrangementSync.editedByHand(arrangements[i], before: before)
        }
        song.arrangements = arrangements
    }

    /// Delete Section: the header goes and its slides join the section just
    /// above them (the one below when it is the first), as the slide list
    /// shows them. An order that sang the deleted section sings them as
    /// part of that one: where it already has that section the deleted one
    /// is dropped, otherwise the deleted one is swapped for it. With no
    /// other section left, the slides have none.
    public static func delete(_ song: inout Presentation, sectionId: String) {
        let first = song.slides.firstIndex { $0.sectionId == sectionId }
        let last = song.slides.lastIndex { $0.sectionId == sectionId }
        let above = first.flatMap { first in
            song.slides[..<first].last { $0.sectionId != nil && $0.sectionId != sectionId }?.sectionId
        }
        let below = last.flatMap { last in
            song.slides[(last + 1)...].first { $0.sectionId != nil && $0.sectionId != sectionId }?.sectionId
        }
        let known = Set((song.sections ?? []).map(\.id))
        let target = [above, below].compactMap { $0 }.first { known.contains($0) && $0 != sectionId }

        song.sections?.removeAll { $0.id == sectionId }
        for index in song.slides.indices where song.slides[index].sectionId == sectionId {
            song.slides[index].sectionId = target
        }
        guard var arrangements = song.arrangements else { return }
        for i in arrangements.indices {
            var ids = arrangements[i].sectionIds
            if let target, !ids.contains(target) {
                ids = ids.map { $0 == sectionId ? target : $0 }
            }
            ids.removeAll { $0 == sectionId }
            let before = arrangements[i]
            arrangements[i].sectionIds = ids
            arrangements[i] = ShepherdArrangementSync.editedByHand(arrangements[i], before: before)
        }
        song.arrangements = arrangements
    }
}
