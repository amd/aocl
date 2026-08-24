# Copyright (C) 2025-2026, Advanced Micro Devices, Inc. All rights reserved.

# Set the minimum required version of CMake
cmake_minimum_required(VERSION 3.26.0)

# Set the project name
if(NOT DEFINED AOCL_SINGLE_LIBRARY_NAME)
    set(AOCL_SINGLE_LIBRARY_NAME "aocl")
endif()
project(${AOCL_SINGLE_LIBRARY_NAME} LANGUAGES C CXX)

# Set the build type first (default Release) so the configuration types below
# can mirror it.
if(NOT DEFINED CMAKE_BUILD_TYPE OR NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE "Release" CACHE STRING "Build type" FORCE)
endif()

# Multi-config generators (e.g. Visual Studio) select the configuration from
# CMAKE_CONFIGURATION_TYPES, not CMAKE_BUILD_TYPE, and CMake pre-seeds it with
# the full "Debug;Release;MinSizeRel;RelWithDebInfo" list (first entry Debug
# would become the default); mirror CMAKE_BUILD_TYPE instead.
if(NOT DEFINED CMAKE_CONFIGURATION_TYPES OR CMAKE_CONFIGURATION_TYPES MATCHES "Debug;")
    set(CMAKE_CONFIGURATION_TYPES "${CMAKE_BUILD_TYPE}" CACHE STRING "Build configurations" FORCE)
endif()

# Set the installation prefix
if(NOT DEFINED CMAKE_INSTALL_PREFIX)
    set(CMAKE_INSTALL_PREFIX "${CMAKE_BINARY_DIR}" CACHE PATH "Installation directory" FORCE)
elseif(WIN32 AND (CMAKE_INSTALL_PREFIX STREQUAL "C:/Program Files (x86)/${PROJECT_NAME}"))
    set(CMAKE_INSTALL_PREFIX "${CMAKE_BINARY_DIR}" CACHE PATH "Installation directory" FORCE)
elseif((NOT WIN32) AND (CMAKE_INSTALL_PREFIX STREQUAL "/usr/local"))
    set(CMAKE_INSTALL_PREFIX "${CMAKE_BINARY_DIR}" CACHE PATH "Installation directory" FORCE)
endif()

# Print the build configurations
message("CMAKE_CONFIGURATION_TYPES: ${CMAKE_CONFIGURATION_TYPES}")
message("CMAKE_BUILD_TYPE: ${CMAKE_BUILD_TYPE}")
message("CMAKE_INSTALL_PREFIX: ${CMAKE_INSTALL_PREFIX}")

# Configure parallel build cores
# User can specify BUILD_CORES, otherwise defaults to 50% of available CPU cores
# to use with the -j option for parallel builds, balancing performance and memory usage.
set(BUILD_CORES "" CACHE STRING "Number of cores for parallel build (empty for auto: 50% of available cores)")

if(UNIX)
    # Detect total number of available processors
    execute_process(COMMAND nproc
                    OUTPUT_VARIABLE NUM_CORES
                    OUTPUT_STRIP_TRAILING_WHITESPACE)
    
    # Use user-specified cores if provided, otherwise calculate 50% of available cores
    if(BUILD_CORES STREQUAL "")
        # Calculate 50% of cores (round up to at least 1)
        math(EXPR BUILD_CORES "(${NUM_CORES} + 1) / 2")  # +1 ensures rounding up
        message(STATUS "Using ${BUILD_CORES} cores for parallel build (auto: 50% of ${NUM_CORES} available cores)")
    else()
        message(STATUS "Using ${BUILD_CORES} cores for parallel build (user-specified)")
    endif()
    
    set(parallel "-j${BUILD_CORES}")
else()
    # Windows: use BUILD_CORES if specified, otherwise use all cores
    if(NOT BUILD_CORES STREQUAL "")
        set(parallel "-j${BUILD_CORES}")
        message(STATUS "Using ${BUILD_CORES} cores for parallel build (user-specified)")
    else()
        set(parallel "-j")
        message(STATUS "Using all available cores for parallel build")
    endif()
endif()

# Define build options
option(BUILD_SHARED_LIBS "Build using shared libraries" ON)
option(ENABLE_AOCL_UTILS "Check if we need to include AOCL-Utils into AOCL unified library" ON)
option(ENABLE_AOCL_BLAS "Check if we need to include AOCL-BLAS into AOCL unified library" OFF)
option(ENABLE_AOCL_LAPACK "Check if we need to include AOCL-LAPACK into AOCL unified library" OFF)
option(ENABLE_AOCL_SPARSE "Check if we need to include AOCL-Sparse into AOCL unified library" OFF)
option(ENABLE_AOCL_CRYPTO "Check if we need to include AOCL-Crypto into AOCL unified library" OFF)
option(ENABLE_AOCL_LIBM "Check if we need to include AOCL-LibM into AOCL unified library" OFF)
option(ENABLE_AOCL_COMPRESSION "Check if we need to include AOCL-Compression into AOCL single library" OFF)
option(ENABLE_AOCL_DA "Check if we need to include AOCL-DA into AOCL unified library" OFF)
option(ENABLE_AOCL_LIBMEM "Check if we need to include AOCL-LibMem into AOCL unified library" OFF)
option(ENABLE_AOCL_OPENRNG "Check if we need to include OpenRNG into AOCL unified library" OFF)
option(ENABLE_AOCL_FFTZ "Check if we need to include AOCL-FFTZ into AOCL unified library" OFF)
option(ENABLE_AOCL_DLP "Check if we need to include AOCL-DLP into AOCL unified library" OFF)
option(ENABLE_MULTITHREADING "Check if we need to enable multithreading" OFF)
option(ENABLE_CBLAS "Check if we need to enable AOCL-BLAS CBLAS interface" ON)
option(ENABLE_AMD_FLAGS "Check if we need to enable amd flags for AOCL-LAPACK library build" OFF)
option(ENABLE_AMD_AOCC_FLAGS "Check if we need to enable amd aocc flags for AOCL-LAPACK library build" OFF)
option(ENABLE_TRSM_PREINVERSION "Check if we need to enable trsm preinversion" ON)
option(ENABLE_ILP64 "Check if we need to enable ILP64" OFF)
option(ENABLE_BLAS_EXT_GEMMT "Check if we need to enable blas external gemmt for AOCL-LAPACK library build" ON)
option(ENABLE_AOCL_LAPACK_BLAS_COUPLING "Check if we need to tightly coupled with AOCL-BLAS library for AOCL-LAPACK library build" OFF)
option(ENABLE_TESTS "Enable building and running library functionality tests" OFF)
# Component source acquisition: ON (default) uses the sources under
# submodules/ (see AOCL_LIB_SRC); OFF makes each component fall back to cloning
# from its <COMP>_GIT_REPOSITORY at <COMP>_GIT_TAG. A per-component <COMP>_PATH
# always takes precedence over both (see aocl_tb_declare_source).
option(USE_SOURCES_FROM_SUBMODULES "Use component sources under submodules/ (else clone via git)" ON)

# Centralized AOCL build-options layer: global single-select knobs (linkage,
# threading runtime, integer size, architecture) + per-component overrides,
# with validation and a backward-compatible bridge to the legacy variables.
# Included here -- after the legacy option() block, before BUILD_STATIC_LIBS /
# ENABLE_ILP64 / AMD_CONFIG are consumed -- so explicit AOCL_* options can drive
# the legacy variables while "auto" defaults leave existing presets untouched.
include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/aocl_options.cmake)

# AOCL-LibMem is a UNIX / x86-only component (IFUNC-based runtime CPU dispatch);
# it does not build on Windows. Skip it there with a warning so a Windows
# configure that requests it does not fail later with a duplicate-output build
# error instead of a clear message.
if(WIN32 AND ENABLE_AOCL_LIBMEM)
    message(WARNING "AOCL-LibMem is not supported on Windows (UNIX/x86 only); "
                    "disabling ENABLE_AOCL_LIBMEM for this build.")
    set(ENABLE_AOCL_LIBMEM OFF CACHE BOOL "AOCL-LibMem (UNIX/x86 only)" FORCE)
endif()

# Set build static libs option based on shared libs option
if(BUILD_SHARED_LIBS)
    set(BUILD_STATIC_LIBS OFF)
else()
    set(BUILD_STATIC_LIBS ON)
endif()

# Set BLAS integer size based on ILP64 option
if(ENABLE_ILP64)
    set(BLAS_INT_SIZE "64")
else()
    set(BLAS_INT_SIZE "32")
endif()

# Set utils library names based on build type and build option
string(TOLOWER "${CMAKE_BUILD_TYPE}" build_type_lower)
if(BUILD_STATIC_LIBS)
    if(build_type_lower STREQUAL "debug")
        set(Linux_Utils_Lib_Name "libaoclutils-dbg.a")
        set(Windows_Utils_Lib_Name "libaoclutils_static-dbg.lib")
    else()
        set(Linux_Utils_Lib_Name "libaoclutils.a")
        set(Windows_Utils_Lib_Name "libaoclutils_static.lib")
    endif()
else()
    if(build_type_lower STREQUAL "debug")
        set(Linux_Utils_Lib_Name "libaoclutils-dbg.so")
        set(Windows_Utils_Lib_Name "libaoclutils-dbg.lib")
    else()
        set(Linux_Utils_Lib_Name "libaoclutils.so")
        set(Windows_Utils_Lib_Name "libaoclutils.lib")
    endif()
endif()

# Set AMD ISA (Instruction Set Architecture) for optimized builds
set(AMD_CONFIG "" CACHE STRING "AMD ISA target (empty, zen, zen2, zen3, zen4, zen5, amdzen)")
set_property(CACHE AMD_CONFIG PROPERTY STRINGS "" "zen" "zen2" "zen3" "zen4" "zen5" "amdzen")

# Validate AMD_CONFIG value if provided
if(AMD_CONFIG AND NOT AMD_CONFIG MATCHES "^(zen|zen2|zen3|zen4|zen5|amdzen)$")
    message(FATAL_ERROR "Invalid AMD_CONFIG value: ${AMD_CONFIG}. Supported values: zen, zen2, zen3, zen4, zen5, amdzen")
endif()

# Set AOCL-BLAS configuration family based on AMD_CONFIG
if(AMD_CONFIG)
    set(BLIS_CONFIG_FAMILY "${AMD_CONFIG}" CACHE STRING "Blis configuration family" FORCE)
    message(STATUS "BLIS_CONFIG_FAMILY set to: ${AMD_CONFIG}")
else()
    set(BLIS_CONFIG_FAMILY "amdzen" CACHE STRING "Blis configuration family")
    message(STATUS "BLIS_CONFIG_FAMILY set to default: amdzen")
endif()

# Set AOCL-LAPACK ISA configuration based on AMD_CONFIG
if(AMD_CONFIG STREQUAL "zen" OR AMD_CONFIG STREQUAL "zen2" OR AMD_CONFIG STREQUAL "zen3")
    set(LF_ISA_CONFIG "AVX2-STRICT" CACHE STRING "LibFlame ISA configuration" FORCE)
    message(STATUS "LF_ISA_CONFIG set to: AVX2-STRICT (based on AMD_CONFIG=${AMD_CONFIG})")
elseif(AMD_CONFIG STREQUAL "zen4" OR AMD_CONFIG STREQUAL "zen5")
    set(LF_ISA_CONFIG "AVX512-STRICT" CACHE STRING "LibFlame ISA configuration" FORCE)
    message(STATUS "LF_ISA_CONFIG set to: AVX512-STRICT (based on AMD_CONFIG=${AMD_CONFIG})")
else()
    set(LF_ISA_CONFIG "AVX2" CACHE STRING "LibFlame ISA configuration")
    message(STATUS "LF_ISA_CONFIG set to default: AVX2")
endif()

# Set AOCL-LibM static dispatch option based on AMD_CONFIG
if(AMD_CONFIG STREQUAL "zen")
    set(ALM_STATIC_DISPATCH_OPTION "AVX2" CACHE STRING "LibM ISA configuration" FORCE)
    message(STATUS "ALM_STATIC_DISPATCH_OPTION set to: AVX2 (based on AMD_CONFIG=${AMD_CONFIG})")
elseif(AMD_CONFIG STREQUAL "zen2" OR AMD_CONFIG STREQUAL "zen3" OR AMD_CONFIG STREQUAL "zen4" OR AMD_CONFIG STREQUAL "zen5")
    string(TOUPPER "${AMD_CONFIG}" ALM_DISPATCH_UPPER)
    set(ALM_STATIC_DISPATCH_OPTION "${ALM_DISPATCH_UPPER}" CACHE STRING "LibM static dispatch option" FORCE)
    message(STATUS "ALM_STATIC_DISPATCH_OPTION set to: ${ALM_DISPATCH_UPPER})")
else()
    set(ALM_STATIC_DISPATCH_OPTION "" CACHE STRING "LibM static dispatch option")
    message(STATUS "ALM_STATIC_DISPATCH_OPTION set to default: (dynamic dispatch)")
endif()

# Set AOCL-DA ISA configuration based on AMD_CONFIG
if(AMD_CONFIG STREQUAL "zen" OR AMD_CONFIG STREQUAL "zen2")
    set(DA_ISA_CONFIG "znver2" CACHE STRING "AOCL-DA ISA config" FORCE)
    message(STATUS "AOCL-DA DA_ISA_CONFIG set to: ${DA_ISA_CONFIG} (based on AMD_CONFIG=${AMD_CONFIG})")
elseif(AMD_CONFIG STREQUAL "zen3")
    set(DA_ISA_CONFIG "znver3" CACHE STRING "AOCL-DA ISA config" FORCE)
    message(STATUS "AOCL-DA DA_ISA_CONFIG set to: ${DA_ISA_CONFIG} (based on AMD_CONFIG=${AMD_CONFIG})")
elseif(AMD_CONFIG STREQUAL "zen4")
    set(DA_ISA_CONFIG "znver4" CACHE STRING "AOCL-DA ISA config" FORCE)
    message(STATUS "AOCL-DA DA_ISA_CONFIG set to: ${DA_ISA_CONFIG} (based on AMD_CONFIG=${AMD_CONFIG})")
elseif(AMD_CONFIG STREQUAL "zen5")
    set(DA_ISA_CONFIG "znver5" CACHE STRING "AOCL-DA ISA config" FORCE)
    message(STATUS "AOCL-DA DA_ISA_CONFIG set to: ${DA_ISA_CONFIG} (based on AMD_CONFIG=${AMD_CONFIG})")
elseif(AMD_CONFIG STREQUAL "amdzen")
    set(DA_ISA_CONFIG "dynamic" CACHE STRING "AOCL-DA ISA config" FORCE)
    message(STATUS "AOCL-DA DA_ISA_CONFIG set to: ${DA_ISA_CONFIG} (based on AMD_CONFIG=${AMD_CONFIG})")
else()
    set(DA_ISA_CONFIG "dynamic" CACHE STRING "AOCL-DA ISA config")
    message(STATUS "AOCL-DA DA_ISA_CONFIG set to default: dynamic")
endif()

# Set AOCL-Sparse ISA configuration based on AMD_CONFIG
if(AMD_CONFIG STREQUAL "zen" OR AMD_CONFIG STREQUAL "zen2" OR AMD_CONFIG STREQUAL "zen3")
    set(SPARSE_ISA_CONFIG OFF CACHE BOOL "Enable AVX512 support for AOCL-Sparse" FORCE)
    message(STATUS "AOCL-Sparse SPARSE_ISA_CONFIG set to: ${SPARSE_ISA_CONFIG} (based on AMD_CONFIG=${AMD_CONFIG})")
elseif(AMD_CONFIG STREQUAL "zen4" OR AMD_CONFIG STREQUAL "zen5" OR AMD_CONFIG STREQUAL "amdzen")
    set(SPARSE_ISA_CONFIG ON CACHE BOOL "Enable AVX512 support for AOCL-Sparse" FORCE)
    message(STATUS "AOCL-Sparse SPARSE_ISA_CONFIG set to: ${SPARSE_ISA_CONFIG} (based on AMD_CONFIG=${AMD_CONFIG})")
else()
    set(SPARSE_ISA_CONFIG ON CACHE BOOL "Enable AVX512 support for AOCL-Sparse")
    message(STATUS "AOCL-Sparse SPARSE_ISA_CONFIG set to default: ON")
endif()

set(ENABLE_ADDON "" CACHE STRING "Configure with specific addons using a ';'-separated list")

# Set platform-specific options
if(WIN32)
    set (suff "obj")
    set(OpenMP_libomp_LIBRARY "C:/Program Files/LLVM/lib/libomp.lib" CACHE STRING "openmp library path")
    set(OPENSSL_INSTALL_DIR "C:/Program Files/OpenSSL-Win64" CACHE STRING "OpenSSL library path")
    set(COMPLEX_RETURN "intel" CACHE STRING "complex return type")
else()
    set(OpenMP_libomp_LIBRARY "" CACHE STRING "openmp library path")
    set(OPENSSL_INSTALL_DIR "" CACHE STRING "OpenSSL library path")
    set(COMPLEX_RETURN "default" CACHE STRING "complex return type")
    set (suff "o")
endif()

# Normalize paths
string(REPLACE "\\" "/" OpenMP_libomp_LIBRARY "${OpenMP_libomp_LIBRARY}")
cmake_path(GET OpenMP_libomp_LIBRARY PARENT_PATH EXT_OPENMP_PATH)
cmake_path(GET OpenMP_libomp_LIBRARY FILENAME EXT_OPENMP_LIB)

# Set threading options based on multithreading option
if(ENABLE_MULTITHREADING)
    set(ENABLE_THREADING "openmp")
    set(AOCL_ENABLE_THREADS ON)
    
    # Check if OpenMP_libomp_LIBRARY path exists
    if(OpenMP_libomp_LIBRARY AND NOT EXISTS "${OpenMP_libomp_LIBRARY}")
        message(FATAL_ERROR "OpenMP library path '${OpenMP_libomp_LIBRARY}' does not exist, please provide a valid path using -DOpenMP_libomp_LIBRARY=<path>")
    endif()
else()
    set(ENABLE_THREADING "no")
    set(AOCL_ENABLE_THREADS OFF)
endif()

# Find OpenMP if multithreading is enabled
if(ENABLE_MULTITHREADING AND (WIN32 OR NOT OpenMP_libomp_LIBRARY))
    find_package(OpenMP)
    if(NOT OPENMP_FOUND)
        message(FATAL_ERROR "OpenMP not found")
    endif()
endif()

# Normalize binary directory path
string(REPLACE "\\" "/" CMAKE_BINARY_DIR "${CMAKE_BINARY_DIR}")

# ---------------------------------------------------------------------------
# Unified AOCL library build (target-based: FetchContent + add_subdirectory).
#
# Each component lives in its own modular file under cmake/ (mirroring the old
# per-library split: aocl_utils.cmake, aocl_compression.cmake, aocl_blas.cmake,
# ...). They are pulled in
# with include() so they share this (root) directory scope and its variables;
# the order matters because later components consume earlier ones' targets and
# exported include dirs. aocl_targets_common.cmake sets up the shared helpers
# and resolves inter-component dependencies; aocl_unified.cmake merges the
# component static archives into libaocl.{so,a}.
# ---------------------------------------------------------------------------
set(AOCL_TB_CMAKE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
include(${AOCL_TB_CMAKE_DIR}/aocl_targets_common.cmake)
include(${AOCL_TB_CMAKE_DIR}/aocl_utils.cmake)
include(${AOCL_TB_CMAKE_DIR}/aocl_compression.cmake)
include(${AOCL_TB_CMAKE_DIR}/aocl_blas.cmake)
include(${AOCL_TB_CMAKE_DIR}/aocl_lapack.cmake)
include(${AOCL_TB_CMAKE_DIR}/aocl_sparse.cmake)
include(${AOCL_TB_CMAKE_DIR}/aocl_dlp.cmake)
include(${AOCL_TB_CMAKE_DIR}/aocl_da.cmake)
include(${AOCL_TB_CMAKE_DIR}/aocl_libmem.cmake)
include(${AOCL_TB_CMAKE_DIR}/aocl_libm.cmake)
include(${AOCL_TB_CMAKE_DIR}/aocl_openrng.cmake)
include(${AOCL_TB_CMAKE_DIR}/aocl_fftz.cmake)
include(${AOCL_TB_CMAKE_DIR}/aocl_crypto.cmake)
include(${AOCL_TB_CMAKE_DIR}/aocl_unified.cmake)

# === SYMBOL RENAMING INTEGRATION ===
# Single variable to control symbol renaming: if empty, renaming is disabled
# If set to a prefix (e.g., "AOCL_"), renaming is enabled with that prefix
set(SYMBOL_RENAME_PREFIX "" CACHE STRING "Prefix for symbol renaming (empty to disable)")

# Check if LibMem is enabled - symbol renaming is incompatible with LibMem
# LibMem uses IFUNC (indirect functions) that must retain standard C library names (memcpy, memset, etc.)
if(ENABLE_AOCL_LIBMEM AND SYMBOL_RENAME_PREFIX)
    message(FATAL_ERROR "Symbol renaming is not compatible with AOCL-LibMem. "
                        "LibMem uses IFUNC symbols that must retain standard C library names. "
                        "Please either disable LibMem (ENABLE_AOCL_LIBMEM=OFF) or "
                        "disable symbol renaming by omitting the SYMBOL_RENAME_PREFIX option.")
endif()

# Function to create symbol renaming target.
#
# Uses the CMake-native engine rename_symbols.cmake (ported from the validated
# aocl/ implementation): on Linux it drives objcopy + .so re-link and delegates
# map generation + header rewrite to rename_engine_linux.py; on Windows it uses
# rename_engine_windows.ps1 (llvm-nm/dumpbin + llvm-objcopy + lld-link/link.exe).
# It reads the installed unified library under ${CMAKE_INSTALL_PREFIX}/{lib,include}
# and writes the renamed copies under ${CMAKE_INSTALL_PREFIX}/renamed/{lib,include}.
function(add_symbol_renaming_target)
    if(SYMBOL_RENAME_PREFIX)
        set(INSTALL_PACKAGE_PATH "${CMAKE_INSTALL_PREFIX}")

        # Shared vs static: use the resolved AOCL linkage knob. The per-component
        # blocks force BUILD_SHARED_LIBS OFF locally, so it is NOT reliable here;
        # AOCL_LINKAGE_EFFECTIVE is the same source of truth aocl_unified.cmake used.
        if(AOCL_LINKAGE_EFFECTIVE STREQUAL "shared")
            set(_create_so_arg "-DCREATE_SO=ON")
            set(RENAME_MODE_MSG "Renaming symbols in static library and creating shared library")
        else()
            set(_create_so_arg "")
            set(RENAME_MODE_MSG "Renaming symbols in static library only")
        endif()

        # The renamed aggregate must re-link against exactly the third-party
        # libraries the unified library was composed from -- collected per
        # component via aocl_tb_add_external_libs() (OpenSSL from Crypto, the
        # Fortran runtime from LAPACK, OpenMP from the threaded components, ...).
        # Reusing that single list keeps the renamed .so/.dll in lockstep with the
        # original; no Fortran/OpenMP/OpenSSL library is named here at all.
        get_property(_aocl_external_libs GLOBAL PROPERTY AOCL_TB_EXTERNAL_LIBS)
        if(_aocl_external_libs)
            list(REMOVE_DUPLICATES _aocl_external_libs)
        endif()
        # OpenMP is resolved automatically when multithreading is enabled -- kept
        # out of the per-component external list. The renamed re-link runs in a
        # separate cmake -P process, so pass a resolved path/flag (not a target).
        if(ENABLE_MULTITHREADING)
            if(WIN32)
                if(AOCL_TB_FORTRAN_LIBDIR AND EXISTS "${AOCL_TB_FORTRAN_LIBDIR}/libiomp5md.lib")
                    list(APPEND _aocl_external_libs "${AOCL_TB_FORTRAN_LIBDIR}/libiomp5md.lib")
                endif()
            elseif(OpenMP_libomp_LIBRARY AND EXISTS "${OpenMP_libomp_LIBRARY}")
                list(APPEND _aocl_external_libs "${OpenMP_libomp_LIBRARY}")
            elseif(OpenMP_C_FLAGS)
                list(APPEND _aocl_external_libs "${OpenMP_C_FLAGS}")
            else()
                list(APPEND _aocl_external_libs "-fopenmp")
            endif()
        endif()

        if(WIN32)
            # Windows-only optional args: Intel Fortran runtime lib dir + OpenSSL
            # crypto import lib + OpenMP import lib, used by rename_symbols.cmake
            # when re-linking the renamed DLL. Each is passed only when available.
            # aocl_tbi exposes the Intel Fortran/OpenMP runtime lib dir as
            # AOCL_TB_FORTRAN_LIBDIR (set in aocl_targets_common.cmake); there is
            # no FORTRAN_LIB_DIR variable. The engine still reads -DFORTRAN_LIB_DIR,
            # so keep the arg name and source its value from AOCL_TB_FORTRAN_LIBDIR.
            # Mechanism flags for recreating the /MT DLL (these are NOT third-party
            # deps, so they stay here):
            #   STATIC_CRT      -> the renamed-DLL re-link pulls the static CRT
            #                      import libs to resolve std::cout/std::locale/...
            #                      embedded in the AOCL-Utils objects (/MT build).
            #   FORTRAN_LIB_DIR -> link search path so the Fortran objects' embedded
            #                      /DEFAULTLIB:libifcoremt / ifconsol directives
            #                      resolve.
            # Every actual third-party library (OpenSSL, the dynamic Intel Fortran
            # runtime, OpenMP, ...) is passed uniformly through SO_LIBS, taken from
            # the shared per-component external-deps list -- nothing hardcoded here.
            set(_rename_extra_args "")
            list(APPEND _rename_extra_args "-DSTATIC_CRT=ON")
            if(AOCL_TB_FORTRAN_LIBDIR)
                # Normalize to forward slashes: this value is embedded verbatim
                # into the generated cmake_install.cmake install(CODE) string, where
                # a Windows backslash is parsed as an invalid character escape.
                file(TO_CMAKE_PATH "${AOCL_TB_FORTRAN_LIBDIR}" _aocl_fortran_libdir)
                list(APPEND _rename_extra_args "-DFORTRAN_LIB_DIR=${_aocl_fortran_libdir}")
            endif()
            if(_aocl_external_libs)
                # Transport the collected list to the rename subprocess with '|'
                # separators, NOT ';'. A semicolon-joined string appended to a
                # CMake list (then re-parsed through the install(CODE) COMMAND)
                # splits into separate arguments, so only the first library would
                # survive. rename_symbols_windows.cmake splits SO_LIBS back on '|'.
                string(REPLACE ";" "|" _so_libs_arg "${_aocl_external_libs}")
                # Normalize Windows backslashes to forward slashes. This string is
                # embedded verbatim into the generated cmake_install.cmake
                # install(CODE); a backslash in a dependency path (e.g. an OpenSSL
                # lib under "C:\Program Files\...") is otherwise parsed there as an
                # invalid character escape ('\P') and aborts the install. Forward
                # slashes are valid on Windows for both linking and CMake parsing.
                string(REPLACE "\\" "/" _so_libs_arg "${_so_libs_arg}")
                list(APPEND _rename_extra_args "-DSO_LIBS=${_so_libs_arg}")
            endif()

            add_custom_target(rename_symbols
                COMMAND ${CMAKE_COMMAND}
                        -DINSTALL_PATH=${INSTALL_PACKAGE_PATH}
                        -DPREFIX=${SYMBOL_RENAME_PREFIX}
                        -DLIBNAME=${AOCL_SINGLE_LIBRARY_NAME}
                        ${_create_so_arg}
                        ${_rename_extra_args}
                        -P ${CMAKE_SOURCE_DIR}/symbol_rename/rename_symbols.cmake
                WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
                COMMENT "Symbol renaming (Windows) with ${SYMBOL_RENAME_PREFIX} prefix (run after install)"
                VERBATIM
            )

            # Re-stringify the optional args so semicolons inside them survive the
            # install(CODE) string.
            set(_post_extra_args "")
            foreach(_a IN LISTS _rename_extra_args)
                set(_post_extra_args "${_post_extra_args} \"${_a}\"")
            endforeach()

            _install(CODE "
                message(STATUS \"Running symbol renaming post-install (Windows, CMake-native)...\")
                message(STATUS \"Mode: ${RENAME_MODE_MSG}\")
                if(NOT EXISTS \"${CMAKE_INSTALL_PREFIX}/lib\")
                    message(FATAL_ERROR \"Installation directory structure incomplete: ${CMAKE_INSTALL_PREFIX}/lib not found\")
                endif()
                set(RENAME_SCRIPT \"${CMAKE_SOURCE_DIR}/symbol_rename/rename_symbols.cmake\")
                if(NOT EXISTS \"\${RENAME_SCRIPT}\")
                    message(FATAL_ERROR \"Symbol renaming script not found: \${RENAME_SCRIPT}\")
                endif()
                execute_process(
                    COMMAND \${CMAKE_COMMAND}
                            -DINSTALL_PATH=${CMAKE_INSTALL_PREFIX}
                            -DPREFIX=${SYMBOL_RENAME_PREFIX}
                            -DLIBNAME=${AOCL_SINGLE_LIBRARY_NAME}
                            ${_create_so_arg}
                            ${_post_extra_args}
                            -DPRUNE_STAGING_LIBS=ON
                            -P \"\${RENAME_SCRIPT}\"
                    WORKING_DIRECTORY \"${CMAKE_SOURCE_DIR}\"
                    RESULT_VARIABLE RENAME_RESULT
                )
                if(RENAME_RESULT EQUAL 0)
                    message(STATUS \"Symbol renaming completed successfully! Renamed libraries in ${CMAKE_INSTALL_PREFIX}/renamed/lib\")
                    message(STATUS \"All renamed symbols now have ${SYMBOL_RENAME_PREFIX} prefix\")
                else()
                    message(FATAL_ERROR \"Symbol renaming failed with exit code: \${RENAME_RESULT}\")
                endif()
            ")
        else()
            # Base runtime the recreated .so always needs: the aggregate carries
            # C++ objects but is re-linked with the C compiler driver, so libstdc++
            # and libpthread are added explicitly. Every component third-party dep
            # (Fortran runtime, OpenMP, OpenSSL, ...) comes from the shared list.
            set(SO_ADDITIONAL_LIBS "-lstdc++" "-lpthread" ${_aocl_external_libs})
            add_custom_target(rename_symbols
                COMMAND ${CMAKE_COMMAND}
                        -DINSTALL_PATH=${INSTALL_PACKAGE_PATH}
                        -DPREFIX=${SYMBOL_RENAME_PREFIX}
                        -DLIBNAME=${AOCL_SINGLE_LIBRARY_NAME}
                        ${_create_so_arg}
                        "-DSO_LIBS=${SO_ADDITIONAL_LIBS}"
                        -DCOMPILER=${CMAKE_C_COMPILER}
                        "-DLINKER_FLAGS=${CMAKE_SHARED_LINKER_FLAGS}"
                        -P ${CMAKE_SOURCE_DIR}/symbol_rename/rename_symbols.cmake
                WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
                COMMENT "Symbol renaming (Linux) with ${SYMBOL_RENAME_PREFIX} prefix (run after install)"
                VERBATIM
            )

            _install(CODE "
                message(STATUS \"Running symbol renaming post-install (Linux, CMake-native)...\")
                message(STATUS \"Mode: ${RENAME_MODE_MSG}\")
                if(NOT EXISTS \"${CMAKE_INSTALL_PREFIX}/lib\")
                    message(FATAL_ERROR \"Installation directory structure incomplete: ${CMAKE_INSTALL_PREFIX}/lib not found\")
                endif()
                set(RENAME_SCRIPT \"${CMAKE_SOURCE_DIR}/symbol_rename/rename_symbols.cmake\")
                if(NOT EXISTS \"\${RENAME_SCRIPT}\")
                    message(FATAL_ERROR \"Symbol renaming script not found: \${RENAME_SCRIPT}\")
                endif()
                execute_process(
                    COMMAND \${CMAKE_COMMAND}
                            -DINSTALL_PATH=${CMAKE_INSTALL_PREFIX}
                            -DPREFIX=${SYMBOL_RENAME_PREFIX}
                            -DLIBNAME=${AOCL_SINGLE_LIBRARY_NAME}
                            ${_create_so_arg}
                            \"-DSO_LIBS=${SO_ADDITIONAL_LIBS}\"
                            -DCOMPILER=${CMAKE_C_COMPILER}
                            \"-DLINKER_FLAGS=${CMAKE_SHARED_LINKER_FLAGS}\"
                            -DPRUNE_STAGING_LIBS=ON
                            -P \"\${RENAME_SCRIPT}\"
                    WORKING_DIRECTORY \"${CMAKE_SOURCE_DIR}\"
                    RESULT_VARIABLE RENAME_RESULT
                )
                if(RENAME_RESULT EQUAL 0)
                    message(STATUS \"Symbol renaming completed successfully! Renamed libraries in ${CMAKE_INSTALL_PREFIX}/renamed/lib\")
                    message(STATUS \"All renamed symbols now have ${SYMBOL_RENAME_PREFIX} prefix\")
                else()
                    message(FATAL_ERROR \"Symbol renaming failed with exit code: \${RENAME_RESULT}\")
                endif()
            ")
        endif()
    else()
        message(STATUS "Symbol renaming is disabled. To enable, use: -DSYMBOL_RENAME_PREFIX=<prefix>")
        message(STATUS "  Example: -DSYMBOL_RENAME_PREFIX=AOCL_ or -DSYMBOL_RENAME_PREFIX=AOCL51_ etc.")
    endif()
endfunction()

# Call the function to set up symbol renaming
add_symbol_renaming_target()

# Add test subdirectory if tests are enabled
if(ENABLE_TESTS)
    enable_testing()
    add_subdirectory(test)
endif()
