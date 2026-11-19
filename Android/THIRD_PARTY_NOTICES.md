# Third-party notices

The AirPlay audio engine uses upstream source trees that are licensed
separately from this repository. The large trees are not committed; the build
downloads the pinned revisions listed below and keeps only local patches and
notices here. Run `./gradlew prepareAirplayThirdParty`, or simply build the app,
to recreate `app/src/main/cpp/third_party`.

If you distribute a binary built from these sources, follow the obligations of
each licence, including providing the corresponding source where required.

| Component | Pinned revision | Download | Licence |
|---|---|---|---|
| UxPlay | `df67c212a433cf6dda3676dd40c097900d24e645` (`v1.73.7`) | [FDH2/UxPlay](https://github.com/FDH2/UxPlay/commit/df67c212a433cf6dda3676dd40c097900d24e645) | GPL-3.0 (`LICENSE` in the downloaded tree) |
| FFmpeg | `38b88335f99e76ed89ff3c93f877fdefce736c13` (`n8.1.2`) | [FFmpeg/FFmpeg](https://github.com/FFmpeg/FFmpeg/commit/38b88335f99e76ed89ff3c93f877fdefce736c13) | LGPL/GPL depending on build options; see `COPYING*` in the downloaded tree |
| libplist | `2117b8fdb6b4096455bd2041a63e59a028120136` (`2.6.0`) | [libimobiledevice/libplist](https://github.com/libimobiledevice/libplist/commit/2117b8fdb6b4096455bd2041a63e59a028120136) | GPL-2.0 / LGPL-2.1; see `COPYING` and `COPYING.LESSER` |
| openssl-cmake | `61be7754dfc452fddefd896b5026d23871d71e51` | [viaduck/openssl-cmake](https://github.com/viaduck/openssl-cmake/commit/61be7754dfc452fddefd896b5026d23871d71e51) | MIT (`LICENSE` in the downloaded tree) |
| OpenSSL | `3.4.4` | [openssl.org](https://www.openssl.org/source/openssl-3.4.4.tar.gz) | Apache-2.0 |
| Oboe | `1.9.3` | Gradle dependency `com.google.oboe:oboe` | Apache-2.0 |

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
