import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in l where (w[kCGWindowLayer as String] as? Int ?? 0) < 30 { print(w[kCGWindowOwnerName as String] ?? "", "|", w[kCGWindowName as String] ?? "", "|", w[kCGWindowLayer as String] ?? "", (w[kCGWindowBounds as String] as? [String: Any]).map { "\($0["Width"]!)x\($0["Height"]!)" } ?? "") }
