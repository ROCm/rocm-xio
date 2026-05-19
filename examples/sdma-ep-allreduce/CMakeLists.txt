# SDMA AllReduce Example

cmake_minimum_required(VERSION 3.21)
project(sdma-ep-allreduce LANGUAGES CXX HIP)

find_package(rocm-xio REQUIRED)
find_package(hsa-runtime64 CONFIG REQUIRED)
find_package(MPI REQUIRED)

add_executable(sdma-ep-allreduce sdma-ep-allreduce.hip)

target_link_libraries(sdma-ep-allreduce PRIVATE
  rocm-xio::rocm-xio
  hsa-runtime64::hsa-runtime64
  MPI::MPI_CXX
)

if(NOT ROCM_XIO_SHARED_LIBS)
  target_link_options(sdma-ep-allreduce PRIVATE -fgpu-rdc)
endif()

target_include_directories(sdma-ep-allreduce PRIVATE
  ${MPI_CXX_INCLUDE_DIRS}
)
