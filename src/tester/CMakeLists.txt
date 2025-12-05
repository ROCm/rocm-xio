# Copyright (c) 2019-2023 Advanced Micro Devices, Inc.
# All rights reserved.
# Modifications Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

cmake_minimum_required(VERSION 3.21.3 FATAL_ERROR)
project(axiio-tester LANGUAGES CXX HIP VERSION 0.0.1)

# Find all the .cpp and .hip files
file(GLOB SRC_FILES *.hip)

# Create a axiio-tester executable
add_executable(${PROJECT_NAME}
  ${SRC_FILES})

# Add librocm-axxio library
find_library(LIBROCM_AXIIO
  rocm-axiio
  ../build)
if (LIBROCM_AXIIO)
    message(STATUS "Found librocm-axiio: ${LIBROCM_AXIIO}")
    target_link_libraries(${PROJECT_NAME}
            PUBLIC ${LIBROCM_AXIIO})
else()
    message(FATAL_ERROR "librocm-axiio not found!")
endif()
include_directories(../include)
set(CMAKE_REQUIRED_LIBRARIES hip::device hip::host)

find_package(hsa-runtime64 REQUIRED)
get_target_property(HSA_INCLUDE_PATH hsa-runtime64::hsa-runtime64 INTERFACE_INCLUDE_DIRECTORIES)


# Find the libraries and packages we need
find_package(CLI11 2.4.1 REQUIRED)
if (CLI11_FOUND)
    message(STATUS "CLI11 found, version ${CLI11_VERSION}")
    target_link_libraries(${PROJECT_NAME}
        PUBLIC CLI11::CLI11)
else()
    message(FATAL_ERROR "CLI11 not found!")
endif()

find_package(HIP REQUIRED)
if (HIP_FOUND)
    message(STATUS "HIP found, version ${HIP_VERSION}")
    target_link_libraries(${PROJECT_NAME}
      PRIVATE hip::host hip::device
      ${HIP_CXX_LIBRARIES})
else()
    message(FATAL_ERROR "HIP not found!")
endif()
target_compile_options(${PROJECT_NAME}
  PRIVATE
  -fgpu-rdc)
#target_link_options(${PROJECT_NAME} PUBLIC "-llibrocm-axiio")

install(TARGETS
  ${PROJECT_NAME} DESTINATION
  ${CMAKE_SOURCE_DIR}/bin)
