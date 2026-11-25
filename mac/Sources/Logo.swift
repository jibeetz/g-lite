import AppKit

// The GL logo, drawn like app/Logo.cs: the app icon (the GL cut out of a white disc, on a dark rounded square as macOS icons are)
// and the menu bar's slanted GL.
enum Logo {
    // The icon's GL, slanted, in a square of 100 units; the context is flipped (y down) like GDI+.
    static func strokeLetters(_ context: CGContext, width: CGFloat) {
        context.translateBy(x: 50, y: 50)
        context.scaleBy(x: 0.9, y: 0.9)
        context.translateBy(x: -50, y: -50)
        context.translateBy(x: 14.8, y: 20)
        context.concatenate(CGAffineTransform(a: 1, b: 0, c: -0.2493, d: 1, tx: 0, ty: 0))
        context.setLineWidth(width)
        context.setLineJoin(.miter)
        context.setLineCap(.butt)
        context.addLines(between: [CGPoint(x: 46, y: 10), CGPoint(x: 14, y: 10), CGPoint(x: 14, y: 50), CGPoint(x: 46, y: 50),
                                   CGPoint(x: 46, y: 30), CGPoint(x: 32, y: 30)])
        context.addLines(between: [CGPoint(x: 60, y: 10), CGPoint(x: 60, y: 50), CGPoint(x: 88, y: 50)])
        context.strokePath()
    }

    // The disc with the GL cut out, in a box of 100 units.
    static func drawDisc(_ context: CGContext, small: Bool) {
        context.setFillColor(.white)
        context.fillEllipse(in: CGRect(x: 2, y: 2, width: 96, height: 96))
        context.saveGState()
        context.setBlendMode(.clear)
        strokeLetters(context, width: small ? 10.5 : 9)
        context.restoreGState()
    }

    // The disc in a colour with the GL cut out in the background's, in a box (app/Logo.cs, Paint): the keyboards' logo key.
    static func paint(_ context: CGContext, _ box: CGRect, _ color: NSColor, _ background: NSColor) {
        context.saveGState()
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: CGRect(x: box.minX + box.width * 0.02, y: box.minY + box.height * 0.02, width: box.width * 0.96, height: box.height * 0.96))
        context.translateBy(x: box.minX, y: box.minY)
        context.scaleBy(x: box.width / 100, y: box.height / 100)
        context.setStrokeColor(background.cgColor)
        strokeLetters(context, width: 9)
        context.restoreGState()
    }

    static func appIconPng(_ size: Int) -> Data? {
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = CGFloat(size) / 100
        context.translateBy(x: 0, y: CGFloat(size))
        context.scaleBy(x: scale, y: -scale)
        // macOS's icon grid: the square is 824 of 1024, rounded at about 22%.
        let square = CGRect(x: 10, y: 10, width: 80, height: 80)
        context.addPath(CGPath(roundedRect: square, cornerWidth: 18, cornerHeight: 18, transform: nil))
        context.setFillColor(CGColor(srgbRed: 0x1C / 255.0, green: 0x1C / 255.0, blue: 0x1C / 255.0, alpha: 1))
        context.fillPath()
        // The disc keeps its own transparency layer, so cutting the letters out of it shows the square behind.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.translateBy(x: 22, y: 22)
        context.scaleBy(x: 0.56, y: 0.56)
        drawDisc(context, small: size <= 32)
        context.endTransparencyLayer()
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    // An .iconset folder for iconutil (mac/build.sh).
    static func writeIconset(_ folder: String) throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
                try appIconPng(points * scale)?.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
            }
        }
    }

    // The menu bar's slanted GL (app/Logo.cs, Slanted), as a template image so macOS colours it for the menu bar.
    static func slanted(_ size: Int = 22) -> NSImage {
        var height = Int((Double(size) * 0.54).rounded())
        let stroke = max(2, Int((Double(height) * 0.21).rounded()))
        if (height - stroke) % 2 != 0 { height += 1 }
        var gWidth = Int((Double(height) * 0.84).rounded()), lWidth = Int((Double(height) * 0.75).rounded())
        let gap = max(1, Int((Double(stroke) * 0.33).rounded()))
        let slant = Int((Double(height) * 0.25).rounded(.up))
        while gWidth + gap + lWidth + slant > size { if lWidth >= gWidth { lWidth -= 1 } else { gWidth -= 1 } }
        let left = (size - (gWidth + gap + lWidth + slant)) / 2, top = (size - height) / 2
        let middle = (height - stroke) / 2, barStart = Int((Double(gWidth) * 0.55).rounded()), lLeft = gWidth + gap
        let rects = [
            CGRect(x: 0, y: 0, width: gWidth, height: stroke), CGRect(x: 0, y: height - stroke, width: gWidth, height: stroke),
            CGRect(x: 0, y: 0, width: stroke, height: height), CGRect(x: gWidth - stroke, y: middle, width: stroke, height: height - middle),
            CGRect(x: barStart, y: middle, width: gWidth - barStart, height: stroke), CGRect(x: lLeft, y: 0, width: stroke, height: height),
            CGRect(x: lLeft, y: height - stroke, width: lWidth, height: stroke),
        ]
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.concatenate(CGAffineTransform(a: 1, b: 0, c: -0.25, d: 1, tx: CGFloat(left) + 0.25 * CGFloat(top + height),
                                                  ty: CGFloat(top)))
            context.setFillColor(.black)
            context.fill(rects)
            return true
        }
        image.isTemplate = true
        return image
    }
}
