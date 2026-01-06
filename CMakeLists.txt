# Copyright (C) 2025, Advanced Micro Devices, Inc. All rights reserved.

# Set the minimum required version of CMake
cmake_minimum_required(VERSION 3.26.0)

# Set the project name
if(NOT DEFINED AOCL_SINGLE_LIBRARY_NAME)
    set(AOCL_SINGLE_LIBRARY_NAME "aocl")
endif()
project(${AOCL_SINGLE_LIBRARY_NAME} LANGUAGES C CXX)

# Set the build configurations
if(NOT DEFINED CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_CONFIGURATION_TYPES "Debug" CACHE STRING "Build configurations" FORCE)
elseif(CMAKE_CONFIGURATION_TYPES MATCHES "Debug;")
    set(CMAKE_CONFIGURATION_TYPES "Debug" CACHE STRING "Build configurations" FORCE)
endif()

# Set the build type
if(NOT DEFINED CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE "Debug" CACHE STRING "Build type" FORCE)
elseif(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE "Debug" CACHE STRING "Build type" FORCE)
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

# Calculate approximately 50% of the available CPU cores on the build machine
# to use with the -j option for parallel builds, balancing performance and memory usage.
# Detect number of available processors
if(UNIX)
    execute_process(COMMAND nproc
                    OUTPUT_VARIABLE NUM_CORES
                    OUTPUT_STRIP_TRAILING_WHITESPACE)
    # Calculate 50% of cores (round up to at least 1)
    math(EXPR BUILD_CORES "(${NUM_CORES} + 1) / 2")  # +1 ensures rounding up

    # Message for debug/logging
    message(STATUS "Using ${BUILD_CORES} cores for parallel build out of ${NUM_CORES} available.")
    set(parallel "-j${BUILD_CORES}")
else()
    set(parallel "-j")
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
option(ENABLE_MULTITHREADING "Check if we need to enable multithreading" OFF)
option(ENABLE_CBLAS "Check if we need to enable AOCL-BLAS CBLAS interface" ON)
option(ENABLE_AMD_FLAGS "Check if we need to enable amd flags for AOCL-LAPACK library build" OFF)
option(ENABLE_AMD_AOCC_FLAGS "Check if we need to enable amd aocc flags for AOCL-LAPACK library build" OFF)
option(ENABLE_TRSM_PREINVERSION "Check if we need to enable trsm preinversion" ON)
option(ENABLE_ILP64 "Check if we need to enable ILP64" OFF)
option(ENABLE_BLAS_EXT_GEMMT "Check if we need to enable blas external gemmt for AOCL-LAPACK library build" ON)
option(ENABLE_AOCL_BLAS "Check if we need to tightly coupled with AOCL-BLAS library for AOCL-LAPACK library build" OFF)

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
    set(ALM_STATIC_DISPATCH_OPTION "AVX2" CACHE STRING "LibFlame ISA configuration" FORCE)
    message(STATUS "ALM_STATIC_DISPATCH_OPTION set to: AVX2 (based on AMD_CONFIG=${AMD_CONFIG})")
elseif(AMD_CONFIG STREQUAL "zen2" OR AMD_CONFIG STREQUAL "zen3" OR AMD_CONFIG STREQUAL "zen4" OR AMD_CONFIG STREQUAL "zen5")
    string(TOUPPER "${AMD_CONFIG}" ALM_DISPATCH_UPPER)
    set(ALM_STATIC_DISPATCH_OPTION "${ALM_DISPATCH_UPPER}" CACHE STRING "LibM static dispatch option" FORCE)
    message(STATUS "ALM_STATIC_DISPATCH_OPTION set to: ${ALM_DISPATCH_UPPER})")
else()
    set(ALM_STATIC_DISPATCH_OPTION "" CACHE STRING "LibM static dispatch option")
    message(STATUS "ALM_STATIC_DISPATCH_OPTION set to default: (dynamic dispatch)")
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

# Initialize lists for object files, def files, and dependent libs
set(OBJECT_FILES "")
set(DEF_FILES "")
set(DEPENDENT_LIBS "")

# Include build scripts based on enabled options
if(ENABLE_AOCL_UTILS)
    include(aocl_utils_build.cmake)
endif()

if(ENABLE_AOCL_COMPRESSION)
    include(aocl_compression_build.cmake)
endif()

if(ENABLE_AOCL_BLAS)
    include(aocl_blis_build.cmake)
endif()

if(UNIX AND ENABLE_AOCL_LIBMEM)
    include(aocl_libmem_build.cmake)
elseif(ENABLE_AOCL_LIBMEM)
    message(WARNING "AOCL-LibMem is only supported on UNIX platforms.")
endif()

if(ENABLE_AOCL_LAPACK)
    if(NOT ENABLE_AOCL_BLAS OR NOT ENABLE_AOCL_UTILS)
        message(WARNING "AOCL-LAPACK has dependency on AOCL-BLAS and AOCL-Utils. Hence ENABLE_AOCL_BLAS and ENABLE_AOCL_UTILS should be \"check\" or \"ON\"")
        if(NOT ENABLE_AOCL_UTILS)
            set(ENABLE_AOCL_UTILS ON)
            include(aocl_utils_build.cmake)
        endif()

        if(NOT ENABLE_AOCL_BLAS)
            set(ENABLE_AOCL_BLAS ON)
            include(aocl_blis_build.cmake)
        endif()
    endif()

    include(aocl_libflame_build.cmake)
endif()

if(ENABLE_AOCL_SPARSE)
    if(NOT ENABLE_AOCL_BLAS OR NOT ENABLE_AOCL_UTILS OR NOT ENABLE_AOCL_LAPACK)
        message(WARNING "AOCL-SPARSE has dependency on AOCL-BLAS, AOCL-LAPACK and AOCL-Utils. Hence ENABLE_AOCL_BLAS, ENABLE_AOCL_LAPACK and ENABLE_AOCL_UTILS should be \"check\" or \"ON\"")
        if(NOT ENABLE_AOCL_UTILS)
            set(ENABLE_AOCL_UTILS ON)
            include(aocl_utils_build.cmake)
        endif()

        if(NOT ENABLE_AOCL_BLAS)
            set(ENABLE_AOCL_BLAS ON)
            include(aocl_blis_build.cmake)
        endif()

        if(NOT ENABLE_AOCL_LAPACK)
            set(ENABLE_AOCL_LAPACK ON)
            include(aocl_libflame_build.cmake)
        endif()
    endif()

    include(aocl_sparse_build.cmake)
endif()

if(ENABLE_AOCL_DA)
    enable_language(Fortran)
    if(NOT ENABLE_AOCL_BLAS OR NOT ENABLE_AOCL_UTILS OR NOT ENABLE_AOCL_LAPACK OR NOT ENABLE_AOCL_SPARSE)
        message(WARNING "AOCL-DA has dependency on AOCL-BLAS, AOCL-LAPACK and AOCL-Utils. Hence ENABLE_AOCL_BLAS, ENABLE_AOCL_LAPACK, ENABLE_AOCL_SPARSE and ENABLE_AOCL_UTILS should be \"check\" or \"ON\"")
        if(NOT ENABLE_AOCL_UTILS)
            set(ENABLE_AOCL_UTILS ON)
            include(aocl_utils_build.cmake)
        endif()

        if(NOT ENABLE_AOCL_BLAS)
            set(ENABLE_AOCL_BLAS ON)
            include(aocl_blis_build.cmake)
        endif()

        if(NOT ENABLE_AOCL_LAPACK)
            set(ENABLE_AOCL_LAPACK ON)
            include(aocl_libflame_build.cmake)
        endif()

        if(NOT ENABLE_AOCL_SPARSE)
            set(ENABLE_AOCL_SPARSE ON)
            include(aocl_sparse_build.cmake)
        endif()
    endif()

    include(aocl_da_build.cmake)
endif()

if(ENABLE_AOCL_LIBM)
    if(NOT ENABLE_AOCL_UTILS)
        set(ENABLE_AOCL_UTILS ON)
        include(aocl_utils_build.cmake)
    endif()
    include(aocl_libm_build.cmake)
endif()

if(ENABLE_AOCL_CRYPTO)
    # Check if OPENSSL_INSTALL_DIR contains 'lib' or 'lib64' and 'include' folders
    if(WIN32)
        if(NOT IS_DIRECTORY "${OPENSSL_INSTALL_DIR}/lib" OR NOT IS_DIRECTORY "${OPENSSL_INSTALL_DIR}/include")
            message(FATAL_ERROR "OPENSSL_INSTALL_DIR environment variable is not set correctly or ${OPENSSL_INSTALL_DIR} does not contain 'lib' and 'include' folders. Please also ensure crypto and openssl libraries are present in ${OPENSSL_INSTALL_DIR}/lib folder.")
        elseif(NOT EXISTS "${OPENSSL_INSTALL_DIR}/lib/libcrypto.lib" OR NOT EXISTS "${OPENSSL_INSTALL_DIR}/lib/libssl.lib")
            message(FATAL_ERROR "${OPENSSL_INSTALL_DIR}/lib does not contain 'libcrypto.lib' and 'libssl.lib' libraries.")
        else()
            message(STATUS "OPENSSL_INSTALL_DIR environment variable is set correctly.")
        endif()
    elseif(UNIX)
        if(NOT ((IS_DIRECTORY "${OPENSSL_INSTALL_DIR}/lib64" OR IS_DIRECTORY "${OPENSSL_INSTALL_DIR}/lib") AND (IS_DIRECTORY "${OPENSSL_INSTALL_DIR}/include")))
            message(FATAL_ERROR "OPENSSL_INSTALL_DIR environment variable is not set correctly or ${OPENSSL_INSTALL_DIR} does not contain 'lib' or 'lib64' and 'include' folders. Please also ensure crypto and openssl libraries are present in ${OPENSSL_INSTALL_DIR}/lib or ${OPENSSL_INSTALL_DIR}/lib64 folder.")
        elseif((IS_DIRECTORY "${OPENSSL_INSTALL_DIR}/lib64" AND (NOT EXISTS "${OPENSSL_INSTALL_DIR}/lib64/libcrypto.so" OR NOT EXISTS "${OPENSSL_INSTALL_DIR}/lib64/libssl.so")) OR (IS_DIRECTORY "${OPENSSL_INSTALL_DIR}/lib" AND (NOT EXISTS "${OPENSSL_INSTALL_DIR}/lib/libcrypto.so" OR NOT EXISTS "${OPENSSL_INSTALL_DIR}/lib/libssl.so")))
            message(FATAL_ERROR "${OPENSSL_INSTALL_DIR} does not contain 'libcrypto.so' and 'libssl.so' libraries in 'lib' or 'lib64' folder.")
        else()
            message(STATUS "OPENSSL_INSTALL_DIR environment variable is set correctly.")
        endif()
    endif()

    if(NOT ENABLE_AOCL_UTILS)
        set(ENABLE_AOCL_UTILS ON)
        include(aocl_utils_build.cmake)
    endif()
    include(aocl_crypto_build.cmake)
endif()

# Merge def files on Windows
if(BUILD_SHARED_LIBS AND WIN32)
    string(REPLACE "\\" "/" MERGED_DEF "${CMAKE_BINARY_DIR}/exports.def")
    file(WRITE ${MERGED_DEF} "")
    foreach(DEF_FILE IN LISTS DEF_FILES)
        file(READ ${DEF_FILE} DEF_CONTENT)
        file(APPEND ${MERGED_DEF} "${DEF_CONTENT}\n")
    endforeach()
    message(STATUS "DEF_FILES : ${DEF_FILES}")
endif()

# Create the library target
if(BUILD_SHARED_LIBS)
    add_library (${PROJECT_NAME} SHARED ${OBJECT_FILES})
    set_target_properties(${PROJECT_NAME} PROPERTIES POSITION_INDEPENDENT_CODE ON)
    set_target_properties(${PROJECT_NAME} PROPERTIES LINKER_LANGUAGE CXX)
    target_link_libraries(${PROJECT_NAME} PRIVATE ${DEPENDENT_LIBS})
    
    if(ENABLE_MULTITHREADING)
        if(WIN32 OR NOT OpenMP_libomp_LIBRARY)
            target_link_libraries(${PROJECT_NAME} PRIVATE OpenMP::OpenMP_C)
        else()
            target_link_libraries(${PROJECT_NAME} PRIVATE ${OpenMP_libomp_LIBRARY})
        endif()
    endif()
    
    if(WIN32)
        target_link_options(${PROJECT_NAME} PRIVATE "/DEF:${MERGED_DEF}")
        set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} /dll")
		if(CMAKE_Fortran_COMPILER)
	        target_link_directories(${PROJECT_NAME} PRIVATE "C:/Program Files (x86)/Intel/oneAPI/compiler/latest/lib")
		endif()
    else()
        if(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
            set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -fuse-ld=ld")
        endif()
        add_library (${PROJECT_NAME}-static STATIC ${OBJECT_FILES})
        set_target_properties(${PROJECT_NAME}-static PROPERTIES LINKER_LANGUAGE CXX)
        set_target_properties(${PROJECT_NAME}-static PROPERTIES OUTPUT_NAME ${PROJECT_NAME})
        install(TARGETS ${PROJECT_NAME}-static LIBRARY DESTINATION ${CMAKE_INSTALL_PREFIX}/lib
                ARCHIVE DESTINATION ${CMAKE_INSTALL_PREFIX}/lib
                RUNTIME DESTINATION ${CMAKE_INSTALL_PREFIX}/lib
                )
    endif()
else()
    add_library (${PROJECT_NAME} STATIC ${OBJECT_FILES})
    set_target_properties(${PROJECT_NAME} PROPERTIES LINKER_LANGUAGE CXX)
endif()

# Install the library
install(TARGETS ${PROJECT_NAME} LIBRARY DESTINATION ${CMAKE_INSTALL_PREFIX}/lib
        ARCHIVE DESTINATION ${CMAKE_INSTALL_PREFIX}/lib
        RUNTIME DESTINATION ${CMAKE_INSTALL_PREFIX}/lib
        )
