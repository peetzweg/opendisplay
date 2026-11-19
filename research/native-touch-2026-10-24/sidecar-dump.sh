#!/bin/sh
# Run while an iPad (iPadOS 27) is connected through Sidecar. Dumps the virtual
# HID devices Sidecar registers and the displays they could bind to. Needs no
# special permissions.
cd "$(dirname "$0")"
OUT=results/sidecar-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"

hidutil list > "$OUT/hidutil-list.txt"
# Every user-space (virtual) HID device, with all registry properties.
ioreg -lw0 -r -c IOHIDUserDevice > "$OUT/ioreg-IOHIDUserDevice.txt"
# Digitizer services (usage page 0x0D) as the HID event system sees them.
hidutil property --matching '{"PrimaryUsagePage":13}' --get displayUUID > "$OUT/digitizer-displayUUID.txt" 2>&1
hidutil property --matching '{"PrimaryUsagePage":13}' --get DisplayIntegrated > "$OUT/digitizer-DisplayIntegrated.txt" 2>&1
hidutil property --matching '{"PrimaryUsagePage":13}' --get SurfaceDimensions > "$OUT/digitizer-SurfaceDimensions.txt" 2>&1

# Online displays with their UUIDs, to match against displayUUID above.
cat > "$OUT/displays.swift" <<'EOF'
import ColorSync
import CoreGraphics
import Foundation
var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
CGGetOnlineDisplayList(16, &ids, &n)
for id in ids.prefix(Int(n)) {
    let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "?"
    print(id, uuid, CGDisplayBounds(id), "vendor=\(CGDisplayVendorNumber(id)) model=\(CGDisplayModelNumber(id))")
}
EOF
swift "$OUT/displays.swift" > "$OUT/displays.txt" 2>&1 && rm "$OUT/displays.swift"

echo "wrote $OUT"
grep -E '"(Product|Transport|PrimaryUsagePage|PrimaryUsage|displayUUID|DisplayUUID|DisplayIntegrated|SurfaceDimensions|Built-In)"' "$OUT/ioreg-IOHIDUserDevice.txt" | sort | uniq -c
cat "$OUT/displays.txt"
