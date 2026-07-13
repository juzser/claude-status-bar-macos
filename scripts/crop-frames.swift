// Crops baked animation frames to their content and downscales them.
// usage: swift crop-frames.swift <outdir> <finalSize> <frame.png...>
//
// The clawd-tank SVGs share a roomy viewBox, so a raw render leaves the
// character tiny inside the canvas. The crop box is the union of the alpha
// bounding boxes across ALL of an icon's frames — per-frame cropping would
// make the artwork jump as limbs move — squared and padded, so the whole
// animation stays framed and the character fills the menu bar slot.
import AppKit

let args = CommandLine.arguments
guard args.count > 3, let final = Int(args[2]) else {
    FileHandle.standardError.write(Data("usage: crop-frames <outdir> <finalSize> <frames...>\n".utf8))
    exit(1)
}
let outDir = args[1]
let paths = Array(args.dropFirst(3))

var frames: [(name: String, cg: CGImage)] = []
var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
for path in paths {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let data = cg.dataProvider?.data as Data? else {
        FileHandle.standardError.write(Data("cannot load \(path)\n".utf8))
        exit(1)
    }
    let bpr = cg.bytesPerRow
    for y in 0..<cg.height {
        for x in 0..<cg.width where data[y * bpr + x * 4 + 3] > 10 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    frames.append((name: (path as NSString).lastPathComponent, cg: cg))
}
guard maxX >= minX, let canvas = frames.first?.cg else { exit(1) }

let contentW = maxX - minX + 1
let contentH = maxY - minY + 1
var side = max(contentW, contentH)
side += max(4, side * 4 / 100) * 2 // breathing room so strokes aren't clipped
side = min(side, min(canvas.width, canvas.height))
var boxX = minX + contentW / 2 - side / 2
var boxY = minY + contentH / 2 - side / 2
boxX = max(0, min(boxX, canvas.width - side))
boxY = max(0, min(boxY, canvas.height - side))

for frame in frames {
    // CGImage.cropping(to:) uses raster coordinates: origin at the top-left,
    // matching the alpha scan above.
    guard let cropped = frame.cg.cropping(to: CGRect(x: boxX, y: boxY,
                                                     width: side, height: side)),
          let ctx = CGContext(data: nil, width: final, height: final,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { exit(1) }
    ctx.interpolationQuality = .high
    ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: final, height: final))
    guard let out = ctx.makeImage(),
          let png = NSBitmapImageRep(cgImage: out)
              .representation(using: .png, properties: [:]) else { exit(1) }
    try png.write(to: URL(fileURLWithPath: "\(outDir)/\(frame.name)"))
}
