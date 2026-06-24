// cc-input-idle — print "<keyboard_idle_sec> <mouse_idle_sec>" to stdout.
//
// Queries the OS HID session state LIVE — no event tap, no background daemon, no
// accessibility / input-monitoring permission, no state file to keep in sync. The
// kernel already records the last event time per type; we just read it. This is the
// single source of truth for "is the user typing / moving the mouse right now".
//
// Used by cc-sweep to avoid stealing focus mid-keystroke (see bin/cc-sweep).
// Compiled on first use by cc-sweep to ~/.cache/cc-notify/cc-input-idle.
import CoreGraphics
import Foundation

func idle(_ t: CGEventType) -> Double {
    return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: t)
}

print(String(format: "%.3f %.3f", idle(.keyDown), idle(.mouseMoved)))
