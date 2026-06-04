# SDMA Collective Examples

cmake_minimum_required(VERSION 3.21)
project(sdma-ep-collectives LANGUAGES CXX HIP)

# Pass -DCMAKE_PREFIX_PATH=/path/to/rocm-xio/install (and optionally
# /opt/rocm) on the cmake command line, or set rocm-xio_DIR /
# hsa-runtime64_DIR in the environment to point at non-default install
# trees. No developer-specific paths are baked into this CMake file.

find_package(rocm-xio REQUIRED)
find_package(hsa-runtime64 CONFIG REQUIRED)
find_package(MPI REQUIRED)

set_source_files_properties(sdma_common.cpp PROPERTIES LANGUAGE HIP)

function(add_sdma_collective_example NAME SOURCE)
  add_executable(${NAME} ${SOURCE} sdma_common.cpp)

  target_link_libraries(${NAME} PRIVATE
    rocm-xio::rocm-xio
    hsa-runtime64::hsa-runtime64
    MPI::MPI_CXX
  )

  if(NOT ROCM_XIO_SHARED_LIBS)
    target_link_options(${NAME} PRIVATE -fgpu-rdc)
  endif()

  target_include_directories(${NAME} PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${MPI_CXX_INCLUDE_DIRS}
  )
endfunction()

add_sdma_collective_example(sdma-ep-allgather sdma_allgather.hip)
add_sdma_collective_example(sdma-ep-alltoall sdma_alltoall.hip)

