import Foundation
import Testing
@testable import PPTXImport

struct PPTXHueWrapTests {
    @Test func luminosityModulationRoundsAWrappedRedHue() throws {
        let xml = """
        <fill xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
          <a:srgbClr val="FF0021"><a:lumMod val="50000"/></a:srgbClr>
        </fill>
        """
        let document = try XMLDocument(data: Data(xml.utf8), options: [])
        var warnings: [String] = []
        let color = PPTXColorResolver().color(in: document.rootElement(), warnings: &warnings)

        // Red is maximal and green < blue, so the hue crosses the wrap.
        // Halving luminosity gives (127.5, 0, 16.5), rounded to (128, 0, 17).
        #expect(color == "800011FF")
        #expect(warnings.isEmpty)
    }
}
