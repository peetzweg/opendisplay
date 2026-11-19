# Third-party notices

This repository is licensed under **GPL-3.0** (see the root `LICENSE`). The
Android module is distributed under the same GPLv3 terms. The AirPlay audio
engine links separately licensed upstream code; the licence options used here
are all compatible with GPLv3.

The large upstream trees are not committed. The build downloads the pinned
revisions listed below and keeps only local patches and notices here. Run
`./gradlew prepareAirplayThirdParty`, or simply build the app, to recreate
`app/src/main/cpp/third_party`.

| Component | Pinned revision | Download | Licence used here |
|---|---|---|---|
| UxPlay | `df67c212a433cf6dda3676dd40c097900d24e645` (`v1.73.7`) | [FDH2/UxPlay](https://github.com/FDH2/UxPlay/commit/df67c212a433cf6dda3676dd40c097900d24e645) | GPL-3.0 (`LICENSE` in the downloaded tree), same licence as this repository |
| FFmpeg | `38b88335f99e76ed89ff3c93f877fdefce736c13` (`n8.1.2`) | [FFmpeg/FFmpeg](https://github.com/FFmpeg/FFmpeg/commit/38b88335f99e76ed89ff3c93f877fdefce736c13) | LGPL-2.1-or-later: `cmake/BuildFFmpeg.cmake` enables only `avcodec`, `avutil` and the ALAC/AAC decoders, without `--enable-gpl` |
| libplist | `2117b8fdb6b4096455bd2041a63e59a028120136` (`2.6.0`) | [libimobiledevice/libplist](https://github.com/libimobiledevice/libplist/commit/2117b8fdb6b4096455bd2041a63e59a028120136) | LGPL-2.1-or-later option of the dual licence; see `COPYING.LESSER` |
| openssl-cmake | `61be7754dfc452fddefd896b5026d23871d71e51` | [viaduck/openssl-cmake](https://github.com/viaduck/openssl-cmake/commit/61be7754dfc452fddefd896b5026d23871d71e51) | MIT (`LICENSE` in the downloaded tree) |
| OpenSSL | `3.4.4` | [openssl.org](https://www.openssl.org/source/openssl-3.4.4.tar.gz) | Apache-2.0, GPLv3-compatible |
| Oboe | `1.9.3` | Gradle dependency `com.google.oboe:oboe` | Apache-2.0, GPLv3-compatible |

If a GPL-only FFmpeg component is enabled later, update this notice and review
the repository licence before merging.

## Source availability

The corresponding source for every linked component is identified by the exact
commit or tarball above and reconstructed by `tools/bootstrap-airplay-third-party.py`.
All local changes are kept as patches in `app/src/main/cpp/patches/UxPlay` or as
explicit edits in the bootstrap script. Anyone receiving a binary can rebuild
the exact source set from this repository plus those pinned upstream URLs. For
distribution channels that require an offline source offer, attach an archive
of the pinned source trees to the release.

OpenSSL 3.4.4 tarball SHA-256:

```text
7bdf55ac20f2779e99e5eca306f824fad2b37dee5a06cc35ed5a8b85a6060010
```

## Local modifications

- `app/src/main/cpp/patches/UxPlay/*.patch` are applied in filename order after
  UxPlay `v1.73.7` is downloaded.
- `tools/bootstrap-airplay-third-party.py` applies three small local changes to
  `openssl-cmake`: a configurable `OPENSSL_PARAMS` cache value, forwarding
  `CPPFLAGS` on Android, and using a local OpenSSL tarball instead of a flaky
  mirror download.
- The formerly integrated `android-airplay-server` code is no longer present in
  this trimmed project, so no separate `android-airplay-server-LICENSE` file is
  currently kept here. Restore its licence notice if that code is reintroduced.

The relevant build configuration lives in `app/src/main/cpp/CMakeLists.txt` and
`app/src/main/cpp/cmake/BuildFFmpeg.cmake`.
