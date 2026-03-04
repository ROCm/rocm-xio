# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Top-level CMake file for rocm-xio

# CMake version according to latest ROCm platform requirements
cmake_minimum_required(VERSION 3.21)

# Set the default build type to Debug
#
# NOTE: This has to be done BEFORE the project is declared!
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Debug CACHE STRING "Build type")
endif()

# Set the library version in a variable so we can use
# it in *.in files and avoid version mismatch.
set(ROCM_XIO_LIBRARY_MAJOR 0)
set(ROCM_XIO_LIBRARY_MINOR 0)
set(ROCM_XIO_LIBRARY_PATCH 1)
set(ROCM_XIO_LIBRARY_VERSION
  "${ROCM_XIO_LIBRARY_MAJOR}.${ROCM_XIO_LIBRARY_MINOR}.${ROCM_XIO_LIBRARY_PATCH}"
  CACHE STRING "ROCM-XIO library version")

# Set the SOVERSION to the major library version (this is the default
# but we set it explicitly to convey intent).
#
# Changes to minor and patch releases must NEVER break the ABI. This
# includes things like reordering struct fields that don't break the API.
set(ROCM_XIO_LIBRARY_SOVERSION
  "${ROCM_XIO_LIBRARY_MAJOR}"
)

project(rocm-xio
  VERSION ${ROCM_XIO_LIBRARY_VERSION}
  DESCRIPTION "ROCm Library for GPU-Initiated IO"
  LANGUAGES CXX HIP
)

# This project uses static libraries by necessity
option(BUILD_SHARED_LIBS "Build using shared libraries" OFF)

# AddressSanitizer option
# NOTE: ASan works for host code in HIP files. Device code instrumentation requires
# xnack+ architecture (e.g., gfx90a:xnack+). Without xnack+, only host code is instrumented.
option(ENABLE_ASAN "Enable AddressSanitizer for host code memory leak detection" OFF)

# Use position-independent code everywhere
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Everything uses C++17, which is mandatory, and we disable extensions (so no -std=gnu++17)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED TRUE)
set(CMAKE_CXX_EXTENSIONS OFF)

# Set the list of build types for ccmake/CMake GUI
#
# This turns the build type box into a multi-select so you don't have to
# enter the names manually
#
# "None" sets nothing, so it's easier to override -O flags, etc.
set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
  "Debug" "Release" "None"
)

#-----------------------------------------------------------------------------
# Valgrind memory leak detection configuration
#-----------------------------------------------------------------------------
# Option to enable/disable valgrind integration
option(ENABLE_VALGRIND "Enable valgrind memory leak detection" ON)

if(ENABLE_VALGRIND)
  # Find valgrind executable
  find_program(MEMORYCHECK_COMMAND valgrind)
  if(MEMORYCHECK_COMMAND)
    message(STATUS "valgrind found: ${MEMORYCHECK_COMMAND}")
    
    # Set valgrind options for memcheck
    # Note: Must be a single string with space-separated options, not a list
    set(MEMORYCHECK_COMMAND_OPTIONS
      "--tool=memcheck --leak-check=full --show-leak-kinds=all --track-origins=yes --error-exitcode=1 --quiet"
      CACHE STRING "Valgrind memcheck options")
    
    # Set suppression file path
    set(MEMORYCHECK_SUPPRESSIONS_FILE
      "${CMAKE_SOURCE_DIR}/scripts/test/valgrind-rocm.supp"
      CACHE FILEPATH "Valgrind suppression file")
    
    message(STATUS "Valgrind memcheck enabled")
    message(STATUS "  Options: ${MEMORYCHECK_COMMAND_OPTIONS}")
    message(STATUS "  Suppressions: ${MEMORYCHECK_SUPPRESSIONS_FILE}")
  else()
    message(STATUS "valgrind not found - memory leak detection disabled")
    message(STATUS "  Install valgrind to enable memory leak detection")
    set(ENABLE_VALGRIND OFF)
  endif()
else()
  message(STATUS "Valgrind memory leak detection disabled")
endif()

# Enable CTest (the include line automatically calls enable_testing())
include(CTest)

#-----------------------------------------------------------------------------
# Get the HIP platform
#-----------------------------------------------------------------------------
# The default is "amd" if CMAKE_HIP_PLATFORM hasn't been set
if(NOT CMAKE_HIP_PLATFORM)
    set(CMAKE_HIP_PLATFORM "amd" CACHE STRING "HIP platform to build with")
endif()
set_property(CACHE CMAKE_HIP_PLATFORM PROPERTY STRINGS "amd" "nvidia")

# Make sure the HIP platform is valid. We only allow AMD
if(NOT CMAKE_HIP_PLATFORM STREQUAL "amd")
    message(FATAL_ERROR "Invalid CMAKE_HIP_PLATFORM: '${CMAKE_HIP_PLATFORM}'. Allowed value is 'amd'.")
endif()

# Set the HIP_PLATFORM environment variable so that HIP headers are
# parsed correctly
set(ENV{HIP_PLATFORM} ${CMAKE_HIP_PLATFORM})

#-----------------------------------------------------------------------------
# Set the path to ROCm
#-----------------------------------------------------------------------------
# If ROCM_PATH was set in the environment, seed it with that
if(DEFINED ENV{ROCM_PATH})
    set(ROCM_INITIAL_PATH "$ENV{ROCM_PATH}")
else()
    set(ROCM_INITIAL_PATH "/opt/rocm")
endif()
set(ROCM_PATH "${ROCM_INITIAL_PATH}"
  CACHE PATH "The path to the ROCm installation"
)

# Set install prefix to ROCm directory (following ROCm conventions)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
    set(CMAKE_INSTALL_PREFIX "${ROCM_PATH}" CACHE PATH
        "The path where rocm-xio should be installed" FORCE)
endif()

# Fix library install directory to "lib" to be inline with the rest of ROCm
set(CMAKE_INSTALL_LIBDIR "lib" CACHE STRING
    "Directory name for installed ROCm libraries")

# Add ROCm search path
list(APPEND CMAKE_PREFIX_PATH
    ${ROCM_PATH}
)

find_package(hip CONFIG REQUIRED)
if(${hip_FOUND})
    message(STATUS "hip found @ ${hip_DIR}")
else()
    message(FATAL_ERROR "find_package did NOT find hip")
endif()

# Find hsakmt for SDMA endpoint support (required for hardware access)
find_package(hsakmt REQUIRED)
if(${hsakmt_FOUND})
    message(STATUS "hsakmt found @ ${hsakmt_DIR}")
else()
    message(FATAL_ERROR "find_package did NOT find hsakmt")
endif()

# Find libnvme (required - for host-side NVMe operations)
# libnvme provides reference implementation and helpers for NVMe operations
find_package(PkgConfig QUIET)
if(PkgConfig_FOUND)
  pkg_check_modules(LIBNVME REQUIRED libnvme)
  message(STATUS "libnvme found: ${LIBNVME_VERSION}")
  message(STATUS "  Include dirs: ${LIBNVME_INCLUDE_DIRS}")
  message(STATUS "  Library dirs: ${LIBNVME_LIBRARY_DIRS}")
else()
  # Fallback: try to find libnvme manually if pkg-config is not available
  find_path(LIBNVME_INCLUDE_DIRS
    NAMES libnvme.h
    PATHS /usr/include /usr/local/include
    REQUIRED
  )
  find_library(LIBNVME_LIBRARIES
    NAMES nvme
    PATHS /usr/lib /usr/local/lib /usr/lib/x86_64-linux-gnu
    REQUIRED
  )
  # Set version to unknown if we can't get it from pkg-config
  set(LIBNVME_VERSION "unknown")
  set(LIBNVME_LIBRARY_DIRS "")
  message(STATUS "libnvme found (via find_path/find_library)")
  message(STATUS "  Include dirs: ${LIBNVME_INCLUDE_DIRS}")
  message(STATUS "  Library dirs: ${LIBNVME_LIBRARIES}")
  message(WARNING "pkg-config not found. Install pkg-config for better libnvme detection.")
endif()
# Note: We don't link libnvme here because it's only used in host-side code
# but it's always required and available

# Include helper modules
list(APPEND CMAKE_MODULE_PATH ${CMAKE_SOURCE_DIR}/cmake)

# GPU architecture detection
set(OFFLOAD_ARCH "" CACHE STRING
  "GPU architecture (e.g., gfx942:xnack+)")
if(NOT OFFLOAD_ARCH)
  find_program(ROCMINFO rocminfo PATHS ${ROCM_PATH}/bin /opt/rocm/bin ENV PATH)
  if(ROCMINFO)
    execute_process(
      COMMAND ${ROCMINFO}
      OUTPUT_VARIABLE ROCMINFO_OUTPUT
      RESULT_VARIABLE ROCMINFO_RESULT
    )
    if(ROCMINFO_RESULT EQUAL 0)
      string(REGEX MATCH "gfx[0-9a-f]+" DETECTED_ARCH
        "${ROCMINFO_OUTPUT}")
      if(DETECTED_ARCH)
        set(OFFLOAD_ARCH ${DETECTED_ARCH})
        set(OFFLOAD_ARCH_MSG "${DETECTED_ARCH} (auto-detected)")
      else()
        set(OFFLOAD_ARCH_MSG "default (hipcc auto-detect)")
      endif()
    else()
      set(OFFLOAD_ARCH_MSG "default (hipcc auto-detect)")
    endif()
  else()
    set(OFFLOAD_ARCH_MSG "default (hipcc auto-detect)")
  endif()
else()
  set(OFFLOAD_ARCH_MSG "${OFFLOAD_ARCH} (specified)")
endif()

message(STATUS "Building for GPU architecture: ${OFFLOAD_ARCH_MSG}")

# Project directories
set(INCLUDE_DIR ${CMAKE_SOURCE_DIR}/src/include)
set(ENDPOINTS_DIR ${CMAKE_SOURCE_DIR}/src/endpoints)
set(ENDPOINTS_COMMON_DIR ${CMAKE_SOURCE_DIR}/src/endpoints/common)
set(COMMON_DIR ${CMAKE_SOURCE_DIR}/src/common)
set(TESTER_DIR ${CMAKE_SOURCE_DIR}/src/tester)
set(EXTERNAL_HEADERS_DIR ${INCLUDE_DIR}/external)
set(RDMA_HEADERS_DIR ${EXTERNAL_HEADERS_DIR}/rdma)

# Include custom CMake modules
include(EndpointDiscovery)
include(CodeGeneration)

# Discover endpoints
discover_endpoints(${ENDPOINTS_DIR} VALID_ENDPOINTS)

# Set up code generation
setup_code_generation(
  ENDPOINTS_DIR ${ENDPOINTS_DIR}
  INCLUDE_DIR ${INCLUDE_DIR}
  EXTERNAL_HEADERS_DIR ${EXTERNAL_HEADERS_DIR}
  RDMA_HEADERS_DIR ${RDMA_HEADERS_DIR}
  GENERATED_REGISTRY ${INCLUDE_DIR}/xio-endpoint-registry-gen.h
  GENERATED_INCLUDES ${INCLUDE_DIR}/xio-endpoint-includes-gen.h
  NVME_EP_GENERATED ${INCLUDE_DIR}/nvme-ep-generated.h
  RDMA_VENDOR_HEADERS
    ${ENDPOINTS_DIR}/rdma-ep/mlx/mlx5-rdma.h
    ${ENDPOINTS_DIR}/rdma-ep/bnxt/bnxt-rdma.h
    ${ENDPOINTS_DIR}/rdma-ep/ionic/ionic-rdma.h
    ${ENDPOINTS_DIR}/rdma-ep/rocm-ernic/rocm-ernic-rdma.h
)

# Discover source files
file(GLOB_RECURSE LIB_SOURCES
  ${COMMON_DIR}/*.hip
  ${ENDPOINTS_COMMON_DIR}/*.hip
)
file(GLOB_RECURSE ENDPOINT_SOURCES
  ${ENDPOINTS_DIR}/*.hip
)
# Filter out common directory from endpoint sources
list(FILTER ENDPOINT_SOURCES EXCLUDE REGEX
  "${ENDPOINTS_COMMON_DIR}/.*")
list(APPEND LIB_SOURCES ${ENDPOINT_SOURCES})

# Create static library
add_library(rocm-xio STATIC ${LIB_SOURCES})

# Set compile options for HIP files
target_compile_options(rocm-xio PRIVATE
  -Wall
  -Wextra
  -Wno-unused-parameter
)

# Add AddressSanitizer flags if enabled
# Note: AddressSanitizer can be used with HIP files for HOST code leak detection.
# Device code instrumentation requires xnack+ architecture (e.g., gfx90a:xnack+).
# Without xnack+, device code won't be instrumented (warnings will appear, but harmless).
# Host code will be fully instrumented for memory leak detection.
# To avoid linker errors, ensure OFFLOAD_ARCH doesn't include xnack+.
if(ENABLE_ASAN)
  # Check if OFFLOAD_ARCH includes xnack+ (which enables device code ASan)
  if(OFFLOAD_ARCH AND OFFLOAD_ARCH MATCHES "xnack\\+")
    message(WARNING "OFFLOAD_ARCH includes xnack+ - device code ASan may cause linker errors")
    message(WARNING "For host-only leak detection, use architecture without xnack+ (e.g., gfx1201)")
  endif()
  
  # Enable ASan for host code (device code won't be instrumented without xnack+)
  target_compile_options(rocm-xio PRIVATE
    -fsanitize=address
    -fno-omit-frame-pointer
    -g
    # Suppress warnings about ASan not being supported for device code (expected)
    -Wno-option-ignored
  )
  # Use INTERFACE linking so targets linking against rocm-xio also get ASan runtime
  target_link_options(rocm-xio INTERFACE -fsanitize=address)
  message(STATUS "AddressSanitizer enabled for rocm-xio (host code only)")
  message(STATUS "  Device code will not be instrumented (requires xnack+ architecture)")
  message(STATUS "  Host code memory leaks will be detected")
endif()

# HIP-specific compilation flags (relocatable device code)
target_compile_options(rocm-xio PRIVATE -fgpu-rdc)

# Include directories
# PUBLIC for headers that consumers need, PRIVATE for internal headers
target_include_directories(rocm-xio
  PUBLIC
    $<BUILD_INTERFACE:${INCLUDE_DIR}>
    $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}/rocm-xio>
  PRIVATE
    ${INCLUDE_DIR}
)
# Add libnvme include directories (required for host-side code)
target_include_directories(rocm-xio PRIVATE ${LIBNVME_INCLUDE_DIRS})
foreach(ep ${VALID_ENDPOINTS})
  target_include_directories(rocm-xio PRIVATE
    ${ENDPOINTS_DIR}/${ep})
endforeach()

# Link dependencies that consumers will need
# These are INTERFACE so consumers get them automatically
target_link_libraries(rocm-xio
  INTERFACE
    hip::host
    hip::device
    hsakmt::hsakmt
)
# Link libnvme (required for host-side status code helpers)
target_link_libraries(rocm-xio PRIVATE ${LIBNVME_LIBRARIES})
target_link_directories(rocm-xio PRIVATE ${LIBNVME_LIBRARY_DIRS})

# Apply endpoint defines per source file
apply_endpoint_defines(rocm-xio ${LIB_SOURCES} ${ENDPOINTS_DIR})

# Dependencies on generated files
add_dependencies(rocm-xio endpoint-registry-generated)
add_dependencies(rocm-xio nvme-ep-generated)
add_dependencies(rocm-xio rdma-vendor-headers-generated)

# Specific file dependencies
set(RDMA_VENDOR_HEADER_DEPS
  ${ENDPOINTS_DIR}/rdma-ep/mlx/mlx5-rdma.h
  ${ENDPOINTS_DIR}/rdma-ep/bnxt/bnxt-rdma.h
  ${ENDPOINTS_DIR}/rdma-ep/ionic/ionic-rdma.h
  ${ENDPOINTS_DIR}/rdma-ep/rocm-ernic/rocm-ernic-rdma.h
)
set_source_files_properties(
  ${ENDPOINTS_DIR}/rdma-ep/rdma-ep.hip
  PROPERTIES OBJECT_DEPENDS "${RDMA_VENDOR_HEADER_DEPS}"
)

set_source_files_properties(
  ${ENDPOINTS_DIR}/nvme-ep/nvme-ep.hip
  PROPERTIES OBJECT_DEPENDS
  "${INCLUDE_DIR}/nvme-ep-generated.h"
)

set_source_files_properties(
  ${ENDPOINTS_COMMON_DIR}/xio-endpoint.hip
  PROPERTIES OBJECT_DEPENDS
  "${INCLUDE_DIR}/nvme-ep-generated.h"
)

file(GLOB TESTER_SOURCES ${TESTER_DIR}/*.cpp)
file(GLOB TESTER_HEADERS ${TESTER_DIR}/*.h)
add_executable(xio-tester ${TESTER_SOURCES})

# Mark C++ sources as HIP language so they compile with hipcc
set_source_files_properties(${TESTER_SOURCES}
  PROPERTIES LANGUAGE HIP
)

target_compile_options(xio-tester PRIVATE
  -std=c++17
  -Wall
  -Wextra
  -Wno-unused-parameter
)

# Add AddressSanitizer flags if enabled
# Note: ASan works for host code in HIP files. Device code won't be instrumented
# unless xnack+ architecture is used (which may cause linker errors).
if(ENABLE_ASAN)
  target_compile_options(xio-tester PRIVATE
    -fsanitize=address
    -fno-omit-frame-pointer
    -g
    # Suppress warnings about ASan not being supported for device code (expected)
    -Wno-option-ignored
  )
  target_link_options(xio-tester PRIVATE -fsanitize=address)
  message(STATUS "AddressSanitizer enabled for xio-tester (host code only)")
endif()

target_include_directories(xio-tester PRIVATE
  ${INCLUDE_DIR}
)
# Add libnvme include directories (required for host-side code)
target_include_directories(xio-tester PRIVATE ${LIBNVME_INCLUDE_DIRS})

target_link_libraries(xio-tester PRIVATE
  rocm-xio
  hip::host
  hip::device
  hsa-runtime64::hsa-runtime64
)
# Link libnvme (required for host-side status code helpers)
target_link_libraries(xio-tester PRIVATE ${LIBNVME_LIBRARIES})
target_link_directories(xio-tester PRIVATE ${LIBNVME_LIBRARY_DIRS})

# Required when linking relocatable device code (like TransferBench)
target_link_options(xio-tester PRIVATE -fgpu-rdc)

#-----------------------------------------------------------------------------
# Register xio-tester tests with CTest for valgrind memcheck
#-----------------------------------------------------------------------------
if(BUILD_TESTING)
  # Helper function to register xio-tester test cases
  function(add_xio_tester_test TEST_NAME COMMAND_ARGS)
    add_test(NAME ${TEST_NAME} COMMAND xio-tester ${COMMAND_ARGS})
    # Note: xio-tester is built in CMAKE_CURRENT_BINARY_DIR, not bin/ subdirectory
    set_tests_properties(${TEST_NAME} PROPERTIES
      LABELS "xio-tester"
      REQUIRED_FILES "${CMAKE_CURRENT_BINARY_DIR}/xio-tester"
    )
  endfunction()
  
  # Register basic test cases (these may require hardware)
  # Mark as manual since they require NVMe hardware
  add_xio_tester_test(xio-tester-help --help)
  set_tests_properties(xio-tester-help PROPERTIES LABELS "manual")
  
  add_xio_tester_test(xio-tester-list-endpoints --list-endpoints)
  set_tests_properties(xio-tester-list-endpoints PROPERTIES LABELS "manual")
  
  # Note: Tests requiring hardware (e.g., --controller /dev/nvme0) should
  # be run manually or via test scripts, not through CTest
endif()

#-----------------------------------------------------------------------------
# Install configuration
#-----------------------------------------------------------------------------

# Include GNUInstallDirs to get CMAKE_INSTALL_INCLUDEDIR, CMAKE_INSTALL_LIBDIR, etc.
include(GNUInstallDirs)

# Install static library
install(TARGETS rocm-xio
    EXPORT rocm-xio-targets
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    COMPONENT rocm-xio
)

# Install public headers
install(FILES
    ${INCLUDE_DIR}/xio.h
    ${INCLUDE_DIR}/xio-endpoint-registry.h
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/rocm-xio
    COMPONENT rocm-xio
)

# Install generated headers (if they exist at install time)
install(FILES
    ${INCLUDE_DIR}/xio-endpoint-registry-gen.h
    ${INCLUDE_DIR}/xio-endpoint-includes-gen.h
    ${INCLUDE_DIR}/nvme-ep-generated.h
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/rocm-xio
    COMPONENT rocm-xio
    OPTIONAL
)

# Install endpoint headers
foreach(ep ${VALID_ENDPOINTS})
    file(GLOB EP_HEADERS ${ENDPOINTS_DIR}/${ep}/*.h)
    if(EP_HEADERS)
        install(FILES ${EP_HEADERS}
            DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/rocm-xio/endpoints/${ep}
            COMPONENT rocm-xio
        )
    endif()
endforeach()

# Optionally install tester executable
option(INSTALL_TESTER "Install xio-tester executable" OFF)
if(INSTALL_TESTER)
    install(TARGETS xio-tester
        RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
        COMPONENT rocm-xio-tester
    )
endif()

# Install CMake config files for find_package support
set(ROCM_XIO_CONFIG_INSTALL_DIR
    ${CMAKE_INSTALL_LIBDIR}/cmake/rocm-xio)

install(EXPORT rocm-xio-targets
    FILE rocm-xio-targets.cmake
    NAMESPACE rocm-xio::
    DESTINATION ${ROCM_XIO_CONFIG_INSTALL_DIR}
    COMPONENT rocm-xio
)

# Create and install rocm-xio-config.cmake for find_package
include(CMakePackageConfigHelpers)

# configure_package_config_file will automatically get version from project()
configure_package_config_file(
    ${CMAKE_SOURCE_DIR}/cmake/rocm-xio-config.cmake.in
    ${CMAKE_BINARY_DIR}/rocm-xio-config.cmake
    INSTALL_DESTINATION ${ROCM_XIO_CONFIG_INSTALL_DIR}
    PATH_VARS CMAKE_INSTALL_INCLUDEDIR CMAKE_INSTALL_LIBDIR
)

write_basic_package_version_file(
    ${CMAKE_BINARY_DIR}/rocm-xio-config-version.cmake
    VERSION ${ROCM_XIO_LIBRARY_VERSION}
    COMPATIBILITY SameMajorVersion
)

install(FILES
    ${CMAKE_BINARY_DIR}/rocm-xio-config.cmake
    ${CMAKE_BINARY_DIR}/rocm-xio-config-version.cmake
    DESTINATION ${ROCM_XIO_CONFIG_INSTALL_DIR}
    COMPONENT rocm-xio
)

# Add unit tests subdirectory
if(BUILD_TESTING)
  add_subdirectory(tests/unit/rdma-ep)
  add_subdirectory(tests/unit/nvme-ep)
endif()

# Utility targets
include(UtilityTargets)
