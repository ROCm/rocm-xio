file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/VERSION" ANVIL_VERSION_CONTENT)
if(ANVIL_VERSION_CONTENT MATCHES "^([0-9]+)\\.([0-9]+)\\.([0-9]+)")
    set(ANVIL_MAJOR "${CMAKE_MATCH_1}")
    set(ANVIL_MINOR "${CMAKE_MATCH_2}")
    set(ANVIL_PATCH "${CMAKE_MATCH_3}")
else()
    message(FATAL_ERROR "VERSION file must be in the format MAJOR.MINOR.PATCH")
endif()

set(ANVIL_SOVERSION ${ANVIL_MAJOR})
set(ANVIL_VERSION "${ANVIL_MAJOR}.${ANVIL_MINOR}.${ANVIL_PATCH}")

cmake_minimum_required(VERSION 3.25)
project(anvil LANGUAGES CXX)

set(CMAKE_PREFIX_PATH "/opt/rocm;${CMAKE_PREFIX_PATH}")
find_package(hip REQUIRED)
find_package(hsa-runtime64 1.0 REQUIRED)
find_package(hsakmt REQUIRED)

set(CMAKE_HIP_STANDARD 17)
set(CMAKE_HIP_FLAGS "${CMAKE_HIP_FLAGS} -Wall -Wextra")

add_library(anvil src/anvil.cpp)
target_include_directories(anvil
    SYSTEM PRIVATE
    ${hip_INCLUDE_DIRS})

target_link_libraries(anvil PRIVATE hip::device hsa-runtime64::hsa-runtime64 hsakmt::hsakmt)
set_target_properties(anvil PROPERTIES LINKER_LANGUAGE CXX POSITION_INDEPENDENT_CODE 1 VERSION ${ANVIL_VERSION} SOVERSION ${ANVIL_SOVERSION})

if("${INSTALL_PREFIX}" STREQUAL "")
    set(INSTALL_PREFIX "./")
endif()

install(
    TARGETS anvil
    FILE_SET HEADERS DESTINATION ${INSTALL_PREFIX}/include
    LIBRARY DESTINATION ${INSTALL_PREFIX}/lib
)

target_include_directories(anvil PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${ROCM_PATH}/opt/rocm/include
     ${ROCM_PATH}/opt/rocm/include/hsa

)