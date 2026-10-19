import ApplicationServices
let app = AXUIElementCreateApplication(Int32(CommandLine.arguments[1])!)
var wins: CFTypeRef?
AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &wins)
for w in (wins as? [AXUIElement]) ?? [] {
  var kids: CFTypeRef?
  AXUIElementCopyAttributeValue(w, kAXChildrenAttribute as CFString, &kids)
  for k in (kids as? [AXUIElement]) ?? [] {
    var t: CFTypeRef?
    AXUIElementCopyAttributeValue(k, kAXTitleAttribute as CFString, &t)
    if (t as? String) == "Cancel" { print("press", AXUIElementPerformAction(k, kAXPressAction as CFString).rawValue) }
  }
}
