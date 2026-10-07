import AppKit
import Testing

/// `cacheDisplay` hands back a bitmap of the requested size for any view, including an empty
/// one, so size alone shows nothing about what was drawn. Require visible content as well.
@MainActor
func expectRendered(_ bitmap: NSBitmapImageRep, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0, sourceLocation: sourceLocation)
    #expect(hasVisibleContent(bitmap), "The view rendered a blank image.", sourceLocation: sourceLocation)
}

func hasVisibleContent(_ bitmap: NSBitmapImageRep) -> Bool {
    guard let data = bitmap.bitmapData else { return false }
    let bytesPerPixel = max(bitmap.bitsPerPixel / 8, 1)
    let rowLength = bitmap.pixelsWide * bytesPerPixel
    let first = (0..<bytesPerPixel).map { data[$0] }
    for row in 0..<bitmap.pixelsHigh {
        let base = data + row * bitmap.bytesPerRow
        var offset = 0
        while offset < rowLength {
            for channel in 0..<bytesPerPixel where base[offset + channel] != first[channel] { return true }
            offset += bytesPerPixel
        }
    }
    return false
}

@MainActor
struct RenderedBitmapTests {
    private func bitmap() -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        memset(bitmap.bitmapData!, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
        return bitmap
    }

    @Test
    func aBlankImageIsNotCountedAsRendered() {
        #expect(!hasVisibleContent(bitmap()))
    }

    @Test
    func aSingleDrawnPixelIsCountedAsRendered() {
        let drawn = bitmap()
        drawn.bitmapData![15 * drawn.bytesPerRow + 15 * (drawn.bitsPerPixel / 8)] = 255
        #expect(hasVisibleContent(drawn))
    }
}
