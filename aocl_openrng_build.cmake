# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.

cmake_policy(SET CMP0010 NEW)

# Integrate OpenRNG via add_subdirectory(): the submodule's vsl.cmake creates
# an OBJECT target (openrngobj) that we consume via $<TARGET_OBJECTS:openrngobj>.

set(OPENRNG_BUILD_LOG_FILE_PATH "${CMAKE_BINARY_DIR}/aocl_openrng_build.log")
file(WRITE "${OPENRNG_BUILD_LOG_FILE_PATH}" "=========================OpenRNG Build Logs=========================.\n")

set(OPENRNG_PATH "" CACHE STRING "Local path of the OpenRNG source code")

# Source resolution: OPENRNG_PATH > submodule > fatal.
if(OPENRNG_PATH)
    string(REPLACE "\\" "/" OPENRNG_SOURCE_DIR "${OPENRNG_PATH}")
    message(STATUS "Using OpenRNG source code from ${OPENRNG_SOURCE_DIR}.")
    file(APPEND "${OPENRNG_BUILD_LOG_FILE_PATH}" "Using OpenRNG source code from ${OPENRNG_PATH}.\n")
elseif(USE_SOURCES_FROM_SUBMODULES AND EXISTS "${SUBMODULES_BASE_PATH}/openrng/CMakeLists.txt")
    set(OPENRNG_SOURCE_DIR "${SUBMODULES_BASE_PATH}/openrng")
    message(STATUS "Using OpenRNG from submodules: ${OPENRNG_SOURCE_DIR}.")
    file(APPEND "${OPENRNG_BUILD_LOG_FILE_PATH}" "Using OpenRNG from submodules: ${OPENRNG_SOURCE_DIR}.\n")
else()
    message(FATAL_ERROR
        "OpenRNG source not found. Please either:\n"
        "  - Set -DOPENRNG_PATH=<path-to-openrng-source>, or\n"
        "  - Add OpenRNG as a git submodule at submodules/openrng.")
endif()

file(APPEND "${OPENRNG_BUILD_LOG_FILE_PATH}" "OPENRNG_SOURCE_DIR: ${OPENRNG_SOURCE_DIR}.\n")

# Forward OpenRNG options (CACHE without FORCE: parent -D values win).
set(BUILD_TESTING    OFF CACHE BOOL "Build OpenRNG unit tests")
set(BUILD_BENCH      OFF CACHE BOOL "Build OpenRNG benchmarks")
set(BUILD_DOCS       OFF CACHE BOOL "Build OpenRNG documentation")
set(AOCL_OPENRNG_BUILD ON  CACHE BOOL "Build AOCL-based OpenRNG")

# OpenRNG's x86_64.cmake needs AOCL_ROOT (include/amdlibm.h, lib/libalm.*).
# Default to the in-tree LibM install; user -DAOCL_ROOT=... is preserved.
set(AOCL_ROOT "${CMAKE_BINARY_DIR}/aocl-libm/install_package"
    CACHE PATH "AOCL install root containing include/amdlibm.h and lib/libalm.{lib,so}")

# OpenRNG links against bare name `alm`, but our in-tree LibM ships as
# `libalm.{lib,so,a}`. Pre-declare an IMPORTED `alm` target before
# add_subdirectory() so any target that links `alm` resolves to our in-tree
# AOCL-LibM (built earlier at configure time into ${AOCL_ROOT}/lib).
if(NOT TARGET alm)
    if(WIN32)
        set(_alm_imp "${AOCL_ROOT}/lib/libalm.lib")
        set(_alm_dll "${AOCL_ROOT}/lib/libalm.dll")
        if(EXISTS "${_alm_imp}")
            if(EXISTS "${_alm_dll}")
                add_library(alm SHARED IMPORTED GLOBAL)
                set_target_properties(alm PROPERTIES
                    IMPORTED_LOCATION             "${_alm_dll}"
                    IMPORTED_IMPLIB               "${_alm_imp}"
                    INTERFACE_INCLUDE_DIRECTORIES "${AOCL_ROOT}/include")
            else()
                add_library(alm STATIC IMPORTED GLOBAL)
                set_target_properties(alm PROPERTIES
                    IMPORTED_LOCATION             "${_alm_imp}"
                    INTERFACE_INCLUDE_DIRECTORIES "${AOCL_ROOT}/include")
            endif()
            message(STATUS "OpenRNG: declared IMPORTED target `alm` -> ${_alm_imp}")
        endif()
    else()
        set(_alm_so  "${AOCL_ROOT}/lib/libalm.so")
        set(_alm_a   "${AOCL_ROOT}/lib/libalm.a")
        if(EXISTS "${_alm_so}")
            add_library(alm SHARED IMPORTED GLOBAL)
            set_target_properties(alm PROPERTIES
                IMPORTED_LOCATION             "${_alm_so}"
                INTERFACE_INCLUDE_DIRECTORIES "${AOCL_ROOT}/include")
            message(STATUS "OpenRNG: declared IMPORTED target `alm` -> ${_alm_so}")
        elseif(EXISTS "${_alm_a}")
            add_library(alm STATIC IMPORTED GLOBAL)
            set_target_properties(alm PROPERTIES
                IMPORTED_LOCATION             "${_alm_a}"
                INTERFACE_INCLUDE_DIRECTORIES "${AOCL_ROOT}/include")
            message(STATUS "OpenRNG: declared IMPORTED target `alm` -> ${_alm_a}")
        endif()
    endif()
endif()

# add_subdirectory() defines: openrngobj (OBJECT), openrng, refng,
# test_linking_with_c_compiler, library_version, and the vsl ALIAS.
message(STATUS "Adding OpenRNG subdirectory: ${OPENRNG_SOURCE_DIR}")
add_subdirectory(${OPENRNG_SOURCE_DIR} openrng)
message(STATUS "OpenRNG subdirectory configured successfully.")

# Upstream OpenRNG adds `/NODEFAULTLIB` (or `-nodefaultlibs`) to the SHARED
# `openrng` target to drop the C++ runtime. On MSVC/ClangCL that strips ALL
# default libs (including the C runtime), causing undefined `round`/`free`/
# `exp`/`tan`/`pow`. Strip those flags on Windows so the C runtime stays in.
if(WIN32 AND TARGET openrng)
    get_target_property(_orng_link_opts openrng LINK_OPTIONS)
    if(_orng_link_opts)
        list(REMOVE_ITEM _orng_link_opts "/NODEFAULTLIB" "-nodefaultlibs")
        set_target_properties(openrng PROPERTIES LINK_OPTIONS "${_orng_link_opts}")
    endif()
endif()

# Build the standalone openrng library by default (installs to
# build/openrng/install_package via the patched cmake_install.cmake from the
# top-level CMakeLists.txt). The remaining targets are upstream test/bench
# helpers we don't need; keep them out of the umbrella ALL build.
foreach(_orng_tgt refng test_linking_with_c_compiler library_version)
    if(TARGET ${_orng_tgt})
        set_target_properties(${_orng_tgt} PROPERTIES EXCLUDE_FROM_ALL TRUE)
    endif()
endforeach()
file(APPEND "${OPENRNG_BUILD_LOG_FILE_PATH}" "OpenRNG add_subdirectory completed.\n")

list(APPEND OBJECT_FILES $<TARGET_OBJECTS:openrngobj>)

# Linux: aggregated shared lib must link libm explicitly.
if(NOT WIN32)
    list(APPEND DEPENDENT_LIBS m)
endif()

# OpenRNG calls amd_* (LibM) from box_muller_2.cpp. If LibM isn't built
# in-tree, link the prebuilt libalm from AOCL_ROOT.
if(AOCL_OPENRNG_BUILD AND NOT ENABLE_AOCL_LIBM)
    if(WIN32)
        set(_alm_candidate "${AOCL_ROOT}/lib/libalm.lib")
    else()
        set(_alm_candidate "${AOCL_ROOT}/lib/libalm.so")
        if(NOT EXISTS "${_alm_candidate}")
            set(_alm_candidate "${AOCL_ROOT}/lib/libalm.a")
        endif()
    endif()
    if(EXISTS "${_alm_candidate}")
        list(APPEND DEPENDENT_LIBS "${_alm_candidate}")
        message(STATUS "OpenRNG: linking prebuilt AOCL-LibM ${_alm_candidate} for amd_* symbols.")
    else()
        message(WARNING "OpenRNG: AOCL_OPENRNG_BUILD=ON but no libalm found under ${AOCL_ROOT}/lib; aocl link will fail with undefined amd_* symbols.")
    endif()
endif()

# Propagate openrngobj's PUBLIC interface (includes/defs) onto the aggregated
# aocl target. DEFER fires after add_library(${PROJECT_NAME}...) in the parent.
cmake_language(DEFER CALL target_link_libraries ${PROJECT_NAME} PUBLIC openrngobj)

# OpenRNG headers have no __declspec(dllexport); list the public C API in a
# DEF file so the symbols are exported from aocl.dll.
if(WIN32 AND BUILD_SHARED_LIBS)
    set(_rng_def_content "EXPORTS\n")
    set(_rng_header "${OPENRNG_SOURCE_DIR}/include/openrng.h")
    file(STRINGS "${_rng_header}" _rng_lines REGEX "^int [a-zA-Z][a-zA-Z0-9_]*[ \t]*\\(")
    foreach(_line ${_rng_lines})
        if(_line MATCHES "^int ([a-zA-Z0-9_]+)[ \t]*[(]")
            string(APPEND _rng_def_content "  ${CMAKE_MATCH_1}\n")
        endif()
    endforeach()
    set(_rng_def_file "${CMAKE_BINARY_DIR}/aocl_openrng_exports.def")
    file(WRITE "${_rng_def_file}" "${_rng_def_content}")
    list(APPEND DEF_FILES "${_rng_def_file}")
    message(STATUS "OpenRNG: Generated DEF file with OpenRNG public API at ${_rng_def_file}")
endif()

message(STATUS "OpenRNG integration configured (target-based via openrngobj OBJECT target).")

# Mirror openrng.h into the unified install_package/include (same pattern as
# the other libs). Source the header straight from the submodule so the rule
# works on Linux too (where there's no install(CODE) header-redirect patch).
install(FILES "${OPENRNG_SOURCE_DIR}/include/openrng.h" DESTINATION include)
