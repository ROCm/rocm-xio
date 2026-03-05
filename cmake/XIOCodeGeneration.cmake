# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# CodeGeneration.cmake
# Helper module for code generation steps

function(setup_code_generation)
  cmake_parse_arguments(GEN "" 
    "ENDPOINTS_DIR;INCLUDE_DIR;EXTERNAL_HEADERS_DIR;RDMA_HEADERS_DIR;NVME_HEADERS_DIR;GENERATED_REGISTRY;GENERATED_INCLUDES;NVME_EP_GENERATED"
    "RDMA_VENDOR_HEADERS" ${ARGN})

  # Discover endpoints for generation
  discover_endpoints(${GEN_ENDPOINTS_DIR} VALID_ENDPOINTS)

  # Endpoint registry generation
  set(GEN_SCRIPT
    ${CMAKE_SOURCE_DIR}/scripts/build/generate-endpoint-files.sh)
  set(GEN_SENTINEL ${CMAKE_BINARY_DIR}/.endpoint-files-generated)

  add_custom_command(
    OUTPUT ${GEN_GENERATED_REGISTRY} ${GEN_GENERATED_INCLUDES}
    COMMAND ${GEN_SCRIPT} ${GEN_ENDPOINTS_DIR}
      ${GEN_GENERATED_REGISTRY} ${GEN_GENERATED_INCLUDES}
    COMMAND ${CMAKE_COMMAND} -E touch ${GEN_SENTINEL}
    DEPENDS ${GEN_SCRIPT}
    COMMENT "Generating endpoint files from: ${VALID_ENDPOINTS}"
  )

  add_custom_target(endpoint-registry-generated
    DEPENDS ${GEN_GENERATED_REGISTRY} ${GEN_GENERATED_INCLUDES})

  # Format generated files if clang-format is available
  find_program(CLANG_FORMAT clang-format PATHS /usr/bin ENV PATH)
  if(CLANG_FORMAT)
    # Add formatting as a post-build step
    add_custom_command(
      TARGET endpoint-registry-generated POST_BUILD
      COMMAND ${CLANG_FORMAT} -i --style=file
        ${GEN_GENERATED_REGISTRY}
      COMMENT "Formatting generated endpoint registry"
    )
  endif()

  # NVMe header fetching
  set(NVME_FETCH_SCRIPT
    ${CMAKE_SOURCE_DIR}/scripts/build/fetch-nvme-headers.sh)
  set(NVME_KERNEL_HEADERS
    ${GEN_NVME_HEADERS_DIR}/linux-nvme.h
    ${GEN_NVME_HEADERS_DIR}/linux-nvme_ioctl.h)

  add_custom_command(
    OUTPUT ${NVME_KERNEL_HEADERS}
    COMMAND ${NVME_FETCH_SCRIPT} ${GEN_NVME_HEADERS_DIR}
    DEPENDS ${NVME_FETCH_SCRIPT}
    COMMENT "Fetching NVMe headers from Linux kernel repository"
  )

  add_custom_target(fetch-nvme-headers
    DEPENDS ${NVME_KERNEL_HEADERS}
    COMMENT "Download NVMe headers")

  # NVMe defines extraction
  set(NVME_EXTRACT_SCRIPT
    ${CMAKE_SOURCE_DIR}/scripts/build/extract-nvme-defines.sh)

  add_custom_command(
    OUTPUT ${GEN_NVME_EP_GENERATED}
    COMMAND ${NVME_EXTRACT_SCRIPT}
      ${GEN_NVME_HEADERS_DIR}/linux-nvme.h
      ${GEN_NVME_EP_GENERATED}
    DEPENDS ${NVME_EXTRACT_SCRIPT}
      ${GEN_NVME_HEADERS_DIR}/linux-nvme.h
    COMMENT "Extracting NVMe defines from kernel headers"
  )

  add_custom_target(nvme-ep-generated
    DEPENDS ${GEN_NVME_EP_GENERATED}
    COMMENT "Generate NVMe endpoint defines")

  # Make nvme-ep-generated depend on fetch-nvme-headers
  add_dependencies(nvme-ep-generated fetch-nvme-headers)

  # Format NVMe generated file if clang-format is available
  find_program(CLANG_FORMAT clang-format PATHS /usr/bin ENV PATH)
  if(CLANG_FORMAT)
    add_custom_command(
      TARGET nvme-ep-generated POST_BUILD
      COMMAND ${CLANG_FORMAT} -i --style=file
        ${GEN_NVME_EP_GENERATED}
      COMMENT "Formatting generated NVMe defines"
    )
  endif()

  # RDMA header fetching
  set(RDMA_FETCH_SCRIPT
    ${CMAKE_SOURCE_DIR}/scripts/build/fetch-rdma-headers.sh)
  set(RDMA_GEN_SCRIPT
    ${CMAKE_SOURCE_DIR}/scripts/build/generate-rdma-vendor-headers.sh)

  # RDMA headers that need to be fetched
  set(RDMA_HEADERS
    ${GEN_RDMA_HEADERS_DIR}/ib_user_verbs.h
    ${GEN_RDMA_HEADERS_DIR}/mlx/mlx5dv.h
    ${GEN_RDMA_HEADERS_DIR}/bnxt/bnxt_re_abi.h
    ${GEN_RDMA_HEADERS_DIR}/ionic/ionic.h)

  add_custom_command(
    OUTPUT ${RDMA_HEADERS}
    COMMAND ${RDMA_FETCH_SCRIPT} ${GEN_RDMA_HEADERS_DIR}
    DEPENDS ${RDMA_FETCH_SCRIPT}
    COMMENT "Fetching RDMA provider headers from rdma-core repository"
  )

  add_custom_target(fetch-rdma-headers
    DEPENDS ${RDMA_HEADERS}
    COMMENT "Download RDMA headers")

  # RDMA vendor header generation
  add_custom_command(
    OUTPUT ${GEN_RDMA_VENDOR_HEADERS}
    COMMAND ${RDMA_GEN_SCRIPT}
      ${GEN_RDMA_HEADERS_DIR}
      ${GEN_ENDPOINTS_DIR}/rdma-ep
    DEPENDS ${RDMA_GEN_SCRIPT} ${RDMA_HEADERS}
    COMMENT "Generating vendor-specific RDMA headers"
  )

  add_custom_target(rdma-vendor-headers-generated
    DEPENDS ${GEN_RDMA_VENDOR_HEADERS}
    COMMENT "Generate RDMA vendor headers")

  # Combined external headers target
  add_custom_target(fetch-external-headers
    DEPENDS fetch-nvme-headers fetch-rdma-headers
    COMMENT "Fetch all external headers")

endfunction()
