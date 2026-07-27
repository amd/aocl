# Copyright (C) 2025-2026, Advanced Micro Devices, Inc. All rights reserved.
#
# Cross-platform (Windows + Linux) AOCL symbol-rename test harness.
# Builds up to five executables, each in two flavours (original + renamed):
#   * test_original_symbols / test_renamed_symbols          (C, exercises BLAS/LAPACK/SPARSE/LIBM/...)
#   * test_cpp_original_symbols / test_cpp_renamed_symbols  (C++, exercises Utils/Crypto/DA - flat C API)
#   * test_cpp_templates_original / test_cpp_templates_renamed (C++ TEMPLATE interfaces: aoclsparse::mv/trsv<T>, da_handle_init<T>)
#   * mix_libraries / mix_libraries_renamed                 (Fortran, BLAS interop) - Linux only
#                                                            (also Windows when a Fortran compiler is found)

cmake_minimum_required(VERSION 3.15)

# Detect Fortran availability before the project() call so we can list it
# conditionally (avoids a hard configure-failure when no Fortran toolchain
# is on the path).
include(CheckLanguage)
project(aocl_symbol_rename_test C CXX)
check_language(Fortran)
if(CMAKE_Fortran_COMPILER)
    enable_language(Fortran)
    set(_HAS_FORTRAN TRUE)
else()
    set(_HAS_FORTRAN FALSE)
    message(STATUS "Fortran compiler not found - skipping mix_libraries.F90 test")
endif()

# -----------------------------------------------------------------------------
# Discover which AOCL libraries the parent enabled
# -----------------------------------------------------------------------------
set(ENABLED_LIBS "")
foreach(_lib UTILS BLAS LAPACK SPARSE CRYPTO LIBM COMPRESSION DA LIBMEM OPENRNG)
    if(ENABLE_AOCL_${_lib})
        list(APPEND ENABLED_LIBS "${_lib}")
    endif()
endforeach()

if(ENABLED_LIBS)
    message(STATUS "Testing enabled for libraries: ${ENABLED_LIBS}")
else()
    message(WARNING "No AOCL libraries enabled - tests may fail")
endif()

set(AOCL_INSTALL_DIR "${CMAKE_INSTALL_PREFIX}" CACHE PATH "AOCL installation directory")

# Unified library base name. Honour the parent's AOCL_SINGLE_LIBRARY_NAME so the
# tests link/reference exactly the file the unified build produced (aocl.dll/.lib
# and libaocl.so/.a by default, or any custom name). Falls back to "aocl" for a
# standalone test configure where the parent variable is not in scope.
if(NOT DEFINED AOCL_SINGLE_LIBRARY_NAME OR AOCL_SINGLE_LIBRARY_NAME STREQUAL "")
    set(AOCL_SINGLE_LIBRARY_NAME "aocl")
endif()

if(NOT DEFINED SYMBOL_RENAME_PREFIX)
    set(SYMBOL_RENAME_PREFIX "" CACHE STRING "Symbol rename prefix from parent")
endif()

if(SYMBOL_RENAME_PREFIX)
    string(TOLOWER "${SYMBOL_RENAME_PREFIX}" SYMBOL_PREFIX_LOWER)
    string(TOUPPER "${SYMBOL_RENAME_PREFIX}" SYMBOL_PREFIX_UPPER)
    set(BUILD_RENAMED_TEST TRUE)
else()
    set(SYMBOL_PREFIX_LOWER "")
    set(SYMBOL_PREFIX_UPPER "")
    set(BUILD_RENAMED_TEST FALSE)
endif()

if(BUILD_RENAMED_TEST)
    message(STATUS "Building test executables: original + renamed (prefix='${SYMBOL_RENAME_PREFIX}')")
else()
    message(STATUS "Building test executables: original only")
endif()

# -----------------------------------------------------------------------------
# Per-platform helpers
# -----------------------------------------------------------------------------

# Lib-name suffix (.lib/.dll vs .a/.so) and prefix ("" vs "lib")
# On Windows we always link the .lib. The unified build produces the SAME base
# name for both linkages (see aocl_unified.cmake): the static build's deliverable
# is aocl.lib (the STATIC target is named ${PROJECT_NAME}), and the shared build's
# aocl.lib is the import library for aocl.dll. So the canonical link name is
# always ${_ln}.lib:
#   shared : aocl.lib          (import lib for aocl.dll)
#   static : aocl.lib          (the unified static archive -- the deliverable)
#   renamed: aocl.lib          (renamed/ dir - umbrella pruned+renamed to aocl.lib)
# (aocl_static.lib only ever exists as a rename-flow *duplicate* of aocl.lib, so
# it is never the canonical name to link.)
# Prefer probing the on-disk file (robust), but when it is not present yet
# (ENABLE_TESTS=ON on the initial configure, before build+install has created
# install_package/lib) fall back to the deterministic name. This lets the whole
# build run in a SINGLE configure pass: the test targets are EXCLUDE_FROM_ALL
# and only linked after install, by which time the .lib exists on disk.
function(_aocl_resolve_lib_basename _outvar _libdir)
    set(_ln "${AOCL_SINGLE_LIBRARY_NAME}")
    if(WIN32)
        if(EXISTS "${_libdir}/${_ln}.lib")
            set(${_outvar} "${_ln}.lib" PARENT_SCOPE)
        elseif(EXISTS "${_libdir}/${_ln}_static.lib")
            set(${_outvar} "${_ln}_static.lib" PARENT_SCOPE)
        else()
            # Not built yet: the unified deliverable is ${_ln}.lib for BOTH the
            # shared (import lib) and static (archive) linkages.
            set(${_outvar} "${_ln}.lib" PARENT_SCOPE)
        endif()
    else()
        if(BUILD_SHARED_LIBS)
            set(${_outvar} "${CMAKE_SHARED_LIBRARY_PREFIX}${_ln}${CMAKE_SHARED_LIBRARY_SUFFIX}" PARENT_SCOPE)
        else()
            set(${_outvar} "${CMAKE_STATIC_LIBRARY_PREFIX}${_ln}${CMAKE_STATIC_LIBRARY_SUFFIX}" PARENT_SCOPE)
        endif()
    endif()
endfunction()

# System libs the test binaries need at link time.
#
# The BASE OS / C++ runtime libraries are always required (they are not
# third-party deps). The actual third-party runtime (Fortran runtime, OpenMP,
# OpenSSL, ...) is reused verbatim from the per-component list collected while
# composing the unified library -- exactly what the AOCL library was built
# against -- so nothing platform/compiler-specific is hardcoded here. When the
# tests are configured OUTSIDE the unified build (standalone, so that shared list
# is empty), discovery from the environment is used as a fallback.
set(_AOCL_PLATFORM_SYSLIBS "")
if(WIN32)
    list(APPEND _AOCL_PLATFORM_SYSLIBS
        Advapi32.lib Ole32.lib User32.lib Kernel32.lib Ws2_32.lib Shell32.lib)
    # A static AOCL library has C++ objects (Utils/Crypto/DA/Sparse) needing the
    # C++ runtime; link it so the /TC C tests resolve those symbols. Use the
    # STATIC C++ runtime import lib (libcpmt.lib) to match the /MT CRT the AOCL
    # objects are compiled with (CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded, see
    # aocl_targets_common.cmake). Linking the dynamic msvcprt.lib instead makes
    # lld-link fail with "/failifmismatch: RuntimeLibrary MT_StaticRelease vs
    # MD_DynamicRelease" (+ duplicate std::locale symbols). A shared build links
    # only the import lib (no CRT objects), so it needs no explicit C++ runtime.
    if(NOT BUILD_SHARED_LIBS)
        list(APPEND _AOCL_PLATFORM_SYSLIBS libcpmt.lib)
    endif()
else()
    list(APPEND _AOCL_PLATFORM_SYSLIBS m pthread stdc++)
    # If the C++ compiler is a custom GCC install whose libstdc++ provides a
    # newer GLIBCXX than the one on the default loader path, the test binaries
    # must rpath that lib dir. Otherwise libaocl.so (built with that compiler)
    # fails to load with "GLIBCXX_3.4.xx not found". Discover via
    #   `g++ -print-file-name=libstdc++.so`.
    set(_AOCL_GCC_RUNTIME_RPATH "")
    execute_process(
        COMMAND "${CMAKE_CXX_COMPILER}" -print-file-name=libstdc++.so
        OUTPUT_VARIABLE _gxx_libstdcxx
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
    )
    if(_gxx_libstdcxx AND EXISTS "${_gxx_libstdcxx}")
        get_filename_component(_AOCL_GCC_RUNTIME_RPATH "${_gxx_libstdcxx}" DIRECTORY)
        message(STATUS "Test: GCC runtime rpath = ${_AOCL_GCC_RUNTIME_RPATH}")
    endif()
endif()

# Third-party runtime libs -- prefer the shared per-component list (in-tree build).
get_property(_aocl_external_libs GLOBAL PROPERTY AOCL_TB_EXTERNAL_LIBS)
if(_aocl_external_libs)
    list(REMOVE_DUPLICATES _aocl_external_libs)
    list(APPEND _AOCL_PLATFORM_SYSLIBS ${_aocl_external_libs})
    message(STATUS "Test: third-party libs from unified build = ${_aocl_external_libs}")
elseif(WIN32)
    # Standalone fallback: discover the Intel Fortran runtime + OpenSSL.
    if(NOT DEFINED FORTRAN_LIB_DIR OR FORTRAN_LIB_DIR STREQUAL "")
        if(DEFINED ENV{ONEAPI_ROOT} AND IS_DIRECTORY "$ENV{ONEAPI_ROOT}/compiler/latest/lib")
            set(FORTRAN_LIB_DIR "$ENV{ONEAPI_ROOT}/compiler/latest/lib")
        elseif(IS_DIRECTORY "C:/Program Files (x86)/Intel/oneAPI/compiler/latest/lib")
            set(FORTRAN_LIB_DIR "C:/Program Files (x86)/Intel/oneAPI/compiler/latest/lib")
        endif()
    endif()
    if(FORTRAN_LIB_DIR)
        list(APPEND _AOCL_PLATFORM_SYSLIBS
            "${FORTRAN_LIB_DIR}/libifcoremd.lib" "${FORTRAN_LIB_DIR}/libircmd.lib"
            "${FORTRAN_LIB_DIR}/svml_dispmd.lib" "${FORTRAN_LIB_DIR}/ifmodintr.lib"
            "${FORTRAN_LIB_DIR}/libmmd.lib")
    endif()
    if(NOT DEFINED OPENSSL_CRYPTO_LIB OR OPENSSL_CRYPTO_LIB STREQUAL "")
        if(DEFINED OPENSSL_INSTALL_DIR AND EXISTS "${OPENSSL_INSTALL_DIR}/lib/libcrypto.lib")
            set(OPENSSL_CRYPTO_LIB "${OPENSSL_INSTALL_DIR}/lib/libcrypto.lib")
        elseif(DEFINED ENV{OPENSSL_INSTALL_DIR} AND EXISTS "$ENV{OPENSSL_INSTALL_DIR}/lib/libcrypto.lib")
            set(OPENSSL_CRYPTO_LIB "$ENV{OPENSSL_INSTALL_DIR}/lib/libcrypto.lib")
        elseif(EXISTS "C:/Program Files/OpenSSL-Win64/lib/libcrypto.lib")
            set(OPENSSL_CRYPTO_LIB "C:/Program Files/OpenSSL-Win64/lib/libcrypto.lib")
        endif()
    endif()
    if(OPENSSL_CRYPTO_LIB)
        list(APPEND _AOCL_PLATFORM_SYSLIBS "${OPENSSL_CRYPTO_LIB}")
    endif()
else()
    # Standalone fallback (POSIX): classic GCC runtime + optional OpenSSL.
    list(APPEND _AOCL_PLATFORM_SYSLIBS gfortran quadmath)
    if(ENABLE_AOCL_CRYPTO)
        list(APPEND _AOCL_PLATFORM_SYSLIBS crypto ssl)
    endif()
endif()

# OpenMP runtime -- resolved automatically when multithreading is enabled (kept
# out of the collected per-component list, matching the unified link and the
# renamed re-link). find_package(OpenMP) on POSIX; the Intel OpenMP import lib
# on Windows.
if(ENABLE_MULTITHREADING)
    if(WIN32)
        set(_omp_dir "${AOCL_TB_FORTRAN_LIBDIR}")
        if(NOT _omp_dir AND DEFINED FORTRAN_LIB_DIR)
            set(_omp_dir "${FORTRAN_LIB_DIR}")
        endif()
        if(_omp_dir AND EXISTS "${_omp_dir}/libiomp5md.lib")
            list(APPEND _AOCL_PLATFORM_SYSLIBS "${_omp_dir}/libiomp5md.lib")
        endif()
    else()
        find_package(OpenMP QUIET)
        if(OpenMP_C_FOUND)
            list(APPEND _AOCL_PLATFORM_SYSLIBS OpenMP::OpenMP_C)
        endif()
    endif()
endif()

# Helper: return the env var that the test binary needs so it can find the
# AOCL shared library at runtime (PATH on Windows, LD_LIBRARY_PATH on Linux).
function(_aocl_test_env_var _outvar _libdir)
    if(WIN32)
        set(${_outvar} "PATH=${_libdir};$ENV{PATH}" PARENT_SCOPE)
    else()
        # Include the GCC runtime dir (when CMAKE_CXX_COMPILER lives in a
        # custom toolchain) so the loader finds a libstdc++ with the
        # GLIBCXX/CXXABI versions libaocl.so was built against.
        set(_libpath "${_libdir}")
        if(_AOCL_GCC_RUNTIME_RPATH)
            set(_libpath "${_libdir}:${_AOCL_GCC_RUNTIME_RPATH}")
        endif()
        set(${_outvar} "LD_LIBRARY_PATH=${_libpath}:$ENV{LD_LIBRARY_PATH}" PARENT_SCOPE)
    endif()
endfunction()

# Helper: per-library compile defines. Avoids 9x duplication.
function(_aocl_apply_lib_defines _target)
    foreach(_lib BLAS LAPACK SPARSE LIBM COMPRESSION CRYPTO DA LIBMEM OPENRNG UTILS)
        if(ENABLE_AOCL_${_lib})
            target_compile_definitions(${_target} PRIVATE ENABLE_${_lib})
        endif()
    endforeach()
    # ILP64 integer width. The DA and Sparse public headers select their integer
    # type (da_int / aoclsparse_int = int64_t vs int32_t) from these macros. The
    # libraries are built ILP64, so every test TU that calls them MUST define the
    # same macros -- otherwise da_int/aoclsparse_int are 32-bit in the test while
    # the library expects 64-bit. On Windows x64 the mismatched stack-passed
    # arguments are then read with garbage high bits (e.g.
    # da_interpolation_set_values' order/ldy_data), yielding a spurious
    # da_status_invalid_input. (Linux passes those args in registers, which
    # zero-extend, so the mismatch is silently harmless there.)
    if(ENABLE_ILP64)
        if(ENABLE_AOCL_DA)
            target_compile_definitions(${_target} PRIVATE AOCLDA_ILP64)
        endif()
        if(ENABLE_AOCL_SPARSE)
            target_compile_definitions(${_target} PRIVATE aoclsparse_ILP64)
        endif()
    endif()
endfunction()

# Helper: declare one C/C++ test executable (original-or-renamed).
#   _name        : target name (e.g. test_original_symbols)
#   _src         : source file
#   _renamed     : TRUE for renamed-mode (uses renamed/{include,lib})
#   _is_cpp      : TRUE for C++ executable
function(_aocl_add_test_executable _name _src _renamed _is_cpp)
    add_executable(${_name} EXCLUDE_FROM_ALL ${_src})
    if(TARGET ${AOCL_SINGLE_LIBRARY_NAME})
        add_dependencies(${_name} ${AOCL_SINGLE_LIBRARY_NAME})
    endif()

    if(_renamed)
        set(_inc_dir "${AOCL_INSTALL_DIR}/renamed/include")
        set(_lib_dir "${AOCL_INSTALL_DIR}/renamed/lib")
    else()
        set(_inc_dir "${AOCL_INSTALL_DIR}/include")
        set(_lib_dir "${AOCL_INSTALL_DIR}/lib")
    endif()

    target_include_directories(${_name} PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}
        ${_inc_dir}
    )

    if(_renamed)
        target_compile_definitions(${_name} PRIVATE
            USE_RENAMED_SYMBOLS
            SYMBOL_PREFIX_TOKEN_LOWER=${SYMBOL_PREFIX_LOWER}
            SYMBOL_PREFIX_TOKEN_UPPER=${SYMBOL_PREFIX_UPPER}
            SYMBOL_PREFIX_STR="${SYMBOL_PREFIX_LOWER}"
        )
    else()
        target_compile_definitions(${_name} PRIVATE SYMBOL_PREFIX_STR="")
    endif()

    _aocl_apply_lib_defines(${_name})

    _aocl_resolve_lib_basename(_aocl_lib_base "${_lib_dir}")
    target_link_libraries(${_name} PRIVATE
        "${_lib_dir}/${_aocl_lib_base}"
        ${_AOCL_PLATFORM_SYSLIBS}
    )

    # Put the Intel Fortran runtime dir on this C/C++ target's link search path so
    # the bare-name /DEFAULTLIB directives embedded in a STATIC AOCL library's
    # Fortran objects resolve under the Visual Studio generator (which does not
    # inherit the oneAPI LIB env). Emitted as a raw /LIBPATH: option -- see the note
    # at the top of this file: link_directories() would be mangled into the ifx
    # linker-wrapper form "/Qoption,link,/LIBPATH:..." that lld-link cannot parse.
    if(WIN32 AND AOCL_TB_FORTRAN_LIBDIR)
        target_link_options(${_name} PRIVATE "/LIBPATH:${AOCL_TB_FORTRAN_LIBDIR}")
    endif()

    if(ENABLE_MULTITHREADING)
        find_package(OpenMP)
        if(_is_cpp AND OpenMP_CXX_FOUND)
            target_link_libraries(${_name} PRIVATE OpenMP::OpenMP_CXX)
        elseif(NOT _is_cpp AND OpenMP_C_FOUND)
            target_link_libraries(${_name} PRIVATE OpenMP::OpenMP_C)
        endif()
    endif()

    # Build per-target rpath: AOCL lib dir + (Linux only) the GCC runtime dir
    # so the test binary picks up the libstdc++ that matches what libaocl.so
    # was linked against.
    set(_target_rpath "${_lib_dir}")
    if(UNIX AND _AOCL_GCC_RUNTIME_RPATH)
        list(APPEND _target_rpath "${_AOCL_GCC_RUNTIME_RPATH}")
    endif()

    if(_is_cpp)
        set_target_properties(${_name} PROPERTIES
            CXX_STANDARD 17
            CXX_STANDARD_REQUIRED ON
            BUILD_RPATH   "${_target_rpath}"
            INSTALL_RPATH "${_target_rpath}"
        )
    else()
        set_target_properties(${_name} PROPERTIES
            C_STANDARD 99
            C_STANDARD_REQUIRED ON
            BUILD_RPATH   "${_target_rpath}"
            INSTALL_RPATH "${_target_rpath}"
        )
    endif()

    # On Windows, force C-mode (clang-cl /TC) so <complex.h> & friends compile.
    if(WIN32 AND NOT _is_cpp)
        target_compile_options(${_name} PRIVATE /TC)
    endif()
endfunction()

# Helper: register one CTest test with the right runtime env var.
function(_aocl_register_test _name _libdir)
    add_test(NAME ${_name} COMMAND ${_name} WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR})
    if(WIN32)
        # Prepend the AOCL lib dir to the *inherited* PATH (which already
        # carries the oneAPI runtime dirs needed by aocl.dll's dependencies:
        # libiomp5md.dll, svml_dispmd.dll, libifcoremd.dll, ...). Using
        # ENVIRONMENT_MODIFICATION's path_list_prepend augments the existing
        # PATH instead of overwriting it. Plain ENVIRONMENT="PATH=a;b;c" would
        # be mis-parsed: CTest treats ';' as a list separator, collapsing the
        # value to its first directory and causing 0xC0000135
        # (STATUS_DLL_NOT_FOUND) at test runtime.
        set_tests_properties(${_name} PROPERTIES
            ENVIRONMENT_MODIFICATION "PATH=path_list_prepend:${_libdir}")
    else()
        _aocl_test_env_var(_envstr "${_libdir}")
        set_tests_properties(${_name} PROPERTIES ENVIRONMENT "${_envstr}")
    endif()
endfunction()

# -----------------------------------------------------------------------------
# C tests : test_aocl_symbols.c
# -----------------------------------------------------------------------------
_aocl_add_test_executable(test_original_symbols test_aocl_symbols.c FALSE FALSE)
_aocl_register_test(test_original_symbols "${AOCL_INSTALL_DIR}/lib")

if(BUILD_RENAMED_TEST)
    _aocl_add_test_executable(test_renamed_symbols test_aocl_symbols.c TRUE FALSE)
    _aocl_register_test(test_renamed_symbols "${AOCL_INSTALL_DIR}/renamed/lib")
endif()

# -----------------------------------------------------------------------------
# C++ tests : test_aocl_cpp.cpp  (only when Utils/Crypto/DA enabled)
# -----------------------------------------------------------------------------
if(ENABLE_AOCL_UTILS OR ENABLE_AOCL_CRYPTO OR ENABLE_AOCL_DA)
    _aocl_add_test_executable(test_cpp_original_symbols test_aocl_cpp.cpp FALSE TRUE)
    _aocl_register_test(test_cpp_original_symbols "${AOCL_INSTALL_DIR}/lib")

    if(BUILD_RENAMED_TEST)
        _aocl_add_test_executable(test_cpp_renamed_symbols test_aocl_cpp.cpp TRUE TRUE)
        _aocl_register_test(test_cpp_renamed_symbols "${AOCL_INSTALL_DIR}/renamed/lib")
    endif()
else()
    message(STATUS "Skipping C++ tests: enable at least one of UTILS / CRYPTO / DA")
endif()

# -----------------------------------------------------------------------------
# C++ template-interface tests : test_aocl_cpp_templates.cpp
#   Exercises the REAL C++ template interfaces (aoclsparse::mv/trsv<T> from
#   aoclsparse.hpp, da_handle_init<T> from aoclda.hpp) so the linker must
#   resolve the C++ *template* instantiation symbols - not just the flat
#   extern "C" API. Guards the DA/sparse "templated function" rename path that
#   the reviewer flagged, and complements test_aocl_cpp.cpp (C-API-from-C++).
# -----------------------------------------------------------------------------
if(ENABLE_AOCL_SPARSE OR ENABLE_AOCL_DA)
    _aocl_add_test_executable(test_cpp_templates_original test_aocl_cpp_templates.cpp FALSE TRUE)
    _aocl_register_test(test_cpp_templates_original "${AOCL_INSTALL_DIR}/lib")

    if(BUILD_RENAMED_TEST)
        _aocl_add_test_executable(test_cpp_templates_renamed test_aocl_cpp_templates.cpp TRUE TRUE)
        _aocl_register_test(test_cpp_templates_renamed "${AOCL_INSTALL_DIR}/renamed/lib")
    endif()
else()
    message(STATUS "Skipping C++ template tests: enable SPARSE or DA")
endif()

# -----------------------------------------------------------------------------
# Fortran test : mix_libraries.F90  (only when Fortran compiler present + BLAS)
# -----------------------------------------------------------------------------
# Builds the original and (when a prefix is configured) renamed Fortran BLAS-interop
# executables from one source. The renamed flavour links renamed/lib and gets the
# prefixed symbol names from CMake, so it adapts to any prefix.
function(_aocl_add_mix_libraries _name _renamed)
    if(_renamed)
        set(_lib_dir "${AOCL_INSTALL_DIR}/renamed/lib")
    else()
        set(_lib_dir "${AOCL_INSTALL_DIR}/lib")
    endif()

    add_executable(${_name} EXCLUDE_FROM_ALL mix_libraries.F90)
    # mix_libraries.F90 uses C-preprocessor guards (#ifdef USE_RENAMED_SYMBOLS).
    # Single-config generators (Ninja/Makefiles) auto-preprocess the .F90 via the
    # compiler, but the Visual Studio generator's Intel Fortran (.vfproj)
    # integration does NOT enable preprocessing from the extension alone -> the
    # #ifdef guards are ignored and BOTH the original and renamed code paths
    # compile, pulling in undefined <prefix>dgemm/<prefix>bli_* symbols. Force
    # preprocessing explicitly so the guards are honoured under every generator.
    set_target_properties(${_name} PROPERTIES Fortran_PREPROCESS ON)

    # Renamed flavour: enable the #ifdef path and pass the prefixed external names
    # as object-like macros (plain substitution, not ## pasting: gfortran's
    # traditional cpp ignores ##).
    if(_renamed)
        target_compile_definitions(${_name} PRIVATE
            USE_RENAMED_SYMBOLS
            RENAMED_PREFIX=${SYMBOL_PREFIX_LOWER}
            RENAMED_LSAME=${SYMBOL_PREFIX_LOWER}lsame
            RENAMED_DGEMM=${SYMBOL_PREFIX_LOWER}dgemm
            RENAMED_BLI_NTHREADS=${SYMBOL_PREFIX_LOWER}bli_thread_get_num_threads
        )
    endif()

    if(TARGET ${AOCL_SINGLE_LIBRARY_NAME})
        add_dependencies(${_name} ${AOCL_SINGLE_LIBRARY_NAME})
    endif()
    # Intel Fortran (ifx) on Windows defaults to /names:uppercase, so external
    # references become e.g. DGEMM / BLI_THREAD_GET_NUM_THREADS. The aggregate
    # AOCL library exports the BLAS interfaces in several decorations (DGEMM,
    # dgemm, dgemm_) but the native BLIS C API (bli_thread_get_num_threads) is
    # only available lowercase. Force lowercase name decoration so every
    # external (lsame, dgemm, bli_thread_get_num_threads, omp_*) resolves.
    if(WIN32 AND CMAKE_Fortran_COMPILER_ID MATCHES "Intel")
        # /names:lowercase: ifx defaults to uppercase external decoration, but the
        # aggregate library exports the BLIS C API lowercase; force lowercase so
        # every external (lsame, dgemm, bli_thread_get_num_threads, omp_*) resolves.
        # /MD: select the DYNAMIC Intel Fortran runtime (libifcoremd/libircmd) so
        # ifx does not ALSO auto-link the static libifcoremt/libircmt. The test
        # links the dynamic runtime import libs explicitly (_AOCL_PLATFORM_SYSLIBS),
        # and mixing static+dynamic Fortran runtimes causes LNK2005 duplicate
        # symbols (for_set_fpe_, for_alloc_allocatable_handle, ...).
        target_compile_options(${_name} PRIVATE /names:lowercase /MD)
    endif()
    # ILP64: the AOCL BLAS Fortran (F77) interface uses 8-byte integers, so the
    # test must pass 8-byte default INTEGERs to dgemm (m, n, k, lda, ldb, ldc).
    # With the default 4-byte INTEGER the callee dereferences 8 bytes per arg and
    # reads adjacent stack garbage -> corrupt leading dimensions -> SEGFAULT
    # (observed on Linux/gfortran; latent on Windows where the extra bytes
    # happened to be zero).
    if(ENABLE_ILP64)
        if(CMAKE_Fortran_COMPILER_ID MATCHES "Intel")
            target_compile_options(${_name} PRIVATE -i8)
        else()
            target_compile_options(${_name} PRIVATE -fdefault-integer-8)
        endif()
    endif()
    _aocl_resolve_lib_basename(_aocl_lib_base "${_lib_dir}")
    target_link_libraries(${_name} PRIVATE
        "${_lib_dir}/${_aocl_lib_base}"
        ${_AOCL_PLATFORM_SYSLIBS}
    )
    set(_mix_rpath "${_lib_dir}")
    if(UNIX AND _AOCL_GCC_RUNTIME_RPATH)
        list(APPEND _mix_rpath "${_AOCL_GCC_RUNTIME_RPATH}")
    endif()
    set_target_properties(${_name} PROPERTIES
        BUILD_RPATH   "${_mix_rpath}"
        INSTALL_RPATH "${_mix_rpath}"
    )
    # Both gfortran and ifx auto-preprocess .F90 files; no extra flag needed.
    _aocl_register_test(${_name} "${_lib_dir}")
endfunction()

if(_HAS_FORTRAN AND ENABLE_AOCL_BLAS)
    _aocl_add_mix_libraries(mix_libraries FALSE)
    if(BUILD_RENAMED_TEST)
        _aocl_add_mix_libraries(mix_libraries_renamed TRUE)
    endif()
endif()

# -----------------------------------------------------------------------------
# Python unit-tests for the rename logic itself (cross-platform)
# -----------------------------------------------------------------------------
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
    message(WARNING "Python3 interpreter not found - skipping test_rename_symbols_cpp")
endif()
