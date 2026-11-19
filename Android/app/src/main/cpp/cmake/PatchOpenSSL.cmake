set(OPENSSL_PATCH_COMMAND PATCH_COMMAND
    ${CMAKE_COMMAND}
    -DTARGET=util/mkbuildinf.pl
    -P ${CMAKE_CURRENT_LIST_DIR}/scrub_mkbuildinf.cmake
)
