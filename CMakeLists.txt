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
# AOCL-ScaLAPACK is NOT merged into the unified libaocl: when enabled it is built
# as its own library that LINKS the finished libaocl (which must contain its
# prerequisites blis + aocl-utils + libflame). Requires MPI and a Fortran compiler.
option(ENABLE_AOCL_SCALAPACK "Build AOCL-ScaLAPACK as a separate library linked against the unified libaocl (not merged into it)" OFF)
option(ENABLE_MULTITHREADING "Check if we need to enable multithreading" OFF)
option(ENABLE_CBLAS "Check if we need to enable AOCL-BLAS CBLAS interface" ON)
option(ENABLE_AMD_FLAGS "Check if we need to enable amd flags for AOCL-LAPACK library build" OFF)
option(ENABLE_AMD_AOCC_FLAGS "Check if we need to enable amd aocc flags for AOCL-LAPACK library build" OFF)
option(ENABLE_TRSM_PREINVERSION "Check if we need to enable trsm preinversion" ON)
option(ENABLE_ILP64 "Check if we need to enable ILP64" OFF)
option(ENABLE_BLAS_EXT_GEMMT "Check if we need to enable blas external gemmt for AOCL-LAPACK library build" ON)
option(ENABLE_AOCL_LAPACK_BLAS_COUPLING "Check if we need to tightly coupled with AOCL-BLAS library for AOCL-LAPACK library build" OFF)
option(ENABLE_TESTS "Enable building and running library functionality tests" OFF)

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

# AOCL-ScaLAPACK is built SEPARATELY and linked against the finished unified
# libaocl (NOT merged into it); included AFTER aocl_unified.cmake so the 'aocl'
# target already exists to depend on and link.
include(${AOCL_TB_CMAKE_DIR}/aocl_scalapack.cmake)

# Add test subdirectory if tests are enabled
if(ENABLE_TESTS)
    enable_testing()
    add_subdirectory(test)
endif()
