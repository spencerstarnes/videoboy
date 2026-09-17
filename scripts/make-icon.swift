//
//  make-icon.swift — draws Videoboy's app icon, at every size macOS asks for.
//
//  Purpose : A test pattern in a circle with VB across the middle. Generated rather
//            than checked in as a binary, so it can be changed by editing numbers
//            instead of by opening an image editor.
//  Usage   : swift scripts/make-icon.swift <output.iconset>
//  Connects: scripts/build.sh, which runs iconutil over the iconset it produces.
//

import AppKit

let barColours: [NSColor] = [
    NSColor(srgbRed: 0.75, green: 0.75, blue: 0.75, alpha: 1),   // grey
    NSColor(srgbRed: 0.75, green: 0.75, blue: 0.00, alpha: 1),   // yellow
    NSColor(srgbRed: 0.00, green: 0.75, blue: 0.75, alpha: 1),   // cyan
    NSColor(srgbRed: 0.00, green: 0.75, blue: 0.00, alpha: 1),   // green
    NSColor(srgbRed: 0.75, green: 0.00, blue: 0.75, alpha: 1),   // magenta
    NSColor(srgbRed: 0.75, green: 0.00, blue: 0.00, alpha: 1),   // red
    NSColor(srgbRed: 0.00, green: 0.00, blue: 0.75, alpha: 1)    // blue
]

func drawIcon(size: Int) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let side = CGFloat(size)

    // A little inset, so the circle is not flush against the tile edge the way no
    // other icon on the dock is.
    let inset = side * 0.06
    let circle = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let clip = NSBezierPath(ovalIn: circle)
    clip.addClip()

    // The bars fill the circle, drawn as full-height columns and clipped to it.
    let barWidth = circle.width / CGFloat(barColours.count)
    for (index, colour) in barColours.enumerated() {
        colour.setFill()
        NSRect(x: circle.minX + CGFloat(index) * barWidth, y: circle.minY,
               width: barWidth + 1, height: circle.height).fill()
    }

    // A dark band across the middle, so the letters have something to sit on. White
    // type straight over cyan and yellow is unreadable at 32pt.
    let bandHeight = circle.height * 0.42
    let band = NSRect(x: circle.minX, y: circle.midY - bandHeight / 2,
                      width: circle.width, height: bandHeight)
    NSColor(srgbRed: 0.05, green: 0.05, blue: 0.06, alpha: 0.92).setFill()
    band.fill()

    // VB, in the camcorder face when it is installed and a bold mono when it is not.
    let pointSize = circle.height * 0.30
    let font = NSFont(name: "VCR OSD Mono", size: pointSize)
        ?? NSFont.monospacedSystemFont(ofSize: pointSize, weight: .bold)
    let text = "VB" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
        .kern: pointSize * 0.04
    ]
    let textSize = text.size(withAttributes: attributes)
    text.draw(
        at: NSPoint(x: circle.midX - textSize.width / 2,
                    y: circle.midY - textSize.height / 2),
        withAttributes: attributes)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("usage: make-icon.swift <output.iconset>\n".data(using: .utf8)!)
    exit(1)
}
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

// The set macOS expects in an .iconset.
let wanted: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for entry in wanted {
    guard let rep = drawIcon(size: entry.size),
          let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("could not draw \(entry.name)\n".data(using: .utf8)!)
        exit(1)
    }
    try? data.write(to: outputDirectory.appendingPathComponent("\(entry.name).png"))
}
print("wrote \(wanted.count) sizes to \(outputDirectory.path)")
