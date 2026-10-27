import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else { fatalError("Usage: swift make-motion-preview.swift FRAMES OUTPUT.gif") }
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, files.count, nil) else { fatalError("Cannot create animation") }
CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for file in files {
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("Invalid frame: \(file.path)") }
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 30.0, kCGImagePropertyGIFUnclampedDelayTime: 1.0 / 30.0]] as CFDictionary)
}
guard CGImageDestinationFinalize(destination) else { fatalError("Cannot finalize animation") }
print("Saved \(files.count)-frame renderer capture to \(output.path)")
