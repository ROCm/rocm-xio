# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Auto-detect GPUs at configure time and generate a
# CTest resource specification file.  Falls back to the
# static cmake/ctest-resources.json when no GPUs are
# found or rocm_agent_enumerator is unavailable.
#
# Usage (from top-level CMakeLists.txt):
#   include(XIODetectGPUs)
#
# After this module runs, XIO_GPU_COUNT is set and
# ${CMAKE_BINARY_DIR}/ctest-resources.json is written.

find_program(ROCM_AGENT_ENUM rocm_agent_enumerator
  HINTS /opt/rocm/bin ENV ROCM_PATH)

set(XIO_GPU_COUNT 0)

if(ROCM_AGENT_ENUM)
  execute_process(
    COMMAND ${ROCM_AGENT_ENUM}
    OUTPUT_VARIABLE _agents
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
    RESULT_VARIABLE _agent_rc)

  if(_agent_rc EQUAL 0 AND _agents)
    string(REPLACE "\n" ";" _agent_list "${_agents}")
    foreach(_agent IN LISTS _agent_list)
      string(STRIP "${_agent}" _agent)
      if(NOT _agent STREQUAL "gfx000"
         AND NOT _agent STREQUAL "")
        math(EXPR XIO_GPU_COUNT
          "${XIO_GPU_COUNT} + 1")
      endif()
    endforeach()
  endif()
endif()

if(XIO_GPU_COUNT EQUAL 0)
  set(XIO_GPU_COUNT 1)
  message(STATUS
    "XIODetectGPUs: no GPUs detected, "
    "defaulting to 1")
else()
  message(STATUS
    "XIODetectGPUs: detected ${XIO_GPU_COUNT} GPU(s)")
endif()

# Build the JSON gpu array
set(_gpu_entries "")
math(EXPR _last "${XIO_GPU_COUNT} - 1")
foreach(_idx RANGE 0 ${_last})
  if(_gpu_entries)
    string(APPEND _gpu_entries ",\n")
  endif()
  string(APPEND _gpu_entries
    "        { \"id\": \"${_idx}\", \"slots\": 1 }")
endforeach()

file(WRITE
  "${CMAKE_BINARY_DIR}/ctest-resources.json"
  "{\n"
  "  \"version\": {\n"
  "    \"major\": 1,\n"
  "    \"minor\": 0\n"
  "  },\n"
  "  \"local\": [\n"
  "    {\n"
  "      \"gpus\": [\n"
  "${_gpu_entries}\n"
  "      ]\n"
  "    }\n"
  "  ]\n"
  "}\n")
