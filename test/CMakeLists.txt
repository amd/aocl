# Copyright (C) 2025, Advanced Micro Devices, Inc. All rights reserved.

cmake_minimum_required(VERSION 3.15)
project(aocl_symbol_rename_test C CXX Fortran)

# Check which AOCL libraries are enabled in the parent project
set(ENABLED_LIBS "")

if(ENABLE_AOCL_UTILS)
    list(APPEND ENABLED_LIBS "UTILS")
endif()

if(ENABLE_AOCL_BLAS)
    list(APPEND ENABLED_LIBS "BLAS")
endif()

if(ENABLE_AOCL_LAPACK)
    list(APPEND ENABLED_LIBS "LAPACK")
endif()

if(ENABLE_AOCL_SPARSE)
    list(APPEND ENABLED_LIBS "SPARSE")
endif()

if(ENABLE_AOCL_CRYPTO)
    list(APPEND ENABLED_LIBS "CRYPTO")
endif()

if(ENABLE_AOCL_LIBM)
    list(APPEND ENABLED_LIBS "LIBM")
endif()

if(ENABLE_AOCL_COMPRESSION)
    list(APPEND ENABLED_LIBS "COMPRESSION")
endif()

if(ENABLE_AOCL_DA)
    list(APPEND ENABLED_LIBS "DA")
endif()

if(ENABLE_AOCL_LIBMEM)
    list(APPEND ENABLED_LIBS "LIBMEM")
endif()

if(ENABLED_LIBS)
    message(STATUS "Testing enabled for libraries: ${ENABLED_LIBS}")
else()
    message(WARNING "No AOCL libraries enabled - tests may fail")
endif()

# Use the parent's install prefix
set(AOCL_INSTALL_DIR "${CMAKE_INSTALL_PREFIX}" CACHE PATH "AOCL installation directory")

# Get the symbol rename prefix from parent (if any)
if(NOT DEFINED SYMBOL_RENAME_PREFIX)
    set(SYMBOL_RENAME_PREFIX "" CACHE STRING "Symbol rename prefix from parent")
endif()

# Convert prefix to lowercase and uppercase for C/Fortran code
if(SYMBOL_RENAME_PREFIX)
    string(TOLOWER "${SYMBOL_RENAME_PREFIX}" SYMBOL_PREFIX_LOWER)
    string(TOUPPER "${SYMBOL_RENAME_PREFIX}" SYMBOL_PREFIX_UPPER)
    set(BUILD_RENAMED_TEST TRUE)
else()
    set(SYMBOL_PREFIX_LOWER "")
    set(SYMBOL_PREFIX_UPPER "")
    set(BUILD_RENAMED_TEST FALSE)
endif()

# Determine which test executables to build
if(BUILD_RENAMED_TEST)
    message(STATUS "Building test executables: test_original_symbols + test_renamed_symbols")
else()
    message(STATUS "Building test executable: test_original_symbols only")
endif()

# ============================================================================
# Test Executable 1: ORIGINAL symbols (no prefix)
# Note: Uses test_aocl_symbols.c source file with different compile-time
#       configurations. Without USE_RENAMED_SYMBOLS defined, it tests original
#       (non-prefixed) symbols. With USE_RENAMED_SYMBOLS, it tests renamed symbols.
# ============================================================================
add_executable(test_original_symbols EXCLUDE_FROM_ALL
    test_aocl_symbols.c
)

add_dependencies(test_original_symbols aocl)

target_include_directories(test_original_symbols PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${AOCL_INSTALL_DIR}/include
)

target_compile_definitions(test_original_symbols PRIVATE
    SYMBOL_PREFIX_STR=""
)

# Add library-specific defines based on enabled libraries
if(ENABLE_AOCL_BLAS)
    target_compile_definitions(test_original_symbols PRIVATE ENABLE_BLAS)
endif()

if(ENABLE_AOCL_LAPACK)
    target_compile_definitions(test_original_symbols PRIVATE ENABLE_LAPACK)
endif()

if(ENABLE_AOCL_SPARSE)
    target_compile_definitions(test_original_symbols PRIVATE ENABLE_SPARSE)
endif()

if(ENABLE_AOCL_LIBM)
    target_compile_definitions(test_original_symbols PRIVATE ENABLE_LIBM)
endif()

if(ENABLE_AOCL_COMPRESSION)
    target_compile_definitions(test_original_symbols PRIVATE ENABLE_COMPRESSION)
endif()

if(ENABLE_AOCL_CRYPTO)
    target_compile_definitions(test_original_symbols PRIVATE ENABLE_CRYPTO)
endif()

if(ENABLE_AOCL_DA)
    target_compile_definitions(test_original_symbols PRIVATE ENABLE_DA)
endif()

if(ENABLE_AOCL_LIBMEM)
    target_compile_definitions(test_original_symbols PRIVATE ENABLE_LIBMEM)
endif()

if(BUILD_SHARED_LIBS)
    set(AOCL_LIB_SUFFIX "${CMAKE_SHARED_LIBRARY_SUFFIX}")
else()
    set(AOCL_LIB_SUFFIX "${CMAKE_STATIC_LIBRARY_SUFFIX}")
endif()

target_link_libraries(test_original_symbols PRIVATE
    ${AOCL_INSTALL_DIR}/lib/libaocl${AOCL_LIB_SUFFIX}
    m
    pthread
    gfortran
    quadmath
    stdc++
)

if(ENABLE_AOCL_CRYPTO)
    target_link_libraries(test_original_symbols PRIVATE
        crypto
        ssl
    )
endif()

if(ENABLE_MULTITHREADING)
    find_package(OpenMP)
    if(OpenMP_C_FOUND)
        target_link_libraries(test_original_symbols PRIVATE OpenMP::OpenMP_C)
    endif()
endif()

set_target_properties(test_original_symbols PROPERTIES
    C_STANDARD 99
    C_STANDARD_REQUIRED ON
    BUILD_RPATH "${AOCL_INSTALL_DIR}/lib"
    INSTALL_RPATH "${AOCL_INSTALL_DIR}/lib"
)

# ============================================================================
# Test Executable 2: RENAMED symbols (with prefix) - CONDITIONAL
# Only build if symbol renaming is enabled
# ============================================================================
if(BUILD_RENAMED_TEST)
    add_executable(test_renamed_symbols EXCLUDE_FROM_ALL
        test_aocl_symbols.c
    )
    add_dependencies(test_renamed_symbols aocl)

    target_include_directories(test_renamed_symbols PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}
        ${AOCL_INSTALL_DIR}/renamed/include
    )

    target_compile_definitions(test_renamed_symbols PRIVATE
        USE_RENAMED_SYMBOLS
        SYMBOL_PREFIX_TOKEN_LOWER=${SYMBOL_PREFIX_LOWER}
        SYMBOL_PREFIX_TOKEN_UPPER=${SYMBOL_PREFIX_UPPER}
        SYMBOL_PREFIX_STR="${SYMBOL_PREFIX_LOWER}"
    )

    # Add library-specific defines based on enabled libraries
    if(ENABLE_AOCL_BLAS)
        target_compile_definitions(test_renamed_symbols PRIVATE ENABLE_BLAS)
    endif()

    if(ENABLE_AOCL_LAPACK)
        target_compile_definitions(test_renamed_symbols PRIVATE ENABLE_LAPACK)
    endif()

    if(ENABLE_AOCL_SPARSE)
        target_compile_definitions(test_renamed_symbols PRIVATE ENABLE_SPARSE)
    endif()

    if(ENABLE_AOCL_LIBM)
        target_compile_definitions(test_renamed_symbols PRIVATE ENABLE_LIBM)
    endif()

    if(ENABLE_AOCL_COMPRESSION)
        target_compile_definitions(test_renamed_symbols PRIVATE ENABLE_COMPRESSION)
    endif()

    if(ENABLE_AOCL_CRYPTO)
        target_compile_definitions(test_renamed_symbols PRIVATE ENABLE_CRYPTO)
    endif()

    if(ENABLE_AOCL_DA)
        target_compile_definitions(test_renamed_symbols PRIVATE ENABLE_DA)
    endif()

    if(ENABLE_AOCL_LIBMEM)
        target_compile_definitions(test_renamed_symbols PRIVATE ENABLE_LIBMEM)
    endif()

    target_link_libraries(test_renamed_symbols PRIVATE
        ${AOCL_INSTALL_DIR}/renamed/lib/libaocl${AOCL_LIB_SUFFIX}
        m
        pthread
        gfortran
        quadmath
        stdc++
    )

    if(ENABLE_AOCL_CRYPTO)
        target_link_libraries(test_renamed_symbols PRIVATE
            crypto
            ssl
        )
    endif()

    if(ENABLE_MULTITHREADING)
        find_package(OpenMP)
        if(OpenMP_C_FOUND)
            target_link_libraries(test_renamed_symbols PRIVATE OpenMP::OpenMP_C)
        endif()
    endif()

    set_target_properties(test_renamed_symbols PROPERTIES
        C_STANDARD 99
        C_STANDARD_REQUIRED ON
        BUILD_RPATH "${AOCL_INSTALL_DIR}/renamed/lib"
        INSTALL_RPATH "${AOCL_INSTALL_DIR}/renamed/lib"
    )
endif()  # BUILD_RENAMED_TEST

# ============================================================================
# C++ Test Executable(s): AOCL-Utils / AOCL-Crypto / AOCL-DA
# ============================================================================
if(ENABLE_AOCL_UTILS OR ENABLE_AOCL_CRYPTO OR ENABLE_AOCL_DA)
    add_executable(test_cpp_original_symbols EXCLUDE_FROM_ALL
        test_aocl_cpp.cpp
    )

    add_dependencies(test_cpp_original_symbols aocl)

    target_include_directories(test_cpp_original_symbols PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}
        ${AOCL_INSTALL_DIR}/include
    )

    target_compile_definitions(test_cpp_original_symbols PRIVATE
        SYMBOL_PREFIX_STR=""
    )

    if(ENABLE_AOCL_UTILS)
        target_compile_definitions(test_cpp_original_symbols PRIVATE ENABLE_UTILS)
    endif()

    if(ENABLE_AOCL_CRYPTO)
        target_compile_definitions(test_cpp_original_symbols PRIVATE ENABLE_CRYPTO)
    endif()

    if(ENABLE_AOCL_DA)
        target_compile_definitions(test_cpp_original_symbols PRIVATE ENABLE_DA)
    endif()

    target_link_libraries(test_cpp_original_symbols PRIVATE
        ${AOCL_INSTALL_DIR}/lib/libaocl${AOCL_LIB_SUFFIX}
        m
        pthread
        gfortran
        quadmath
        stdc++
    )

    if(ENABLE_AOCL_CRYPTO)
        target_link_libraries(test_cpp_original_symbols PRIVATE
            crypto
            ssl
        )
    endif()

    if(ENABLE_MULTITHREADING)
        find_package(OpenMP)
        if(OpenMP_CXX_FOUND)
            target_link_libraries(test_cpp_original_symbols PRIVATE OpenMP::OpenMP_CXX)
        endif()
    endif()

    set_target_properties(test_cpp_original_symbols PROPERTIES
        CXX_STANDARD 17
        CXX_STANDARD_REQUIRED ON
        BUILD_RPATH "${AOCL_INSTALL_DIR}/lib"
        INSTALL_RPATH "${AOCL_INSTALL_DIR}/lib"
    )

    if(BUILD_RENAMED_TEST)
        add_executable(test_cpp_renamed_symbols EXCLUDE_FROM_ALL
            test_aocl_cpp.cpp
        )

        add_dependencies(test_cpp_renamed_symbols aocl)

        target_include_directories(test_cpp_renamed_symbols PRIVATE
            ${CMAKE_CURRENT_SOURCE_DIR}
            ${AOCL_INSTALL_DIR}/renamed/include
        )

        target_compile_definitions(test_cpp_renamed_symbols PRIVATE
            USE_RENAMED_SYMBOLS
            SYMBOL_PREFIX_TOKEN_LOWER=${SYMBOL_PREFIX_LOWER}
            SYMBOL_PREFIX_STR="${SYMBOL_PREFIX_LOWER}"
        )

        if(ENABLE_AOCL_UTILS)
            target_compile_definitions(test_cpp_renamed_symbols PRIVATE ENABLE_UTILS)
        endif()

        if(ENABLE_AOCL_CRYPTO)
            target_compile_definitions(test_cpp_renamed_symbols PRIVATE ENABLE_CRYPTO)
        endif()

        if(ENABLE_AOCL_DA)
            target_compile_definitions(test_cpp_renamed_symbols PRIVATE ENABLE_DA)
        endif()

        target_link_libraries(test_cpp_renamed_symbols PRIVATE
            ${AOCL_INSTALL_DIR}/renamed/lib/libaocl${AOCL_LIB_SUFFIX}
            m
            pthread
            gfortran
            quadmath
            stdc++
        )

        if(ENABLE_AOCL_CRYPTO)
            target_link_libraries(test_cpp_renamed_symbols PRIVATE
                crypto
                ssl
            )
        endif()

        if(ENABLE_MULTITHREADING)
            find_package(OpenMP)
            if(OpenMP_CXX_FOUND)
                target_link_libraries(test_cpp_renamed_symbols PRIVATE OpenMP::OpenMP_CXX)
            endif()
        endif()

        set_target_properties(test_cpp_renamed_symbols PROPERTIES
            CXX_STANDARD 17
            CXX_STANDARD_REQUIRED ON
            BUILD_RPATH "${AOCL_INSTALL_DIR}/renamed/lib"
            INSTALL_RPATH "${AOCL_INSTALL_DIR}/renamed/lib"
        )
    endif()
else()
    message(STATUS "Skipping C++ tests: at least one of ENABLE_AOCL_UTILS, ENABLE_AOCL_CRYPTO, or ENABLE_AOCL_DA must be ON")
endif()

# ============================================================================
# CTest Integration
# ============================================================================
add_test(NAME test_original_symbols
    COMMAND test_original_symbols
    WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
)

set_tests_properties(test_original_symbols PROPERTIES
    ENVIRONMENT "LD_LIBRARY_PATH=${AOCL_INSTALL_DIR}/lib:$ENV{LD_LIBRARY_PATH}"
)

if(TARGET test_cpp_original_symbols)
    add_test(NAME test_cpp_original_symbols
        COMMAND test_cpp_original_symbols
        WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
    )

    set_tests_properties(test_cpp_original_symbols PROPERTIES
        ENVIRONMENT "LD_LIBRARY_PATH=${AOCL_INSTALL_DIR}/lib:$ENV{LD_LIBRARY_PATH}"
    )
endif()

# Python unit tests for symbol renaming logic (C/C++ mangled handling)
find_package(Python3 COMPONENTS Interpreter)
if(Python3_Interpreter_FOUND)
    add_test(NAME test_rename_symbols_cpp
        COMMAND ${Python3_EXECUTABLE} -m unittest discover
                -s ${CMAKE_CURRENT_SOURCE_DIR}
                -p test_rename_symbols_cpp.py
                -v
        WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    )
else()
    message(WARNING "Python3 interpreter not found. Skipping test_rename_symbols_cpp CTest hook.")
endif()

# Only add renamed symbols test if renaming is enabled
if(BUILD_RENAMED_TEST)
    add_test(NAME test_renamed_symbols
        COMMAND test_renamed_symbols
        WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
    )

    set_tests_properties(test_renamed_symbols PROPERTIES
        ENVIRONMENT "LD_LIBRARY_PATH=${AOCL_INSTALL_DIR}/renamed/lib:$ENV{LD_LIBRARY_PATH}"
    )

    if(TARGET test_cpp_renamed_symbols)
        add_test(NAME test_cpp_renamed_symbols
            COMMAND test_cpp_renamed_symbols
            WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
        )

        set_tests_properties(test_cpp_renamed_symbols PROPERTIES
            ENVIRONMENT "LD_LIBRARY_PATH=${AOCL_INSTALL_DIR}/renamed/lib:$ENV{LD_LIBRARY_PATH}"
        )
    endif()
endif()



# ============================================================================
# Test Executable 3: Mix original and renamed symbols
# ============================================================================
if(BUILD_RENAMED_TEST AND ENABLE_AOCL_BLAS)
    if(BUILD_SHARED_LIBS)
        set(AOCL_LIB_TYPE SHARED)
    else()
        set(AOCL_LIB_TYPE STATIC)
    endif()
    
    add_library(aocl_original ${AOCL_LIB_TYPE} IMPORTED)
    set_target_properties(aocl_original PROPERTIES
        IMPORTED_LOCATION "${AOCL_INSTALL_DIR}/lib/libaocl${AOCL_LIB_SUFFIX}"
    )
    
    add_library(aocl_renamed ${AOCL_LIB_TYPE} IMPORTED)
    set_target_properties(aocl_renamed PROPERTIES
        IMPORTED_LOCATION "${AOCL_INSTALL_DIR}/renamed/lib/libaocl${AOCL_LIB_SUFFIX}"
    )

    add_executable(mix_libraries EXCLUDE_FROM_ALL
        mix_libraries.F90
    )

    target_compile_definitions(mix_libraries PRIVATE
        USE_RENAMED_SYMBOLS
        RENAMED_PREFIX=${SYMBOL_PREFIX_LOWER}
        renamed_bli_thread_get_num_threads=${SYMBOL_PREFIX_LOWER}bli_thread_get_num_threads
        renamed_dgemm=${SYMBOL_PREFIX_LOWER}dgemm
    )

    target_compile_options(mix_libraries PRIVATE
        -cpp
    )

    # Link using imported targets
    target_link_libraries(mix_libraries PRIVATE
        aocl_original
        aocl_renamed
        m
        pthread
        gfortran
        quadmath
        stdc++
    )

    if(ENABLE_AOCL_CRYPTO)
        # Find OpenSSL libraries in lib or lib64
        find_library(OPENSSL_CRYPTO_LIB NAMES crypto
            PATHS "${OPENSSL_INSTALL_DIR}/lib" "${OPENSSL_INSTALL_DIR}/lib64"
            NO_DEFAULT_PATH
        )
        find_library(OPENSSL_SSL_LIB NAMES ssl
            PATHS "${OPENSSL_INSTALL_DIR}/lib" "${OPENSSL_INSTALL_DIR}/lib64"
            NO_DEFAULT_PATH
        )
        
        target_link_libraries(mix_libraries PRIVATE
            ${OPENSSL_CRYPTO_LIB}
            ${OPENSSL_SSL_LIB}
        )
    endif()

    if(ENABLE_MULTITHREADING)
        find_package(OpenMP)
        if(OpenMP_Fortran_FOUND)
            target_link_libraries(mix_libraries PRIVATE OpenMP::OpenMP_Fortran)
        endif()
    endif()

    set_target_properties(mix_libraries PROPERTIES
        BUILD_RPATH "${AOCL_INSTALL_DIR}/lib:${AOCL_INSTALL_DIR}/renamed/lib"
        INSTALL_RPATH "${AOCL_INSTALL_DIR}/lib:${AOCL_INSTALL_DIR}/renamed/lib"
    )

    add_test(NAME mix_libraries
        COMMAND mix_libraries
        WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
    )

    set_tests_properties(mix_libraries PROPERTIES
        ENVIRONMENT "LD_LIBRARY_PATH=${AOCL_INSTALL_DIR}/lib:${AOCL_INSTALL_DIR}/renamed/lib:$ENV{LD_LIBRARY_PATH}"
    )
endif()
