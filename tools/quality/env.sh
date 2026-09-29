# Shared settings for the quality suite. Override before running:
#   OD_QUALITY_DIR    where captures and the compiled test page live (default: build/quality)
#   OD_RECEIVER_HOST  ssh host of the receiving Mac running the Debug receiver (default: imac)
ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
S=${OD_QUALITY_DIR:-$ROOT/build/quality}
R=${OD_RECEIVER_HOST:-imac}
SENDER_LOG="$HOME/Library/Logs/OpenDisplay Dev/opendisplay.log"
RECEIVER_LOG='"$HOME/Library/Logs/OpenDisplay Receiver Dev/opendisplay.log"'
mkdir -p "$S/cap"
