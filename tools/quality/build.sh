#!/bin/zsh
# Compile the test page and the receiver-side tools (mode switcher, decode benchmark).
source "$(dirname "$0")/env.sh"
swiftc -O "$ROOT/tools/quality/testpage.swift" -o "$S/testpage"
swiftc -O "$ROOT/tools/quality/decbench.swift" -o "$S/decbench"
scp -q "$ROOT/tools/quality/mode.swift" "$ROOT/tools/quality/decbench.swift" "$R:/tmp/"
ssh "$R" 'cd /tmp && swiftc -O mode.swift -o od-mode && swiftc -O decbench.swift -o od-decbench'
echo "built into $S and $R:/tmp"
