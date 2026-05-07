# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# XIOUtilityTargets.cmake
# Utility targets for linting, formatting, and other tasks

# Clean target
add_custom_target(clean-all
  COMMAND ${CMAKE_COMMAND} -E remove_directory ${CMAKE_BINARY_DIR}/bin
  COMMAND ${CMAKE_COMMAND} -E remove_directory ${CMAKE_BINARY_DIR}/lib
  COMMAND ${CMAKE_COMMAND} -E remove_directory ${CMAKE_BINARY_DIR}
  COMMENT "Cleaning build artifacts"
)

# Clean external headers
add_custom_target(clean-external
  COMMAND ${CMAKE_COMMAND} -E remove_directory
    ${CMAKE_SOURCE_DIR}/src/include/external
  COMMENT "Removing external headers"
)

# Linting targets
find_program(CLANG_FORMAT clang-format PATHS /usr/bin ENV PATH)

if(CLANG_FORMAT)
  # Format check
  add_custom_target(lint-format
    COMMAND ${CLANG_FORMAT} --version
    COMMAND ${CMAKE_COMMAND} -E chdir ${CMAKE_SOURCE_DIR}
      bash -c
      "find . -type f \\( -name '*.cpp' -o -name '*.h' -o -name '*.hpp' -o -name '*.c' -o -name '*.cc' -o -name '*.hip' \\) -not -path './build/*' -not -path './build-*/*' -not -path './.git/*' -not -path './.venv/*' -not -path './src/include/external/*' -not -path './gda-experiments/rocSHMEM/*' -not -name '*-generated.h' -not -name '*-gen.h' -not -name '*.mod.c' -not -name '*.mod' -print0 | xargs -0 ${CLANG_FORMAT} --dry-run --Werror --style=file"
    COMMENT "Checking code formatting with clang-format"
    VERBATIM
  )

  # Format fix
  add_custom_target(format
    COMMAND ${CMAKE_COMMAND} -E chdir ${CMAKE_SOURCE_DIR}
      bash -c
      "find . -type f \\( -name '*.cpp' -o -name '*.h' -o -name '*.hpp' -o -name '*.c' -o -name '*.cc' -o -name '*.hip' \\) -not -path './build/*' -not -path './build-*/*' -not -path './.git/*' -not -path './.venv/*' -not -path './src/include/external/*' -not -path './gda-experiments/rocSHMEM/*' -not -name '*-generated.h' -not -name '*-gen.h' -not -name '*.mod.c' -not -name '*.mod' -print0 | xargs -0 ${CLANG_FORMAT} -i --style=file"
    COMMENT "Formatting code with clang-format"
    VERBATIM
  )
else()
  add_custom_target(lint-format
    COMMAND ${CMAKE_COMMAND} -E echo
      "Error: clang-format not found. Install with:"
    COMMAND ${CMAKE_COMMAND} -E echo
      "  sudo apt-get install clang-format"
    COMMAND ${CMAKE_COMMAND} -E false
  )

  add_custom_target(format
    COMMAND ${CMAKE_COMMAND} -E echo
      "Error: clang-format not found. Install with:"
    COMMAND ${CMAKE_COMMAND} -E echo
      "  sudo apt-get install clang-format"
    COMMAND ${CMAKE_COMMAND} -E false
  )
endif()

# Spell checking
find_program(PYSPELLING pyspelling PATHS ENV PATH)
find_program(ASPELL aspell PATHS /usr/bin ENV PATH)

if(PYSPELLING AND ASPELL)
  add_custom_target(lint-spell
    COMMAND ${PYSPELLING} -c ${CMAKE_SOURCE_DIR}/.spellcheck.yml
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMENT "Checking spelling in markdown files"
  )
else()
  add_custom_target(lint-spell
    COMMAND ${CMAKE_COMMAND} -E echo
      "Error: pyspelling or aspell not found. Install with:"
    COMMAND ${CMAKE_COMMAND} -E echo
      "  pip install pyspelling[all]"
    COMMAND ${CMAKE_COMMAND} -E echo
      "  sudo apt-get install aspell aspell-en"
    COMMAND ${CMAKE_COMMAND} -E false
  )
endif()

# Codespell (code + docs spell-checking, like hipFile)
find_program(CODESPELL codespell PATHS ENV PATH)

if(CODESPELL)
  add_custom_target(lint-codespell
    COMMAND ${CODESPELL} ${CMAKE_SOURCE_DIR}
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMENT "Checking spelling with codespell"
  )
else()
  add_custom_target(lint-codespell
    COMMAND ${CMAKE_COMMAND} -E echo
      "Error: codespell not found. Install with:"
    COMMAND ${CMAKE_COMMAND} -E echo
      "  pip install codespell"
    COMMAND ${CMAKE_COMMAND} -E false
  )
endif()

# Combined linting
add_custom_target(lint-all
  DEPENDS lint-format lint-spell lint-codespell
  COMMENT "Run all linting checks"
)

add_custom_target(lint
  DEPENDS lint-format
  COMMENT "Run linting checks"
)

if(NOT XIO_DOCS_ONLY)

# Assembly dump target
find_program(OBJDUMP llvm-objdump PATHS
  /opt/rocm/lib/llvm/bin ENV PATH)

if(OBJDUMP)
  add_custom_target(asm
    COMMAND ${OBJDUMP} --demangle --disassemble-all
      $<TARGET_FILE:rocm-xio>
    COMMAND ${CMAKE_COMMAND} -E echo
      "Use 'make asm | less -R' to view"
    DEPENDS rocm-xio
    COMMENT "Dumping assembly of library"
  )
else()
  add_custom_target(asm
    COMMAND ${CMAKE_COMMAND} -E echo
      "Error: llvm-objdump not found"
    COMMAND ${CMAKE_COMMAND} -E false
  )
endif()

# List supported GPUs
find_program(CLANGXX clang++ PATHS
  /opt/rocm/llvm/bin ENV PATH)

if(CLANGXX)
  add_custom_target(list
    COMMAND ${CLANGXX}
      --target=amdgcn --print-supported-cpus 2>&1
      | grep -E gfx[1-9]
      | sort -t'x' -k2,2n
      | sed 's/^[ \\t]*/  /'
    COMMENT "Listing supported GPUs"
  )
else()
  add_custom_target(list
    COMMAND ${CMAKE_COMMAND} -E echo
      "Error: clang++ not found in /opt/rocm/llvm/bin"
    COMMAND ${CMAKE_COMMAND} -E false
  )
endif()

endif() # NOT XIO_DOCS_ONLY
