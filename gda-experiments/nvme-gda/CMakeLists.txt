cmake_minimum_required(VERSION 3.21)
project(nvme_gda LANGUAGES C CXX)

# ROCm/HIP setup
if(NOT DEFINED ROCM_PATH)
    set(ROCM_PATH "/opt/rocm" CACHE PATH "Path to ROCm installation")
endif()

list(APPEND CMAKE_PREFIX_PATH ${ROCM_PATH})

# Enable HIP language support
enable_language(HIP)

# HSA setup
find_path(HSA_INCLUDE_DIR hsa/hsa.h
    HINTS ${ROCM_PATH}/include /opt/rocm/include
)
find_library(HSA_LIBRARY hsa-runtime64
    HINTS ${ROCM_PATH}/lib /opt/rocm/lib
)

if(NOT HSA_INCLUDE_DIR OR NOT HSA_LIBRARY)
    message(FATAL_ERROR "HSA runtime not found")
endif()

message(STATUS "ROCM_PATH: ${ROCM_PATH}")
message(STATUS "HSA_INCLUDE_DIR: ${HSA_INCLUDE_DIR}")
message(STATUS "HSA_LIBRARY: ${HSA_LIBRARY}")

# Compiler flags
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -Wall -Wextra")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall -Wextra")

# HIP/GPU flags - following rocSHMEM GDA pattern
set(CMAKE_HIP_ARCHITECTURES "gfx90a;gfx942;gfx1100" CACHE STRING "GPU architectures")
set(CMAKE_HIP_FLAGS "-fgpu-rdc -O2")  # -fgpu-rdc is CRITICAL for GDA device code linking

# Include directories
include_directories(
    ${CMAKE_SOURCE_DIR}/include
    ${CMAKE_SOURCE_DIR}/nvme_gda_driver
    ${HSA_INCLUDE_DIR}
)

# Userspace library
add_library(nvme_gda SHARED
    lib/nvme_gda.cpp
)

target_link_libraries(nvme_gda
    ${HSA_LIBRARY}
)

# GPU device library (compiled with HIP) - STATIC for RDC linking
add_library(nvme_gda_device STATIC
    lib/nvme_gda_device.hip
)

set_source_files_properties(lib/nvme_gda_device.hip PROPERTIES LANGUAGE HIP)

# Enable RDC for device code linking (like rocSHMEM GDA)
set_target_properties(nvme_gda_device PROPERTIES
    HIP_SEPARABLE_COMPILATION ON
    POSITION_INDEPENDENT_CODE ON
)

target_link_libraries(nvme_gda_device
    nvme_gda
)

# Test programs
add_executable(test_basic_doorbell
    tests/test_basic_doorbell.hip
)

set_source_files_properties(tests/test_basic_doorbell.hip PROPERTIES LANGUAGE HIP)

# Enable RDC for tests
set_target_properties(test_basic_doorbell PROPERTIES
    HIP_SEPARABLE_COMPILATION ON
)

target_link_libraries(test_basic_doorbell
    nvme_gda_device
    nvme_gda
    ${HSA_LIBRARY}
)

# Add -fgpu-rdc to linker flags (needed for RDC)
target_link_options(test_basic_doorbell PRIVATE -fgpu-rdc)

add_executable(test_gpu_io
    tests/test_gpu_io.hip
)

set_source_files_properties(tests/test_gpu_io.hip PROPERTIES LANGUAGE HIP)

set_target_properties(test_gpu_io PROPERTIES
    HIP_SEPARABLE_COMPILATION ON
)

target_link_libraries(test_gpu_io
    nvme_gda_device
    nvme_gda
    ${HSA_LIBRARY}
)

# Add -fgpu-rdc to linker flags (needed for RDC)
target_link_options(test_gpu_io PRIVATE -fgpu-rdc)

# Install targets
install(TARGETS nvme_gda nvme_gda_device
    LIBRARY DESTINATION lib
)

install(FILES include/nvme_gda.h
    DESTINATION include
)

install(TARGETS test_basic_doorbell test_gpu_io
    RUNTIME DESTINATION bin
)

# Print build configuration
message(STATUS "=================================")
message(STATUS "NVMe GDA Build Configuration")
message(STATUS "=================================")
message(STATUS "Build type: ${CMAKE_BUILD_TYPE}")
message(STATUS "C compiler: ${CMAKE_C_COMPILER}")
message(STATUS "CXX compiler: ${CMAKE_CXX_COMPILER}")
message(STATUS "HIP compiler: ${HIP_HIPCC_EXECUTABLE}")
message(STATUS "=================================")

