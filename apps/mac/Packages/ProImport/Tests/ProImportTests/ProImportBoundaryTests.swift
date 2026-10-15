import Testing
@testable import ProImport

struct ProImportBoundaryTests {
    @Test func zeroTransitionDurationUsesHalfSecondDefault() {
        var transition = RVData_Transition()
        transition.duration = 0
        #expect(ProAnimationMapper.duration(transition) == 0.5)
    }

    @Test func playlistIncludesDepthThreeAndStopsAtDepthFour() throws {
        func nestedHeader(_ name: String, depth: Int) -> RVData_PlaylistItem {
            var item = RVData_PlaylistItem()
            item.uuid.string = name
            item.name = name
            item.itemType = .header(RVData_PlaylistItem.Header())
            for _ in 0..<depth {
                var placeholder = RVData_PlaylistItem.Placeholder()
                placeholder.linkedData = item
                var wrapper = RVData_PlaylistItem()
                wrapper.itemType = .placeholder(placeholder)
                item = wrapper
            }
            return item
        }

        // Depth counts linked items, starting at zero for a top-level item.
        var items = RVData_Playlist.PlaylistItems()
        items.items = [
            nestedHeader("included", depth: 3),
            nestedHeader("too-deep", depth: 4),
        ]
        var document = RVData_PlaylistDocument()
        document.rootNode.childrenType = .items(items)
        let mapped = ProPlaylistMapper.mapPresentationPlaylists(document) { _ in nil }

        #expect(mapped.services.count == 1)
        let service = try #require(mapped.services.first)
        #expect(service.service.items.map(\.id) == ["included"])
        #expect(service.service.items.map(\.name) == ["included"])
        #expect(service.warnings.isEmpty)
    }
}
