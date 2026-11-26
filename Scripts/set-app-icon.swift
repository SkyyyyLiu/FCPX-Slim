import AppKit
let path=CommandLine.arguments[1]
let clear=CommandLine.arguments.contains("--clear")
var image:NSImage?=nil
if !clear {
    let source=URL(fileURLWithPath:path).appendingPathComponent("Contents/Resources/AppIcon.icns")
    guard let loaded=NSImage(contentsOf:source) else {fatalError("Unable to load app icon")}
    image=loaded
}
let result=NSWorkspace.shared.setIcon(image,forFile:path,options:[])
print("Custom icon \(clear ? "cleared before signing" : "applied"): \(result), \(path)")
if !result {exit(1)}
