# Copyright (c) 2019-2023 Advanced Micro Devices, Inc.
# All rights reserved.
# Modifications Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

cmake_minimum_required(VERSION 3.28.3 FATAL_ERROR)
project(rocm-axiio LANGUAGES CXX HIP VERSION 0.0.1)

# Declare GPU architectures to build
set(GPU_TARGETS
  gfx906
  gfx908
  gfx90a
  gfx942
  gfx950
  gfx1030
  gfx1100
  gfx1101
  gfx1102
  gfx1200
  gfx1201)
message(STATUS "Compiling for ${GPU_TARGETS}")

# Declare project options
set(ROCM_PATH /opt/rocm)
set(ENABLE_IFC 1)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall -Wextra")
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_HIP_STANDARD 17)
set(CMAKE_HIP_FLAGS "${CMAKE_HIP_FLAGS} -Wall -Wextra")
set(CMAKE_HIP_ARCHITECTURES ${DEFAULT_GPUS})
set(GPU_LIBRARIES hip::device)
set(GPU_INCLUDE_DIRS ${hip_INCLUDE_DIRS})
if(ROCM_PATH)
  list(APPEND CMAKE_PREFIX_PATH
    ${ROCM_PATH}
    ${ROCM_PATH}/hip
    ${ROCM_PATH}/llvm)
endif()

# Check for HIP
find_package(hip REQUIRED)
message(STATUS "HIP compiler:     ${HIP_COMPILER}")
message(STATUS "HIP runtime:      ${HIP_RUNTIME}")
if(NOT "${HIP_COMPILER}" MATCHES "clang")
  message(FATAL_ERROR "${CMAKE_PROJECT_NAME} requires clang-based compiler (amdclang++ or hipcc)")
endif()

## Check for HIP version
find_program(hipconfig_executable hipconfig)
message(STATUS "hipconfig executable: ${hipconfig_executable}")
execute_process(
  COMMAND         bash "-c" "${hipconfig_executable} -v | awk -F\"-\" '{ printf $1 }'"
  OUTPUT_VARIABLE hip_version_string)
message(STATUS "${COMPILER_EXE_NAME} HIP version:    ${hip_version_string}")

# Checking HIP device symbols
set(CMAKE_REQUIRED_LIBRARIES hip::device)

# Check for indirect function call support
if(ENABLE_IFC)
  if("${hip_version_string}" VERSION_GREATER_EQUAL "5.5.30201")
    set(IFC_ENABLED ON)
    message(STATUS "Indirect function call enabled")
  else()
    set(IFC_ENABLED OFF)
    message(WARNING "Indirect function call disabled - requires HIP version >= 5.5.30201")
  endif()
else()
  set(IFC_ENABLED OFF)
endif()

# Check for hsa-runtime64
find_package(hsa-runtime64 REQUIRED)
get_target_property(HSA_INCLUDE_PATH hsa-runtime64::hsa-runtime64 INTERFACE_INCLUDE_DIRECTORIES)
message(STATUS "HSA runtime: ${HSA_INCLUDE_PATH}")

# Check for --amdgpu-kernarg-preload-count
check_cxx_compiler_flag("-mllvm --amdgpu-kernarg-preload-count=16" HAVE_KERNARG_PRELOAD)
if (HAVE_KERNARG_PRELOAD)
  message(STATUS "Kernarg preloading to SGPR enabled")
endif()

check_cxx_compiler_flag("-parallel-jobs=12" HAVE_PARALLEL_JOBS)
if (HAVE_PARALLEL_JOBS)
  message(STATUS "Parallel jobs enabled")
endif()

# Find all the .hip files
file(GLOB_RECURSE HIP_SRC_FILES endpoints/*.hip)
message(STATUS "The value of HIP_SRC_FILES is: ${HIP_SRC_FILES}")

# Add the library target
add_library(rocm-axiio STATIC
  ${HIP_SRC_FILES})
target_include_directories(rocm-axiio
  SYSTEM PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/include)
set_target_properties(rocm-axiio
  PROPERTIES
  LINKER_LANGUAGE CXX
  POSITION_INDEPENDENT_CODE 1)
target_link_libraries(rocm-axiio
  PRIVATE
  ${GPU_LIBRARIES})
target_compile_definitions(rocm-axiio
  PRIVATE
  ROCM_AXIIO_USE_ROCM)
foreach(arch ${ROCM_AXIIO_GPU_ARCHS})
  target_compile_options(rocm-axiio
    PRIVATE --offload-arch=${arch})
endforeach()
target_link_libraries(rocm-axiio
  PRIVATE
  -fgpu-rdc)
add_subdirectory(tester)
