# Python bindings for SDMA endpoint

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

# Link rocm-xio library file directly to avoid inheriting HIP device flags
# (--offload-arch, --hip-link) from its INTERFACE dependencies, which break
# pure C++ compilation. Runtime dependencies added explicitly.
target_link_libraries(sdma_ep_py PRIVATE
  $<TARGET_FILE:rocm-xio>
  hip::host
  hsa-runtime64::hsa-runtime64
  hsakmt::hsakmt
)

# Ensure rocm-xio is built before the Python extension
add_dependencies(sdma_ep_py rocm-xio)

# Install the extension into the xio.sdma_ep package. scikit-build-core
# sets CMAKE_INSTALL_PREFIX to the wheel staging directory, so a
# relative destination keeps the source tree clean and lets the wheel
# pick up the .so via wheel.packages = ["python/xio"] in pyproject.toml.
install(TARGETS sdma_ep_py
  LIBRARY DESTINATION xio/sdma_ep
)

# Python bindings for the RDMA endpoint (GPU-initiated RDMA). Needs a compiled-in
# provider (GDA_MLX5, GDA_BNXT, ...). Unlike sdma_ep_py this module launches GPU
# kernels that live in the -fgpu-rdc rocm-xio library, so it is compiled and linked
# as HIP with -fgpu-rdc (device linking happens here, as for the tests).
if(GDA_BNXT OR GDA_MLX5 OR GDA_IONIC OR GDA_ERNIC)
  nanobind_add_module(rdma_ep_py rdma_ep_py.cpp)
  set_source_files_properties(rdma_ep_py.cpp PROPERTIES LANGUAGE HIP)
  set_target_properties(rdma_ep_py PROPERTIES LINKER_LANGUAGE HIP)
  target_compile_options(rdma_ep_py PRIVATE
    $<$<COMPILE_LANGUAGE:HIP>:-fgpu-rdc>)
  target_link_options(rdma_ep_py PRIVATE -fgpu-rdc --hip-link)
  target_include_directories(rdma_ep_py PRIVATE
    ${CMAKE_SOURCE_DIR}/src/endpoints/rdma-ep
    ${CMAKE_SOURCE_DIR}/src/common
    ${HIP_INCLUDE_DIRS}
  )
  target_link_libraries(rdma_ep_py PRIVATE rocm-xio hip::host hip::device)
  add_dependencies(rdma_ep_py rocm-xio)
  install(TARGETS rdma_ep_py LIBRARY DESTINATION xio/rdma_ep)
endif()
