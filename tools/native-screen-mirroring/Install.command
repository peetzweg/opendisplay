#!/bin/zsh
# Install the packaged bridge and its login service from this source folder.
set -eu
cd "${0:A:h}"
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
if [[ "${1:-}" == --check && $# == 1 ]]; then
  exec /bin/zsh Review.command --check
fi
if (( $# )); then
  print -u2 'Use Install.command without options, or --check to check dependencies.'
  exit 1
fi
if ! /usr/bin/xcrun --find clang >/dev/null 2>&1; then
  print -u2 'Apple compiler tools are required. Run xcode-select --install, complete the installation, then retry.'
  exit 1
fi
if ! /bin/zsh Review.command --check >/dev/null 2>&1; then
  brew_binary="$(command -v brew || true)"
  if [[ -z "$brew_binary" ]]; then
    print -u2 'Build dependencies are missing. Install Homebrew from https://brew.sh, then retry.'
    exit 1
  fi
  formulae=(cmake pkgconf libplist openssl@3)
  if ! /bin/zsh Review.command --runtime >/dev/null 2>&1; then formulae+=(node); fi
  print 'Installing the missing runtime/build prerequisites through Homebrew.'
  HOMEBREW_NO_AUTO_UPDATE=1 "$brew_binary" install "${formulae[@]}"
fi
exec /bin/zsh Review.command --install
