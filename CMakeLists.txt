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
set(ROCM_XIO_LIBRARY_MINOR 1)
set(ROCM_XIO_LIBRARY_PATCH 0)
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

option(XIO_DOCS_ONLY
  "Only configure documentation targets (no HIP/ROCm needed)"
  OFF)

if(XIO_DOCS_ONLY)
  project(rocm-xio
    VERSION ${ROCM_XIO_LIBRARY_VERSION}
    DESCRIPTION "ROCm Library for GPU-Initiated IO"
    LANGUAGES CXX
  )
else()
  project(rocm-xio
    VERSION ${ROCM_XIO_LIBRARY_VERSION}
    DESCRIPTION "ROCm Library for GPU-Initiated IO"
    LANGUAGES CXX HIP
  )
endif()

# Add cmake/ to the module search path (all modes need this)
list(APPEND CMAKE_MODULE_PATH ${CMAKE_SOURCE_DIR}/cmake)

if(NOT XIO_DOCS_ONLY)

# This project uses static libraries by necessity
option(BUILD_SHARED_LIBS "Build using shared libraries" OFF)

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

# Include build options modules early so options are available
# This makes XIO_USE_SANITIZERS, XIO_USE_CODE_COVERAGE available as
# cmake command-line options
include(XIOCompilerOptions)

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
set(NVME_HEADERS_DIR ${EXTERNAL_HEADERS_DIR}/nvme)

# Include custom CMake modules
include(XIOEndpointDiscovery)
include(XIOCodeGeneration)

# Discover endpoints
discover_endpoints(${ENDPOINTS_DIR} VALID_ENDPOINTS)

# Set up code generation
setup_code_generation(
  ENDPOINTS_DIR ${ENDPOINTS_DIR}
  INCLUDE_DIR ${INCLUDE_DIR}
  EXTERNAL_HEADERS_DIR ${EXTERNAL_HEADERS_DIR}
  RDMA_HEADERS_DIR ${RDMA_HEADERS_DIR}
  NVME_HEADERS_DIR ${NVME_HEADERS_DIR}
  GENERATED_REGISTRY ${INCLUDE_DIR}/xio-endpoint-registry-gen.h
  GENERATED_INCLUDES ${INCLUDE_DIR}/xio-endpoint-includes-gen.h
  NVME_EP_GENERATED ${INCLUDE_DIR}/nvme-ep-generated.h
)

# GDA provider options for RDMA endpoint
option(GDA_BNXT "Build BNXT (Broadcom Thor 2) RDMA provider" ON)
option(GDA_MLX5 "Build MLX5 (Mellanox ConnectX) RDMA provider" OFF)
option(GDA_IONIC "Build IONIC (Pensando) RDMA provider" OFF)
option(GDA_ERNIC "Build ROCm ERNIC RDMA provider" OFF)

# Build rdma-core with bnxt Direct Verbs patches
if(GDA_BNXT)
  include(XIOBnxtDirectVerbs)
endif()

# Build rdma-core with ROCm ERNIC DV provider
if(GDA_ERNIC)
  include(XIOErnicDirectVerbs)
endif()

# IONIC kernel module (DKMS) targets
if(GDA_IONIC)
  include(XIOIonicKernelModule)
endif()

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
# Filter out vendor queue-pair device code files (they are #included from queue-pair.hip)
list(FILTER ENDPOINT_SOURCES EXCLUDE REGEX
  "${ENDPOINTS_DIR}/rdma-ep/(bnxt|mlx5|ionic|rocm-ernic)/.*-queue-pair\\.hip")
list(APPEND LIB_SOURCES ${ENDPOINT_SOURCES})

# Add new GDA shared infrastructure (C++ sources, not HIP)
list(APPEND LIB_SOURCES
  ${COMMON_DIR}/ibv-wrapper.cpp
  ${COMMON_DIR}/rdma-topology.cpp
  ${COMMON_DIR}/rdma-numa-wrapper.cpp
)

# Add GDA backend for rdma-ep
list(APPEND LIB_SOURCES
  ${ENDPOINTS_DIR}/rdma-ep/gda-backend.cpp
)

# Add BNXT vendor backend (always compiled, conditionally active via GDA_BNXT)
if(GDA_BNXT)
  list(APPEND LIB_SOURCES
    ${ENDPOINTS_DIR}/rdma-ep/bnxt/bnxt-backend.cpp
  )
  set_source_files_properties(
    ${ENDPOINTS_DIR}/rdma-ep/bnxt/bnxt-backend.cpp
    PROPERTIES LANGUAGE HIP
  )
endif()

# Add ERNIC vendor backend
if(GDA_ERNIC)
  list(APPEND LIB_SOURCES
    ${ENDPOINTS_DIR}/rdma-ep/rocm-ernic/ernic-backend.cpp
  )
  set_source_files_properties(
    ${ENDPOINTS_DIR}/rdma-ep/rocm-ernic/ernic-backend.cpp
    PROPERTIES LANGUAGE HIP
  )
endif()

# Add IONIC vendor backend
if(GDA_IONIC)
  list(APPEND LIB_SOURCES
    ${ENDPOINTS_DIR}/rdma-ep/ionic/ionic-backend.cpp
  )
  set_source_files_properties(
    ${ENDPOINTS_DIR}/rdma-ep/ionic/ionic-backend.cpp
    PROPERTIES LANGUAGE HIP
  )
endif()

# Mark C++ sources as HIP language for hipcc compilation
set_source_files_properties(
  ${COMMON_DIR}/ibv-wrapper.cpp
  ${COMMON_DIR}/rdma-topology.cpp
  ${COMMON_DIR}/rdma-numa-wrapper.cpp
  ${ENDPOINTS_DIR}/rdma-ep/gda-backend.cpp
  PROPERTIES LANGUAGE HIP
)

# Create static library
add_library(rocm-xio STATIC ${LIB_SOURCES})

# Set compile options for HIP files
target_compile_options(rocm-xio PRIVATE
  -Wall
  -Wextra
  -Wno-unused-parameter
)

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
    ${COMMON_DIR}
)
foreach(ep ${VALID_ENDPOINTS})
  target_include_directories(rocm-xio PRIVATE
    ${ENDPOINTS_DIR}/${ep})
endforeach()

# GDA provider compile definitions
if(GDA_BNXT)
  target_compile_definitions(rocm-xio PRIVATE GDA_BNXT)
endif()
if(GDA_MLX5)
  target_compile_definitions(rocm-xio PRIVATE GDA_MLX5)
endif()
if(GDA_IONIC)
  target_compile_definitions(rocm-xio PRIVATE GDA_IONIC)
endif()
if(GDA_ERNIC)
  target_compile_definitions(rocm-xio PRIVATE GDA_ERNIC)
endif()

# Link dependencies that consumers will need
# These are INTERFACE so consumers get them automatically
target_link_libraries(rocm-xio
  INTERFACE
    hip::host
    hip::device
    hsakmt::hsakmt
)

# dlopen support for IBV wrapper and vendor DV libs
target_link_libraries(rocm-xio PRIVATE dl)

# Apply endpoint defines per source file
apply_endpoint_defines(rocm-xio ${LIB_SOURCES} ${ENDPOINTS_DIR})

# Dependencies on generated files
add_dependencies(rocm-xio endpoint-registry-generated)
add_dependencies(rocm-xio nvme-ep-generated)

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

target_include_directories(xio-tester PRIVATE
  ${INCLUDE_DIR}
)

target_link_libraries(xio-tester PRIVATE
  rocm-xio
  hip::host
  hip::device
  hsa-runtime64::hsa-runtime64
)

# Required when linking relocatable device code (like TransferBench)
target_link_options(xio-tester PRIVATE -fgpu-rdc)

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
endif()

endif() # NOT XIO_DOCS_ONLY

# Documentation (optional, requires -DXIO_BUILD_DOCS=ON)
include(XIODocumentation)

# Utility targets
include(XIOUtilityTargets)
