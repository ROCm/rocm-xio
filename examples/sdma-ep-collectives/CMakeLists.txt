# SDMA Collective Examples

cmake_minimum_required(VERSION 3.21)
project(sdma-ep-collectives LANGUAGES CXX HIP)

set(CMAKE_PREFIX_PATH "/home/dasidler/rocm-xio/install;/opt/rocm" ${CMAKE_PREFIX_PATH})

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

