import CoreGraphics
import Foundation
let code = CGKeyCode(Int(CommandLine.arguments[1])!)
let src = CGEventSource(stateID: .hidSystemState)
for down in [true, false] { CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!.post(tap: .cghidEventTap); usleep(30000) }
