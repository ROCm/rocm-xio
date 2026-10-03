# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# XIOSanitizeImportedTargets.cmake
#
# Drop absolute library paths that do not exist from an imported target's link
# interface.
#
# The therock ROCm stream exports hsakmt::hsakmt with its build machine baked
# in:
#
#   INTERFACE_LINK_LIBRARIES "-L/__w/rockrel/rockrel/build/third-party/...;
#     $<LINK_ONLY:-ldrm>;$<LINK_ONLY:pthread>;$<LINK_ONLY:rt>;
#     /usr/lib64/libc.so;$<LINK_ONLY:numa::numa>;$<LINK_ONLY:dl>"
#
# /usr/lib64/libc.so is that builder's manylinux libc. On Ubuntu libc lives in
# /usr/lib/x86_64-linux-gnu, so every executable linking hsakmt fails with
# "No rule to make target '/usr/lib64/libc.so'" -- make treats an absolute path
# in a link line as a file it must be able to produce. Dropping it is safe: the
# compiler driver links libc regardless.
#
# Only non-existent absolute *file* paths are removed. -L flags are left alone
# even when they point at nothing, because a stale -L is harmless to the linker
# and removing one could change which copy of a library gets picked up.

function(xio_sanitize_imported_target target)
    if(NOT TARGET ${target})
        return()
    endif()

    get_target_property(_libs ${target} INTERFACE_LINK_LIBRARIES)
    if(NOT _libs)
        return()
    endif()

    set(_kept "")
    set(_dropped "")
    foreach(_entry IN LISTS _libs)
        # Look inside $<LINK_ONLY:...> so a wrapped path is judged on the path.
        set(_path "${_entry}")
        if(_path MATCHES "^\\$<LINK_ONLY:(.*)>$")
            set(_path "${CMAKE_MATCH_1}")
        endif()

        if(_path MATCHES "^/" AND NOT EXISTS "${_path}")
            list(APPEND _dropped "${_path}")
        else()
            list(APPEND _kept "${_entry}")
        endif()
    endforeach()

    if(_dropped)
        message(STATUS
            "${target}: dropping non-existent absolute link entries: ${_dropped}")
        set_target_properties(${target} PROPERTIES
            INTERFACE_LINK_LIBRARIES "${_kept}")
    endif()
endfunction()
