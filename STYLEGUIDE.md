# rocm-xio Style Guide

## File and Directory Structure

### Naming

* Use hyphens instead of underscores in file and directory names (e.g.,
  `nvme-ep`, `xio-tester`)

## Formatting

* Code must meet the requirements of our `.clang-format` configuration
  (LLVM base style, 80-column limit, 2-space indentation)
* Run formatting checks with:
  `cmake --build build --target lint-format`
* Auto-fix formatting with:
  `cmake --build build --target format`

## Naming Conventions

* Use `snake_case` for variables and functions
* Use `PascalCase` for types and classes
* Use `UPPER_SNAKE_CASE` for macros and constants
* Prefix public API symbols with `xio_` or `Xio`

## Comments and Documentation

* Public headers MUST have Doxygen markup for all public symbols using
  `/** @brief ... */` style
* Document all `@param` and `@return` values
* Use `@note` for caveats and `@see` for related items
* Private headers should have Doxygen markup flagged with `@internal`

## Header Guidelines

* Use `#pragma once` instead of include guards
* Place local headers (quoted) ahead of system headers (brackets), with
  each block in alphabetical order
* Follow [include-what-you-use](https://include-what-you-use.org/)
  guidelines

## Language Features and Idioms

### CMake

* We use CMake 3.21+ (see the root `CMakeLists.txt` for the specific
  version)
* Use modern CMake paradigms and avoid "legacy CMake"

### C/C++ and HIP

* C++17 is required (`CMAKE_CXX_STANDARD 17`)
* GNU extensions are disabled (`CMAKE_CXX_EXTENSIONS OFF`)
* Use modern C++ idioms
* Code should be platform-independent where possible
* HIP device code uses `-fgpu-rdc` for relocatable device code

### Shell scripts

* All shell scripts should be run through
  [ShellCheck](https://www.shellcheck.net/) and report no issues
* Use `#!/usr/bin/env bash` as a platform-independent shebang line
* bash-isms are allowed, within reason

## Error Handling

* Use HIP error checking for all HIP API calls
* Propagate errors to callers rather than silently ignoring them
* The `HIP_CHECK` macro in `xio.h` logs HIP failures to stderr and does
  not change control flow; treat it as a legacy diagnostic aid only.
  Prefer `XIO_HIP_TRY(expr)` or explicit `if ((expr) != hipSuccess) return
  ...;` patterns for new code.

## Testing Conventions

* All new functionality introduced MUST include tests
  * This could include unit tests, system tests, and integration tests
  * These tests MUST be automatable via `ctest`
* Bugfixes MUST include a test that fails before the fix and passes
  after

## Tooling and Enforcement

* **clang-format**: enforced via `.clang-format` and the `lint-format`
  CMake target
* **codespell**: spell-checking via `.codespellrc` and the
  `lint-codespell` CMake target
* **Sphinx + Doxygen**: API documentation via `sphinx-html`
  CMake target
* **CI**: GitHub Actions workflows for build, docs, spelling, and test
  checks
