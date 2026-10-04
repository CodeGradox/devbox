import AppKit
import Testing
@testable import DevBox

@MainActor
struct OpenWithMenuTests {
    @Test
    func menuIconHasNativeMenuSizeWithoutResizingSharedSource() throws {
        let source = NSImage(size: NSSize(width: 512, height: 512))
        let representation = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        source.addRepresentation(representation)

        let icon = OpenWithMenu.menuIcon(source)

        #expect(icon !== source)
        #expect(icon.size == NSSize(width: 16, height: 16))
        #expect(source.size == NSSize(width: 512, height: 512))
        // Preserve the high-resolution image data for Retina menu rendering.
        #expect(icon.representations.first?.pixelsWide == 512)
        #expect(icon.representations.first?.pixelsHigh == 512)
    }
}
