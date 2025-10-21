# MIT License
#
# Copyright (c) 2022-2025 Advanced Micro Devices, Inc. All rights reserved.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

cmake_minimum_required(VERSION 3.21.3 FATAL_ERROR)
project(rocm-axiio LANGUAGES CXX HIP VERSION 0.0.1)

# ROCm installation path
set(ROCM_ROOT "/opt/rocm" CACHE PATH
  "Root directory of the ROCm installation"
)
set(ROCM_LLVM_ROOT "${ROCM_ROOT}/llvm")
set(PREFIX_LLVM_ROOT "${CMAKE_INSTALL_PREFIX}/llvm")

# HIP Runtime
set(GPU_RUNTIME "HIP" CACHE STRING "Switches between HIP and CUDA")
set(GPU_RUNTIMES "HIP" "CUDA")
set_property(CACHE GPU_RUNTIME PROPERTY STRINGS ${GPU_RUNTIMES})

if(NOT "${GPU_RUNTIME}" IN_LIST GPU_RUNTIMES)
    set(ERROR_MESSAGE
        "GPU_RUNTIME is set to \"${GPU_RUNTIME}\".\nGPU_RUNTIME must be either HIP or CUDA."
    )
    message(FATAL_ERROR ${ERROR_MESSAGE})
endif()

# Find all the .hip files
file(GLOB_RECURSE HIP_SRC_FILES endpoints/*.hip)
message(STATUS "The value of HIP_SRC_FILES is: ${HIP_SRC_FILES}")

add_library(${CMAKE_PROJECT_NAME}
  SHARED
  ${HIP_SRC_FILES})

target_include_directories(${CMAKE_PROJECT_NAME}
  PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/include)
install(TARGETS
  ${CMAKE_PROJECT_NAME}
  LIBRARY DESTINATION ${CMAKE_CURRENT_SOURCE_DIR}/lib
  ARCHIVE DESTINATION ${CMAKE_CURRENT_SOURCE_DIR}/lib
  PUBLIC_HEADER DESTINATION ${CMAKE_CURRENT_SOURCE_DIR}/include)

add_subdirectory(tester)
