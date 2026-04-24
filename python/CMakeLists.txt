# Python bindings for SDMA endpoint

cmake_minimum_required(VERSION 3.25)

# Find Python
find_package(Python 3.10 REQUIRED COMPONENTS Interpreter Development.Module)

# Fetch Nanobind
include(FetchContent)
FetchContent_Declare(
  nanobind
  GIT_REPOSITORY https://github.com/wjakob/nanobind.git
  GIT_TAG v1.4.0
  GIT_SHALLOW TRUE
)
FetchContent_MakeAvailable(nanobind)

# Create Python extension module
nanobind_add_module(sdma_ep_py sdma_ep_py.cpp)

# Set compiler to hipcc
set_target_properties(sdma_ep_py PROPERTIES
  CXX_COMPILER ${CMAKE_CXX_COMPILER}
)

# Find HIP, HSA, and hsakmt
find_package(HIP REQUIRED)
find_package(hsa-runtime64 REQUIRED HINTS /opt/rocm)
find_package(hsakmt REQUIRED)

# Include directories
target_include_directories(sdma_ep_py PRIVATE
  ${CMAKE_SOURCE_DIR}/src/endpoints/sdma-ep
  ${HIP_INCLUDE_DIRS}
  ${hsa-runtime64_INCLUDE_DIRS}
)

# Link libraries
target_link_libraries(sdma_ep_py PRIVATE
  rocm-xio
  hip::host
  hsa-runtime64::hsa-runtime64
  hsakmt::hsakmt
)

# Install to xio.sdma_ep package directory
install(TARGETS sdma_ep_py
  LIBRARY DESTINATION ${CMAKE_CURRENT_SOURCE_DIR}/xio/sdma_ep
)
