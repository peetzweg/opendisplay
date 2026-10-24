#!/usr/bin/env python3
"""Turn linux/Cargo.lock into flatpak-builder sources for an offline build.

Writes the same shape as flatpak-builder-tools' flatpak-cargo-generator: one
archive per crate (static.crates.io, sha256 from Cargo.lock) unpacked into
cargo/vendor/<name>-<version> with its .cargo-checksum.json, plus a cargo
config that replaces crates.io with that directory. Standard library only;
no network (every crate here comes from crates.io with a checksum).

    linux/packaging/flatpak/cargo-sources.py > linux/packaging/flatpak/cargo-sources.json
"""

import json
import pathlib
import sys
import tomllib

LOCK = pathlib.Path(__file__).resolve().parents[2] / "Cargo.lock"
REGISTRY = "registry+https://github.com/rust-lang/crates.io-index"


def main() -> int:
    lock = tomllib.loads(LOCK.read_text())
    sources = []
    for pkg in lock["package"]:
        source = pkg.get("source")
        if source is None:
            continue  # a workspace member
        if source != REGISTRY or "checksum" not in pkg:
            print(f"unsupported source for {pkg['name']}: {source}", file=sys.stderr)
            return 1
        name, version, checksum = pkg["name"], pkg["version"], pkg["checksum"]
        dest = f"cargo/vendor/{name}-{version}"
        sources.append(
            {
                "type": "archive",
                "archive-type": "tar-gzip",
                "url": f"https://static.crates.io/crates/{name}/{name}-{version}.crate",
                "sha256": checksum,
                "dest": dest,
            }
        )
        sources.append(
            {
                "type": "inline",
                "contents": json.dumps({"package": checksum, "files": {}}),
                "dest": dest,
                "dest-filename": ".cargo-checksum.json",
            }
        )
    sources.append(
        {
            "type": "inline",
            "contents": "[source.vendored-sources]\n"
            'directory = "cargo/vendor"\n\n'
            "[source.crates-io]\n"
            'replace-with = "vendored-sources"\n',
            "dest": "cargo",
            "dest-filename": "config.toml",
        }
    )
    json.dump(sources, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
