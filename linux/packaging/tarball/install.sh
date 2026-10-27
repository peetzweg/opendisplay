#!/usr/bin/env bash
# Installs od-sender from this release tarball, with its desktop entry and
# systemd user unit pointing at wherever the binary went (both ship with
# /usr/bin/od-sender, the AUR package's path).
#
#   ./install.sh               for you: ~/.local/bin, ~/.local/share/applications,
#                              ~/.config/systemd/user
#   sudo ./install.sh --system for everyone: /usr/local/bin,
#                              /usr/local/share/applications, /usr/local/lib/systemd/user
#   ./install.sh --uninstall [--system]
#
# KDE Plasma 6.7 and older let only the program a desktop entry's Exec= names
# create outputs, compared by absolute path, so Exec= must name the installed
# binary exactly; this script writes that path.
#
# Runtime requirement: libpipewire 0.3 (libpipewire-0.3.so.0), on every
# desktop with PipeWire already; FFmpeg and x264 are built in.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

system=0
uninstall=0
for arg in "$@"; do
  case "$arg" in
    --system) system=1 ;;
    --uninstall) uninstall=1 ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown argument '$arg' (see --help)" >&2; exit 2 ;;
  esac
done

if [[ $system == 1 ]]; then
  bindir=/usr/local/bin
  appdir=/usr/local/share/applications
  unitdir=/usr/local/lib/systemd/user
  if [[ $EUID -ne 0 ]]; then
    echo "install.sh: --system writes to /usr/local; run it with sudo" >&2
    exit 1
  fi
else
  if [[ $EUID -eq 0 ]]; then
    echo "install.sh: as root this would install into root's home; use --system" >&2
    exit 1
  fi
  bindir="${HOME}/.local/bin"
  appdir="${XDG_DATA_HOME:-${HOME}/.local/share}/applications"
  unitdir="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
fi

bin="${bindir}/od-sender"
desktop="${appdir}/od-sender.desktop"
unit="${unitdir}/od-sender@.service"

reload_units() {
  if [[ $system == 0 ]] && command -v systemctl >/dev/null; then
    systemctl --user daemon-reload 2>/dev/null || true
  fi
}

if [[ $uninstall == 1 ]]; then
  rm -fv "$bin" "$desktop" "$unit"
  reload_units
  exit 0
fi

for f in od-sender od-sender.desktop od-sender@.service; do
  [[ -f "${here}/${f}" ]] || { echo "install.sh: ${f} is missing next to this script" >&2; exit 1; }
done

install -Dm755 "${here}/od-sender" "$bin"
# Point Exec= / ExecStart= at the installed binary (an absolute path).
sed "s#^Exec=/usr/bin/od-sender#Exec=${bin}#" "${here}/od-sender.desktop" |
  install -Dm644 /dev/stdin "$desktop"
sed "s#^ExecStart=/usr/bin/od-sender#ExecStart=${bin}#" "${here}/od-sender@.service" |
  install -Dm644 /dev/stdin "$unit"
reload_units

echo "installed ${bin}"
echo "          ${desktop}"
echo "          ${unit}"
# (Captured first: with pipefail, `ldconfig -p | grep -q` fails when grep
# stops reading early.)
libs="$(ldconfig -p 2>/dev/null || true)"
if [[ "$libs" != *"libpipewire-0.3.so.0"* ]]; then
  echo "note: libpipewire-0.3.so.0 was not found; install your distribution's libpipewire" >&2
fi
case ":${PATH}:" in
  *":${bindir}:"*) ;;
  *) echo "note: ${bindir} is not on your PATH yet; log out and in, or add it" >&2 ;;
esac
echo "start with: od-sender run   (or: systemctl --user enable --now 'od-sender@<receiver>.service')"
