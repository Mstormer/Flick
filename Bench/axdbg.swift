import AppKit
import ApplicationServices
print("trusted", AXIsProcessTrusted(), "screen", CGPreflightScreenCaptureAccess())
let a = NSWorkspace.shared.runningApplications.first { $0.localizedName == CommandLine.arguments[1] }!
let el = AXUIElementCreateApplication(a.processIdentifier)
var v: CFTypeRef?
print(AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &v).rawValue, v as Any)
