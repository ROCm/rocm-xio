# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# EndpointDiscovery.cmake
# Helper module to discover endpoints and map them to compile defines

# Function to convert endpoint name to define name
function(endpoint_name_to_define ep_name ep_define)
  if(ep_name STREQUAL "test-ep")
    set(${ep_define} "TEST" PARENT_SCOPE)
  elseif(ep_name STREQUAL "nvme-ep")
    set(${ep_define} "NVME" PARENT_SCOPE)
  elseif(ep_name STREQUAL "nvme-simple-ep")
    set(${ep_define} "NVME_SIMPLE" PARENT_SCOPE)
  elseif(ep_name STREQUAL "sdma-ep")
    set(${ep_define} "SDMA" PARENT_SCOPE)
  elseif(ep_name STREQUAL "rdma-ep")
    set(${ep_define} "RDMA" PARENT_SCOPE)
  else()
    # Default: convert nvme-simple-ep -> NVME_SIMPLE_EP, then remove _EP
    string(REPLACE "-ep" "" ep_base "${ep_name}")
    string(REPLACE "-" "_" ep_base "${ep_base}")
    string(TOUPPER "${ep_base}" ep_upper)
    set(${ep_define} "${ep_upper}" PARENT_SCOPE)
  endif()
endfunction()

# Function to discover endpoints
function(discover_endpoints endpoints_dir valid_endpoints_var)
  file(GLOB endpoint_dirs "${endpoints_dir}/*")
  set(endpoints "")
  foreach(dir ${endpoint_dirs})
    if(IS_DIRECTORY ${dir})
      get_filename_component(ep_name ${dir} NAME)
      if(NOT ep_name STREQUAL "common")
        list(APPEND endpoints ${ep_name})
      endif()
    endif()
  endforeach()
  list(SORT endpoints)
  set(${valid_endpoints_var} ${endpoints} PARENT_SCOPE)
endfunction()

# Function to apply endpoint defines to source files
function(apply_endpoint_defines target sources endpoints_dir)
  # Convert sources list to proper variable
  set(src_list ${sources})
  foreach(src ${src_list})
    # Check if source is in an endpoint directory
    string(FIND "${src}" "${endpoints_dir}/" pos)
    if(pos GREATER_EQUAL 0)
      # Extract endpoint name from path
      string(REGEX REPLACE
        "^.*${endpoints_dir}/([^/]+)/.*$" "\\1"
        ep_name "${src}")
      # Skip if it's the common directory
      if(NOT ep_name STREQUAL "common")
        # Get define name
        endpoint_name_to_define(${ep_name} ep_define)
        # Apply compile definition
        set_source_files_properties(${src} PROPERTIES
          COMPILE_DEFINITIONS "XIO_ENDPOINT_${ep_define}")
      endif()
    endif()
  endforeach()
endfunction()
