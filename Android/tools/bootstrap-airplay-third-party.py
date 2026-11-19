#!/usr/bin/env python3
"""Download the pinned native sources required by the AirPlay audio engine.

The upstream source trees are intentionally not committed to this repository.
This script recreates app/src/main/cpp/third_party from immutable upstream
commits and the patches kept under app/src/main/cpp/patches.

Usage:
    python3 tools/bootstrap-airplay-third-party.py
    python3 tools/bootstrap-airplay-third-party.py --proxy http://host:port
    python3 tools/bootstrap-airplay-third-party.py --force

HTTP(S)_PROXY environment variables are honoured by urllib automatically.
"""

from __future__ import annotations

import argparse
import errno
import hashlib
import os
import shutil
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path
from typing import Dict, List, Optional
from urllib.error import URLError
from urllib.request import ProxyHandler, Request, build_opener

ROOT = Path(__file__).resolve().parents[1]
CPP_DIR = ROOT / "app" / "src" / "main" / "cpp"
THIRD_PARTY = CPP_DIR / "third_party"
UXPLAY_PATCHES = CPP_DIR / "patches" / "UxPlay"
DOWNLOADS = THIRD_PARTY / ".downloads"
STAGING = THIRD_PARTY / ".staging"
MARKER = THIRD_PARTY / ".airplay-bootstrap"

CONFIG_VERSION = "airplay-third-party-v1"

# Downloaded archives plus extracted sources. The later native build needs much
# more, but this is the minimum for bootstrap itself to make progress.
MIN_BOOTSTRAP_FREE_BYTES = 256 * 1024 * 1024
RECOMMENDED_BUILD_FREE_BYTES = 4 * 1024 * 1024 * 1024

UXPLAY_COMMIT = "df67c212a433cf6dda3676dd40c097900d24e645"
FFMPEG_COMMIT = "38b88335f99e76ed89ff3c93f877fdefce736c13"
LIBPLIST_COMMIT = "2117b8fdb6b4096455bd2041a63e59a028120136"
OPENSSL_CMAKE_COMMIT = "61be7754dfc452fddefd896b5026d23871d71e51"

OPENSSL_VERSION = "3.4.4"
OPENSSL_SHA256 = "7bdf55ac20f2779e99e5eca306f824fad2b37dee5a06cc35ed5a8b85a6060010"
OPENSSL_URLS = [
    "https://www.openssl.org/source/openssl-3.4.4.tar.gz",
    "https://mirror.viaduck.org/openssl/openssl-3.4.4.tar.gz",
]

ARCHIVES: List[Dict[str, str]] = [
    {
        "name": "UxPlay",
        "url": f"https://github.com/FDH2/UxPlay/archive/{UXPLAY_COMMIT}.tar.gz",
        "filename": f"UxPlay-{UXPLAY_COMMIT}.tar.gz",
    },
    {
        "name": "ffmpeg",
        "url": f"https://github.com/FFmpeg/FFmpeg/archive/{FFMPEG_COMMIT}.tar.gz",
        "filename": f"FFmpeg-{FFMPEG_COMMIT}.tar.gz",
    },
    {
        "name": "libplist",
        "url": (
            "https://github.com/libimobiledevice/libplist/archive/"
            f"{LIBPLIST_COMMIT}.tar.gz"
        ),
        "filename": f"libplist-{LIBPLIST_COMMIT}.tar.gz",
    },
    {
        "name": "openssl-cmake",
        "url": (
            "https://github.com/viaduck/openssl-cmake/archive/"
            f"{OPENSSL_CMAKE_COMMIT}.tar.gz"
        ),
        "filename": f"openssl-cmake-{OPENSSL_CMAKE_COMMIT}.tar.gz",
    },
]

REQUIRED_PATHS = [
    "UxPlay/lib/raop.c",
    "UxPlay/lib/airplay_video.c",
    "UxPlay/lib/llhttp/llhttp.c",
    "UxPlay/lib/playfair/playfair.c",
    "ffmpeg/configure",
    "ffmpeg/libavcodec/Makefile",
    "libplist/include/plist/plist.h",
    "libplist/src/plist.c",
    "libplist/libcnary/cnary.c",
    "openssl-cmake/CMakeLists.txt",
    "openssl-cmake/cmake/BuildOpenSSL.cmake",
    f"openssl-cmake/openssl-{OPENSSL_VERSION}.tar.gz",
]

OPENER: Optional[urllib.request.OpenerDirector] = None


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _is_within(root: Path, candidate: Path) -> bool:
    root_real = os.path.realpath(str(root))
    candidate_real = os.path.realpath(str(candidate))
    try:
        return os.path.commonpath([root_real, candidate_real]) == root_real
    except ValueError:
        return False


def _safe_extract(archive: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "r:gz") as source:
        for member in source.getmembers():
            member_path = destination / member.name
            if not _is_within(destination, member_path):
                raise RuntimeError(f"unsafe path in archive: {member.name}")
            if member.issym() or member.islnk():
                link_path = member_path.parent / member.linkname
                if not _is_within(destination, link_path):
                    raise RuntimeError(f"unsafe link in archive: {member.name}")
        source.extractall(destination)


def _download(url: str, destination: Path, expected_sha256: Optional[str] = None) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() and destination.stat().st_size > 0:
        if expected_sha256 is None:
            print(f"using cached {destination.name}")
            return
        actual = _sha256(destination)
        if actual == expected_sha256:
            print(f"using cached {destination.name} (sha256 ok)")
            return
        print(f"cached {destination.name} has wrong sha256; downloading again")

    request = Request(url, headers={"User-Agent": "OpenDisplayAndroid-bootstrap/1.0"})
    temporary = destination.with_name(destination.name + ".part")
    assert OPENER is not None
    try:
        with OPENER.open(request, timeout=120) as response, temporary.open("wb") as output:
            total = 0
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                output.write(chunk)
                total += len(chunk)
        if expected_sha256 is not None:
            actual = _sha256(temporary)
            if actual != expected_sha256:
                raise RuntimeError(
                    f"sha256 mismatch for {url}: expected {expected_sha256}, got {actual}"
                )
        elif not tarfile.is_tarfile(temporary):
            raise RuntimeError(f"download from {url} is not a gzip tarball")
        temporary.replace(destination)
        print(f"downloaded {destination.name} ({total / 1024 / 1024:.1f} MiB)")
    except (URLError, OSError, RuntimeError) as error:
        if temporary.exists():
            temporary.unlink()
        raise RuntimeError(
            f"failed to download {url}: {error}. "
            "If GitHub needs a proxy, pass --proxy http://host:port or set HTTPS_PROXY."
        ) from error


def _install_archive(spec: Dict[str, str]) -> None:
    name = spec["name"]
    archive = DOWNLOADS / spec["filename"]
    _download(spec["url"], archive)

    target = THIRD_PARTY / name
    work = STAGING / name
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True, exist_ok=True)
    _safe_extract(archive, work)

    roots = [path for path in work.iterdir() if path.is_dir()]
    if len(roots) != 1:
        raise RuntimeError(f"expected one top-level directory in {archive}, found {roots}")
    if target.exists():
        shutil.rmtree(target)
    shutil.move(str(roots[0]), str(target))
    shutil.rmtree(work, ignore_errors=True)
    print(f"installed {name}")


def _apply_uxplay_patches() -> None:
    patches = sorted(UXPLAY_PATCHES.glob("*.patch"))
    if not patches:
        raise RuntimeError(f"no UxPlay patches found in {UXPLAY_PATCHES}")
    target = THIRD_PARTY / "UxPlay"

    git = shutil.which("git")
    if git:
        for patch in patches:
            subprocess.run(
                [git, "apply", "--unidiff-zero", str(patch)],
                cwd=target,
                check=True,
            )
    else:
        patch_tool = shutil.which("patch")
        if patch_tool is None:
            raise RuntimeError("git or patch is required to apply UxPlay patches")
        for patch in patches:
            subprocess.run([patch_tool, "-p1", "-i", str(patch)], cwd=target, check=True)
    print(f"applied {len(patches)} UxPlay patches")


def _replace_once(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one match, found {count}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def _patch_openssl_cmake() -> None:
    target = THIRD_PARTY / "openssl-cmake"
    cmake_lists = target / "CMakeLists.txt"
    build = target / "cmake" / "BuildOpenSSL.cmake"

    cmake_text = cmake_lists.read_text(encoding="utf-8")
    if "set(OPENSSL_PARAMS " not in cmake_text:
        _replace_once(
            cmake_lists,
            'set(OPENSSL_RPATH "" CACHE STRING "RPath to set during build")',
            'set(OPENSSL_PARAMS "" CACHE STRING "OpenSSL configure parameters")\n'
            'set(OPENSSL_RPATH "" CACHE STRING "RPath to set during build")',
            "openssl-cmake CMakeLists.txt",
        )

    build_text = build.read_text(encoding="utf-8")
    if 'set(CONFIGURE_OPENSSL_PARAMS "${OPENSSL_PARAMS} --libdir=lib")' not in build_text:
        _replace_once(
            build,
            "set(CONFIGURE_OPENSSL_PARAMS --libdir=lib)",
            'set(CONFIGURE_OPENSSL_PARAMS "${OPENSSL_PARAMS} --libdir=lib")',
            "openssl-cmake configure params",
        )

    build_text = build.read_text(encoding="utf-8")
    if "set(FORWARD_CPPFLAGS" not in build_text:
        _replace_once(
            build,
            '        set(FORWARD_CXXFLAGS "${CMAKE_CXX_FLAGS} -Qunused-arguments")\n'
            "        set(FORWARD_LDFLAGS",
            '        set(FORWARD_CXXFLAGS "${CMAKE_CXX_FLAGS} -Qunused-arguments")\n'
            '        set(FORWARD_CPPFLAGS "${FORWARD_CXXFLAGS}")\n'
            "        set(FORWARD_LDFLAGS",
            "openssl-cmake forwarded flags",
        )

    build_text = build.read_text(encoding="utf-8")
    if "if(OPENSSL_LOCAL_TARBALL AND EXISTS" not in build_text:
        block = (
            "    # Prefer a local tarball when one is provided; the upstream mirror can\n"
            "    # drop long downloads, which breaks multi-ABI Android builds.\n"
            '    if(OPENSSL_LOCAL_TARBALL AND EXISTS "${OPENSSL_LOCAL_TARBALL}")\n'
            '        set(OPENSSL_SOURCE_URL "file://${OPENSSL_LOCAL_TARBALL}")\n'
            "    else()\n"
            '        set(OPENSSL_SOURCE_URL '
            '"https://mirror.viaduck.org/openssl/openssl-${OPENSSL_BUILD_VERSION}.tar.gz")\n'
            "    endif()\n\n"
        )
        _replace_once(
            build,
            "    # add openssl target\n",
            block + "    # add openssl target\n",
            "openssl-cmake local tarball block",
        )

        build_text = build.read_text(encoding="utf-8")
        lines = build_text.splitlines(keepends=True)
        in_openssl_target = False
        replaced = False
        for index, line in enumerate(lines):
            if "ExternalProject_Add(openssl" in line:
                in_openssl_target = True
            if in_openssl_target and line.lstrip().startswith("URL "):
                lines[index] = "        URL ${OPENSSL_SOURCE_URL}\n"
                replaced = True
                break
        if not replaced:
            raise RuntimeError("openssl-cmake ExternalProject_Add URL was not found")
        build.write_text("".join(lines), encoding="utf-8")
    print("applied local openssl-cmake patches")


def _legacy_tree_is_complete() -> bool:
    return all((THIRD_PARTY / relative).is_file() for relative in REQUIRED_PATHS)


def _check_free_space() -> None:
    usage = shutil.disk_usage(str(ROOT))
    free_mib = usage.free / 1024 / 1024
    minimum_mib = MIN_BOOTSTRAP_FREE_BYTES / 1024 / 1024
    if usage.free < MIN_BOOTSTRAP_FREE_BYTES:
        raise RuntimeError(
            f"not enough free space on {ROOT}: {free_mib:.0f} MiB available, "
            f"bootstrap needs at least {minimum_mib:.0f} MiB. "
            "Free disk space and run the bootstrap again."
        )
    if usage.free < RECOMMENDED_BUILD_FREE_BYTES:
        print(
            f"warning: only {free_mib:.0f} MiB free; the native Android build "
            "will need substantially more space",
            file=sys.stderr,
        )


def _download_openssl_tarball() -> None:
    archive = DOWNLOADS / f"openssl-{OPENSSL_VERSION}.tar.gz"
    last_error: Optional[Exception] = None
    for url in OPENSSL_URLS:
        try:
            _download(url, archive, OPENSSL_SHA256)
            last_error = None
            break
        except RuntimeError as error:
            last_error = error
            if archive.exists():
                archive.unlink()
    if last_error is not None:
        raise last_error
    target = THIRD_PARTY / "openssl-cmake" / f"openssl-{OPENSSL_VERSION}.tar.gz"
    shutil.copy2(archive, target)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--proxy", help="HTTP proxy, e.g. http://9.36.235.13:8080")
    parser.add_argument(
        "--force",
        action="store_true",
        help="replace any existing third-party trees and download them again",
    )
    args = parser.parse_args()

    global OPENER
    if args.proxy:
        proxy = args.proxy if "://" in args.proxy else f"http://{args.proxy}"
        OPENER = build_opener(ProxyHandler({"http": proxy, "https": proxy}))
    else:
        OPENER = build_opener()

    marker_text = MARKER.read_text(encoding="utf-8").strip() if MARKER.exists() else None
    if marker_text == CONFIG_VERSION and not args.force:
        print("third-party sources are already bootstrapped")
        return 0
    if marker_text is not None and marker_text != CONFIG_VERSION and not args.force:
        raise SystemExit(
            f"{MARKER} was written by {marker_text}, but this build needs {CONFIG_VERSION}. "
            "Run with --force to refresh the third-party sources."
        )
    if _legacy_tree_is_complete() and not args.force:
        MARKER.write_text(CONFIG_VERSION + "\n", encoding="utf-8")
        print("existing vendored third-party sources detected; nothing to download")
        return 0

    _check_free_space()
    DOWNLOADS.mkdir(parents=True, exist_ok=True)
    STAGING.mkdir(parents=True, exist_ok=True)
    for spec in ARCHIVES:
        _install_archive(spec)
    _apply_uxplay_patches()
    _patch_openssl_cmake()
    _download_openssl_tarball()
    MARKER.write_text(CONFIG_VERSION + "\n", encoding="utf-8")
    print("third-party sources are ready")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except OSError as error:
        if error.errno == errno.ENOSPC:
            print(
                f"error: no space left on device while accessing "
                f"{error.filename or ROOT}; free disk space and try again",
                file=sys.stderr,
            )
        else:
            print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
