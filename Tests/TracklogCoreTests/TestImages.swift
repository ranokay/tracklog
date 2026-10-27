import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A deterministic image the artwork tests resize and hash.
func testImageData(
    width: Int = 300,
    height: Int = 300,
    red: CGFloat = 0.2,
    green: CGFloat = 0.4,
    blue: CGFloat = 0.6,
) -> Data? {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
    ) else {
        return nil
    }
    context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else { return nil }

    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data,
        UTType.png.identifier as CFString,
        1,
        nil,
    ) else {
        return nil
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}
