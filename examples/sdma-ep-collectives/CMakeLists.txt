# SDMA Collective Examples

cmake_minimum_required(VERSION 3.21)
project(sdma-ep-collectives LANGUAGES CXX HIP)

# Add local install directory and ROCm to prefix path
set(CMAKE_PREFIX_PATH "/home/dasidler/rocm-xio/install;/opt/rocm" ${CMAKE_PREFIX_PATH})

find_package(rocm-xio REQUIRED)
find_package(hsa-runtime64 CONFIG REQUIRED)
find_package(MPI REQUIRED)

# AllReduce executable - compile common code with HIP compiler
add_executable(sdma-ep-allreduce
  sdma_allreduce.hip
  sdma_common.cpp
)

# Force sdma_common.cpp to be compiled as HIP
set_source_files_properties(sdma_common.cpp PROPERTIES LANGUAGE HIP)

target_link_libraries(sdma-ep-allreduce PRIVATE
  rocm-xio::rocm-xio
  hsa-runtime64::hsa-runtime64
  MPI::MPI_CXX
)

if(NOT ROCM_XIO_SHARED_LIBS)
  target_link_options(sdma-ep-allreduce PRIVATE -fgpu-rdc)
endif()

target_include_directories(sdma-ep-allreduce PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${MPI_CXX_INCLUDE_DIRS}
)
