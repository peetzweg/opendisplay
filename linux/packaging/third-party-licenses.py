#!/usr/bin/env python3
"""Writes THIRD-PARTY-LICENSES.txt for an od-sender release tarball.

Covers everything linked into the binary:
  * every Rust crate od-sender links (normal dependencies, transitively, for
    the target being built; build scripts and dev-dependencies are not
    shipped), with its declared licence and the licence files it ships;
  * OpenH264 (BSD-2-Clause, built from source by openh264-sys2);
  * FFmpeg and x264 (GPL), from the licence files build-static.sh installs
    under <prefix>/share/licenses.

  third-party-licenses.py <linux workspace dir> <static ffmpeg prefix> > THIRD-PARTY-LICENSES.txt
"""

import json
import pathlib
import subprocess
import sys

LICENSE_GLOBS = ("LICENSE*", "LICENCE*", "COPYING*", "NOTICE*", "COPYRIGHT*", "UNLICENSE*")


def metadata(workspace: pathlib.Path) -> dict:
    host = subprocess.run(
        ["rustc", "--print", "host-tuple"], capture_output=True, text=True, check=True
    ).stdout.strip()
    out = subprocess.run(
        ["cargo", "metadata", "--format-version", "1", "--locked", "--filter-platform", host],
        cwd=workspace,
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return json.loads(out)


def linked_packages(meta: dict, root_name: str) -> list:
    """Packages reachable from `root_name` through normal dependencies."""
    pkgs = {p["id"]: p for p in meta["packages"]}
    nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
    root = next(p["id"] for p in meta["packages"] if p["name"] == root_name)
    seen, todo = set(), [root]
    while todo:
        pid = todo.pop()
        if pid in seen:
            continue
        seen.add(pid)
        for dep in nodes[pid]["deps"]:
            if any(k["kind"] is None for k in dep["dep_kinds"]):
                todo.append(dep["pkg"])
    seen.discard(root)
    return sorted((pkgs[i] for i in seen), key=lambda p: (p["name"], p["version"]))


def licence_files(pkg: dict) -> list:
    root = pathlib.Path(pkg["manifest_path"]).parent
    files = []
    for pattern in LICENSE_GLOBS:
        files += [f for f in root.glob(pattern) if f.is_file()]
    return sorted(set(files))


def section(title: str) -> str:
    return f"\n{'=' * 78}\n{title}\n{'=' * 78}\n"


def main() -> int:
    workspace, prefix = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    meta = metadata(workspace)
    own = {p["name"] for p in meta["packages"] if p["source"] is None}
    out = [
        "Third-party software in this od-sender binary\n",
        "od-sender itself is GPL-3.0-only (see LICENSE). It statically links the\n"
        "components below. FFmpeg is built with --enable-gpl and x264 is GPL, so the\n"
        "binary as a whole is distributed under the GPL-3.0; the other components'\n"
        "notices follow as their licences require.\n",
    ]

    ffmpeg = prefix / "share" / "licenses"
    out.append(section("FFmpeg and x264 (GPL-2.0-or-later, linked statically)"))
    found = sorted(ffmpeg.rglob("*")) if ffmpeg.is_dir() else []
    found = [f for f in found if f.is_file()]
    if not found:
        print(f"third-party-licenses: no licence files under {ffmpeg}", file=sys.stderr)
        return 1
    for f in found:
        out.append(f"\n--- {f.relative_to(ffmpeg)} ---\n{f.read_text(errors='replace')}")

    pkgs = [p for p in linked_packages(meta, "od-sender") if p["name"] not in own]
    out.append(section(f"Rust crates ({len(pkgs)})"))
    for p in pkgs:
        out.append(f"{p['name']} {p['version']}: {p.get('license') or p.get('license_file') or 'UNKNOWN'}"
                   f"{'  ' + p['repository'] if p.get('repository') else ''}\n")
    for p in pkgs:
        files = licence_files(p)
        if p["name"] == "openh264-sys2":
            # The vendored OpenH264 sources carry Cisco's notice one level down.
            files += [f for f in (pathlib.Path(p["manifest_path"]).parent / "upstream").glob("LICENSE*")]
        out.append(section(f"{p['name']} {p['version']} ({p.get('license') or 'see below'})"))
        if p["name"] == "openh264-sys2":
            out.append(
                "OpenH264 is compiled from source into this binary (openh264-sys2's\n"
                "`source` feature). Cisco's H.264 patent licence covers only Cisco's\n"
                "prebuilt OpenH264 binaries, so it does not apply to this build.\n\n"
            )
        if not files:
            out.append(f"(the crate ships no licence file; licence: {p.get('license')})\n")
        for f in files:
            out.append(f"--- {f.name} ---\n{f.read_text(errors='replace')}\n")
    sys.stdout.write("".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
