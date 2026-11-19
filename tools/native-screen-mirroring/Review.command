#!/bin/zsh
# Build and run a temporary review session; no login service is installed.
set -eu
cd "${0:A:h}"
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
node_candidates=( "$(command -v node || true)" /opt/homebrew/bin/node /usr/local/bin/node "$HOME"/.nvm/versions/node/*/bin/node(N) )
for runtime in "${node_candidates[@]}"; do
  if [[ -x "$runtime" ]] && [[ "$("$runtime" -p 'Number(process.versions.node.split(".")[0]) >= 20' 2>/dev/null)" == true ]]; then
    export PATH="${runtime:h}:$PATH"
    if [[ "${1:-}" == --runtime ]]; then
      print -r -- "$runtime"
      exit 0
    fi
    exec "$runtime" scripts/review.js "$@"
  fi
done
print -u2 'Node 20+ is required. Install Node, then open Review.command again.'
exit 1
