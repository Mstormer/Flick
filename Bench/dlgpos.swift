import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in l where (w[kCGWindowOwnerName as String] as? String) == "UserNotificationCenter" { print(w[kCGWindowBounds as String]!) }
