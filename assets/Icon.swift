import AppKit
let folder=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels=size*scale
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        bitmap.size=NSSize(width:1024,height:1024)
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
        let background=NSBezierPath(roundedRect:NSRect(x:80,y:80,width:864,height:864),xRadius:190,yRadius:190)
        NSGradient(starting:NSColor(calibratedRed:0.91,green:0.12,blue:0.22,alpha:1),ending:NSColor(calibratedRed:0.51,green:0.03,blue:0.12,alpha:1))!.draw(in:background,angle:90)
        NSColor(calibratedWhite:0.1,alpha:1).setFill()
        NSBezierPath(roundedRect:NSRect(x:210,y:345,width:604,height:418),xRadius:40,yRadius:40).fill()
        NSColor(calibratedWhite:0.96,alpha:1).setFill()
        NSBezierPath(roundedRect:NSRect(x:238,y:395,width:548,height:340),xRadius:14,yRadius:14).fill()
        NSColor(calibratedWhite:0.1,alpha:1).setFill()
        NSBezierPath(roundedRect:NSRect(x:475,y:252,width:74,height:110),xRadius:8,yRadius:8).fill()
        NSBezierPath(roundedRect:NSRect(x:371,y:224,width:282,height:33),xRadius:16,yRadius:16).fill()
        let arrow=NSBezierPath();arrow.move(to:NSPoint(x:365,y:550));arrow.line(to:NSPoint(x:650,y:550));arrow.move(to:NSPoint(x:565,y:635));arrow.line(to:NSPoint(x:650,y:550));arrow.line(to:NSPoint(x:565,y:465));arrow.lineWidth=35;arrow.lineCapStyle = .round;arrow.lineJoinStyle = .round
        NSColor(calibratedRed:0.8,green:0.07,blue:0.18,alpha:1).setStroke();arrow.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix=scale==2 ? "@2x" : ""
        try bitmap.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
