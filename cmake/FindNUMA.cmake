# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# FindNUMA.cmake
#
# Locate libnuma and expose it as NUMA::NUMA.
#
# This exists to work around a packaging bug we do not own. The therock ROCm
# stream's hsakmt-config.cmake calls find_dependency(NUMA) but installs no
# FindNUMA.cmake or NUMAConfig.cmake next to it, so find_package(hsakmt) fails
# with "Could not find a package configuration file provided by NUMA" on any
# consumer -- installing libnuma-dev cannot help, because Debian ships headers
# and a library, not CMake package files. The ROCm 7.1 packages get away with
# it only because their hsakmt-config.cmake leaves the find_dependency line
# commented out.
#
# cmake/ is on CMAKE_MODULE_PATH before find_package(hsakmt) runs, so CMake
# picks this up in module mode and the config-mode search never happens.
# Delete this once the therock hsakmt package installs its own.

find_path(NUMA_INCLUDE_DIR NAMES numa.h)
find_library(NUMA_LIBRARY NAMES numa)

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(NUMA
    REQUIRED_VARS NUMA_LIBRARY NUMA_INCLUDE_DIR)

if(NUMA_FOUND)
    set(NUMA_LIBRARIES ${NUMA_LIBRARY})
    set(NUMA_INCLUDE_DIRS ${NUMA_INCLUDE_DIR})

    # Both spellings, and GLOBAL so they are visible wherever hsakmt is used.
    # NUMA::NUMA is the conventional name a Find module exports; numa::numa is
    # the name therock's hsakmtTargets.cmake actually puts in its link
    # interface, and CMake errors at generate time on an unknown target there.
    foreach(_numa_target NUMA::NUMA numa::numa)
        if(NOT TARGET ${_numa_target})
            add_library(${_numa_target} UNKNOWN IMPORTED GLOBAL)
            set_target_properties(${_numa_target} PROPERTIES
                IMPORTED_LOCATION "${NUMA_LIBRARY}"
                INTERFACE_INCLUDE_DIRECTORIES "${NUMA_INCLUDE_DIR}")
        endif()
    endforeach()
endif()

mark_as_advanced(NUMA_INCLUDE_DIR NUMA_LIBRARY)
