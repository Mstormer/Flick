import AppKit
import ApplicationServices
let pid = Int32(CommandLine.arguments[1])!
func dump(_ e: AXUIElement, _ d: Int) {
  var role: CFTypeRef?, title: CFTypeRef?, val: CFTypeRef?, kids: CFTypeRef?
  AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role)
  AXUIElementCopyAttributeValue(e, kAXTitleAttribute as CFString, &title)
  AXUIElementCopyAttributeValue(e, kAXValueAttribute as CFString, &val)
  print(String(repeating: "  ", count: d), role ?? "", "|", title ?? "", "|", (val as? String)?.prefix(200) ?? "")
  AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids)
  for k in (kids as? [AXUIElement]) ?? [] where d < 6 { dump(k, d + 1) }
}
dump(AXUIElementCreateApplication(pid), 0)
