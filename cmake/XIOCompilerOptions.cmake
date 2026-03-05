# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Set compiler flags on target based on compilers being used on sources

include(XIOClangCompilerOptions)
include(XIOGNUCompilerOptions)
include(XIOSanitizers)

option(XIO_USE_CODE_COVERAGE
  "Build with code coverage instrumentation (clang only)" OFF)

function(xio_set_compiler_flags target)
    get_target_property(sources ${target} SOURCES)
    foreach(source IN LISTS sources)
        get_source_file_property(language ${source} LANGUAGE)
        set(compiler_id "${CMAKE_${language}_COMPILER_ID}")
        set(compiler_version "${CMAKE_${language}_COMPILER_VERSION}")

        if(compiler_id STREQUAL "GNU" OR compiler_id STREQUAL "NVIDIA")
            get_xio_gnu_warning_flags(compiler_flags
              ${compiler_version})
        elseif(compiler_id STREQUAL "Clang")
            get_xio_clang_warning_flags(compiler_flags
              ${compiler_version})
        endif()
        target_compile_options(${target} PRIVATE
          $<$<COMPILE_LANG_AND_ID:${language},${compiler_id}>:${compiler_flags}>)
        if(XIO_USE_CODE_COVERAGE)
            target_compile_options(${target} PRIVATE
              $<$<COMPILE_LANG_AND_ID:CXX,Clang>:-fprofile-instr-generate -fcoverage-mapping>)
            target_link_options(${target} PRIVATE
              $<$<COMPILE_LANG_AND_ID:CXX,Clang>:-fprofile-instr-generate>)
            target_link_options(${target} PRIVATE
              $<$<COMPILE_LANG_AND_ID:HIP,Clang>:-fprofile-instr-generate>)
        endif()
    endforeach()

    xio_add_sanitizers(${target})

    if(NOT BUILD_TESTING)
        target_compile_options(${target} PRIVATE -fvisibility=hidden)
    endif()
endfunction()
