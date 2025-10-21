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
project(axiio-tester LANGUAGES CXX HIP VERSION 0.0.1)

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

# Find all the .cpp and .hip files
file(GLOB HIP_SRC_FILES src/*.hip)
file(GLOB SRC_FILES src/*.cpp)

# Create a axiio-tester executable
add_executable(${CMAKE_PROJECT_NAME}
  ${SRC_FILES}
  ${HIP_SRC_FILES}
)

# Find the libraries and packages we need
find_package(CLI11 2.4.1 REQUIRED)
if (CLI11_FOUND)
    message(STATUS "CLI11 found, version ${CLI11_VERSION}")
    target_link_libraries(${CMAKE_PROJECT_NAME}
        PRIVATE CLI11::CLI11)
else()
    message(FATAL_ERROR "CLI11 not found!")
endif()

