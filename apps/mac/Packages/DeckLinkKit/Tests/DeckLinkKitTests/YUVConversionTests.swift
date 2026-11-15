import CDeckLink
import Testing

/// A mode the card has only in YUV (1080p60 on a Quad 2) goes out converted
/// from the app's BGRA: black, white and red must land on Rec. 709 video
/// levels, Cb Y Cr Y.
@Suite struct YUVConversionTests {
    private func converted(blue: UInt8, green: UInt8, red: UInt8) -> [UInt8] {
        let width = 4, height = 2
        let bgra = [UInt8](repeating: 0, count: width * height * 4).enumerated().map { index, _ in
            [blue, green, red, 255][index % 4]
        }
        var yuv = [UInt8](repeating: 0, count: width * height * 2)
        let ok = bgra.withUnsafeBufferPointer { source in
            yuv.withUnsafeMutableBufferPointer { destination in
                dlk_bgra_to_2vuy(source.baseAddress, width * 4, destination.baseAddress, width * 2,
                                 Int32(width), Int32(height))
            }
        }
        #expect(ok)
        return Array(yuv.prefix(4))
    }

    @Test func blackAndWhiteAreVideoRange() {
        #expect(converted(blue: 0, green: 0, red: 0) == [128, 16, 128, 16])
        #expect(converted(blue: 255, green: 255, red: 255) == [128, 235, 128, 235])
    }

    @Test func redIsRec709() {
        // Rec. 709 red: Y 63, Cb 102, Cr 240.
        let red = converted(blue: 0, green: 0, red: 255)
        #expect(abs(Int(red[1]) - 63) <= 1 && abs(Int(red[0]) - 102) <= 1 && abs(Int(red[2]) - 240) <= 1, "\(red)")
    }
}
