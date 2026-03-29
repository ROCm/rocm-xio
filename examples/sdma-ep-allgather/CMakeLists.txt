# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Example: MPI allgather via shader-initiated SDMA
#
# Each MPI rank owns one GPU. The GPU kernel uses the
# sdma_ep device-side API to copy its local data into
# every other rank's output buffer, implementing a
# GPU-initiated allgather collective.
#
# Requires:
#   - MPI (OpenMPI, MPICH, etc.)
#   - N GPUs with XGMI / Infinity Fabric P2P access
#     (one GPU per MPI rank)
#
# Build against an installed rocm-xio:
#   cmake -S . -B build \
#     -DCMAKE_PREFIX_PATH=<install-prefix>
#   cmake --build build
#
# Run:
#   mpirun -np <N> ./build/sdma-ep-allgather

cmake_minimum_required(VERSION 3.21)
project(sdma-ep-allgather LANGUAGES CXX HIP)

find_package(rocm-xio REQUIRED)
find_package(MPI REQUIRED)

add_executable(sdma-ep-allgather sdma-ep-allgather.hip)
target_link_libraries(sdma-ep-allgather PRIVATE
  rocm-xio::rocm-xio
  MPI::MPI_CXX)
target_include_directories(sdma-ep-allgather PRIVATE
  ${MPI_CXX_INCLUDE_DIRS})
