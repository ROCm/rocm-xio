# FindNUMA.cmake
#
# Shim required by hsakmt-config.cmake, which unconditionally calls
# find_dependency(NUMA). Ubuntu's libnuma-dev ships a .so and pkg-config
# but no cmake config file, so hsakmt's find_dependency fails without this.
#
# Sets NUMA_FOUND and the imported target NUMA::NUMA when libnuma is present.

find_library(NUMA_LIBRARY NAMES numa)
find_path(NUMA_INCLUDE_DIR NAMES numa.h)

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(NUMA
  REQUIRED_VARS NUMA_LIBRARY NUMA_INCLUDE_DIR)

if(NUMA_FOUND)
  if(NOT TARGET NUMA::NUMA)
    add_library(NUMA::NUMA UNKNOWN IMPORTED)
    set_target_properties(NUMA::NUMA PROPERTIES
      IMPORTED_LOCATION "${NUMA_LIBRARY}"
      INTERFACE_INCLUDE_DIRECTORIES "${NUMA_INCLUDE_DIR}")
  endif()
  # hsakmtTargets.cmake references numa::numa (lowercase); provide an alias.
  if(NOT TARGET numa::numa)
    add_library(numa::numa ALIAS NUMA::NUMA)
  endif()
endif()
