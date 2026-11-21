file(READ "${TARGET}" _c)
if(NOT _c MATCHES "ffile-prefix-map")
    string(REPLACE
        "my $cflags = join(' ', @ARGV);"
        "my $cflags = join(' ', @ARGV);\n$cflags =~ s/-ffile-prefix-map=\\S+\\s*//g;"
        _c "${_c}")
    file(WRITE "${TARGET}" "${_c}")
endif()
