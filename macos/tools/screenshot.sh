#!/usr/bin/env bash
# Screenshots the running [rgb] window: tools/screenshot.sh out.png
set -euo pipefail
id="$(swift -e '
import CoreGraphics
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
// The app also owns thin menu bar windows: take its tallest window.
let ours = windows.filter { ["fff3", "[rgb]"].contains($0[kCGWindowOwnerName as String] as? String ?? "") && ($0[kCGWindowLayer as String] as? Int) == 0 }
    .max { (($0[kCGWindowBounds as String] as? [String: Any])?["Height"] as? Double ?? 0) < (($1[kCGWindowBounds as String] as? [String: Any])?["Height"] as? Double ?? 0) }
print(ours?[kCGWindowNumber as String] as? Int ?? 0)
')"
if [ "$id" = "0" ]; then echo "no [rgb] window on screen" >&2; exit 1; fi
screencapture -x -o -l "$id" "$1"
echo "$1"
