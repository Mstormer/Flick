import CoreGraphics
let owner = CommandLine.arguments[1]
let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in l where (w[kCGWindowOwnerName as String] as? String) == owner && (w[kCGWindowLayer as String] as? Int) == 0 {
  print(w[kCGWindowNumber as String]!, w[kCGWindowBounds as String]!)
}
