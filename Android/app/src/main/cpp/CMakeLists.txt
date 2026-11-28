cmake_minimum_required(VERSION 3.22.1)
project(airplay_native C CXX)

set(CMAKE_C_STANDARD 17)
set(CMAKE_CXX_STANDARD 17)

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -ffile-prefix-map=${CMAKE_SOURCE_DIR}=. -ffile-prefix-map=${CMAKE_BINARY_DIR}=. -ffile-prefix-map=${ANDROID_NDK}=.")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -ffile-prefix-map=${CMAKE_SOURCE_DIR}=. -ffile-prefix-map=${CMAKE_BINARY_DIR}=. -ffile-prefix-map=${ANDROID_NDK}=.")

set(UXPLAY_LIB third_party/UxPlay/lib)

# ---------- OpenSSL (built from source via openssl-cmake) ----------
set(BUILD_OPENSSL ON CACHE BOOL "" FORCE)
set(OPENSSL_BUILD_VERSION "3.4.4" CACHE STRING "" FORCE)
set(CROSS_ANDROID ON CACHE BOOL "" FORCE)
string(REGEX MATCH "[0-9]+" AIRPLAY_ANDROID_API "${ANDROID_PLATFORM}")
set(OPENSSL_PARAMS "-D__ANDROID_API__=${AIRPLAY_ANDROID_API}" CACHE STRING "" FORCE)
set(FORWARD_ANDROID_NDK_ROOT "${ANDROID_NDK}" CACHE STRING "" FORCE) # CI
set(OPENSSL_LOCAL_TARBALL
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/openssl-cmake/openssl-3.4.4.tar.gz"
    CACHE FILEPATH "Local OpenSSL tarball used for offline/multi-ABI builds")

list(PREPEND CMAKE_MODULE_PATH ${CMAKE_CURRENT_SOURCE_DIR}/cmake)
add_subdirectory(third_party/openssl-cmake)

# ---------- Sanitizers (opt-in via -DSANITIZE=ON) ----------
# OpenSSL uninstrumented; HWASan is arm64-only
option(SANITIZE "Enable UBSan (and HWASan on arm64) for the native code" OFF)
if(SANITIZE)
    set(SANITIZE_CFLAGS -fno-omit-frame-pointer -fsanitize=undefined -fno-sanitize=vptr)
    set(SANITIZE_LDFLAGS -fsanitize=undefined)
    if(ANDROID_ABI STREQUAL "arm64-v8a")
        list(APPEND SANITIZE_CFLAGS -fsanitize=hwaddress)
        list(APPEND SANITIZE_LDFLAGS -fsanitize=hwaddress)
    endif()
    add_compile_options(${SANITIZE_CFLAGS})
    add_link_options(${SANITIZE_LDFLAGS})
endif()

# ---------- Oboe (low-latency audio output, via prefab AAR) ----------
find_package(oboe REQUIRED CONFIG)

# ---------- ffmpeg (software ALAC decoder) ----------
include(BuildFFmpeg)

# ---------- libplist (built from submodule source) ----------
set(PLIST_SRC third_party/libplist/src)
set(PLIST_CNARY third_party/libplist/libcnary)

add_library(plist STATIC
    ${PLIST_SRC}/base64.c
    ${PLIST_SRC}/bplist.c
    ${PLIST_SRC}/bytearray.c
    ${PLIST_SRC}/hashtable.c
    ${PLIST_SRC}/jplist.c
    ${PLIST_SRC}/jsmn.c
    ${PLIST_SRC}/oplist.c
    ${PLIST_SRC}/out-default.c
    ${PLIST_SRC}/out-limd.c
    ${PLIST_SRC}/out-plutil.c
    ${PLIST_SRC}/plist.c
    ${PLIST_SRC}/ptrarray.c
    ${PLIST_SRC}/time64.c
    ${PLIST_SRC}/xplist.c
    ${PLIST_CNARY}/cnary.c
    ${PLIST_CNARY}/node.c
    ${PLIST_CNARY}/node_list.c
)
target_include_directories(plist
    PUBLIC third_party/libplist/include
    PRIVATE ${PLIST_SRC} ${PLIST_CNARY}/include
)
target_compile_definitions(plist PRIVATE
    _GNU_SOURCE
    HAVE_STRNDUP
    PACKAGE_VERSION="2.6.0"
)

# ---------- llhttp (embedded in UxPlay) ----------
add_library(llhttp STATIC
    ${UXPLAY_LIB}/llhttp/api.c
    ${UXPLAY_LIB}/llhttp/http.c
    ${UXPLAY_LIB}/llhttp/llhttp.c
)
target_include_directories(llhttp PUBLIC ${UXPLAY_LIB}/llhttp)

# ---------- playfair (embedded in UxPlay) ----------
add_library(playfair STATIC
    ${UXPLAY_LIB}/playfair/hand_garble.c
    ${UXPLAY_LIB}/playfair/modified_md5.c
    ${UXPLAY_LIB}/playfair/omg_hax.c
    ${UXPLAY_LIB}/playfair/playfair.c
    ${UXPLAY_LIB}/playfair/sap_hash.c
)
target_include_directories(playfair PUBLIC ${UXPLAY_LIB}/playfair)

# ---------- UxPlay core (dnssd via shim) ----------
set(AIRPLAY_SOURCES
    ${UXPLAY_LIB}/airplay_video.c
    ${UXPLAY_LIB}/byteutils.c
    ${UXPLAY_LIB}/compat.c
    ${UXPLAY_LIB}/crypto.c
    ${UXPLAY_LIB}/fairplay_playfair.c
    ${UXPLAY_LIB}/http_request.c
    ${UXPLAY_LIB}/http_response.c
    ${UXPLAY_LIB}/httpd.c
    ${UXPLAY_LIB}/logger.c
    ${UXPLAY_LIB}/mirror_buffer.c
    ${UXPLAY_LIB}/netutils.c
    ${UXPLAY_LIB}/pairing.c
    ${UXPLAY_LIB}/raop.c
    ${UXPLAY_LIB}/raop_buffer.c
    ${UXPLAY_LIB}/raop_ntp.c
    ${UXPLAY_LIB}/raop_rtp.c
    ${UXPLAY_LIB}/raop_rtp_mirror.c
    ${UXPLAY_LIB}/srp.c
    ${UXPLAY_LIB}/utils.c
)

# ---------- Android JNI bridge + dnssd shim ----------
set(BRIDGE_SOURCES
    ${CMAKE_CURRENT_SOURCE_DIR}/android_dnssd_shim.c
    ${CMAKE_CURRENT_SOURCE_DIR}/android_raop_callbacks.c
    ${CMAKE_CURRENT_SOURCE_DIR}/native_bridge.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/audio_engine.cpp
)

# ---------- Final shared library ----------
add_library(airplay_native SHARED
    ${AIRPLAY_SOURCES}
    ${BRIDGE_SOURCES}
)
add_dependencies(airplay_native ffmpeg_ep)

target_include_directories(airplay_native PRIVATE
    ${UXPLAY_LIB}
    ${UXPLAY_LIB}/llhttp
    ${UXPLAY_LIB}/playfair
    ${CMAKE_CURRENT_SOURCE_DIR}
)

target_compile_definitions(airplay_native PRIVATE
    ANDROID
    __STDC_CONSTANT_MACROS
    PLIST_210
    TARGET_RT_LITTLE_ENDIAN=1
)

target_link_options(airplay_native PRIVATE "-Wl,--build-id=none")

target_link_libraries(airplay_native
    llhttp
    playfair
    crypto
    plist
    oboe::oboe
    ffmpeg::avcodec
    mediandk
    m
    log
    android
)
