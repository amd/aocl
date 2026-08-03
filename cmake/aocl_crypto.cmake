# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
#
# AOCL-Crypto (ALCP) component -- target-based build (FetchContent +
# add_subdirectory).
#
# PURPOSE
#   Builds AOCL-Crypto (ALCP) in-tree so its compiled OBJECT files go straight
#   into the unified libaocl (via `$<TARGET_OBJECTS>`, not archive merging). The
#   per-component install_package carries the synthesized libalcp.{so,dll}.
#
# DEPENDENCIES
#   * AOCL-Utils (CPUID dispatch): consumed as an IN-TREE target. ALCP's patched
#     cmake/modules/AoclUtils.cmake links the in-tree `aoclutils` target directly
#     when present (no staged install layout required). The root auto-enables
#     Utils with Crypto.
#   * OpenSSL (libcrypto): the crypto core hard-depends on it; OPENSSL_INSTALL_DIR
#     must point at an OpenSSL install (include/openssl/*.h + lib{,64}/libcrypto.*).
#   * 7-Zip: ALCP's root unconditionally calls check_7zip_installed() (FATAL if
#     missing) for an off-by-default combined static lib; we pre-seed 7_ZIP to
#     bypass it.
#
# HOW IT WORKS (step by step)
#   1. Guarded by ENABLE_AOCL_CRYPTO so the component is opt-in.
#   2. OpenSSL is resolved FIRST (FATAL if headers/lib missing): the libcrypto
#      import lib (Windows) or libcrypto.so (Unix) is located and added to the
#      unified link. On Windows ALCP's SystemRng uses BCryptGenRandom, so
#      bcrypt.lib is also added.
#   3. CRYPTO_PATH points at the sources under submodules/aocl-crypto;
#      aocl_resolve_component(CRYPTO) resolves DTL logging (`_alcp_dtl`).
#   4. A block() isolates the forced cache settings (static PIC archive only,
#      in-tree Utils, OpenSSL path, 7z bypass, DTL). FetchContent then
#      add_subdirectory()s the tree and the resolved dirs are cached.
#   5. The component's OBJECT files are included in libaocl, its public
#      headers + synthesized libalcp.{so,dll} are staged into the per-component
#      install_package, and the component is recorded in the build manifest
#      (see the remainder of this file).

if(ENABLE_AOCL_CRYPTO)
    message(STATUS "[aocl] Configuring AOCL-Crypto (ALCP, FetchContent + add_subdirectory)")

    # Honour a bare `export OPENSSL_INSTALL_DIR` (no preset), matching AOCL-DA's
    # BOOST_ROOT; an explicit -DOPENSSL_INSTALL_DIR still wins.
    if(NOT OPENSSL_INSTALL_DIR AND DEFINED ENV{OPENSSL_INSTALL_DIR})
        set(OPENSSL_INSTALL_DIR "$ENV{OPENSSL_INSTALL_DIR}")
    endif()

    # --- OpenSSL (hard dependency of the crypto core) ---------------------
    if(NOT OPENSSL_INSTALL_DIR OR NOT EXISTS "${OPENSSL_INSTALL_DIR}/include/openssl/bn.h")
        message(FATAL_ERROR
            "[aocl] AOCL-Crypto requires OpenSSL development headers + library. "
            "Set -DOPENSSL_INSTALL_DIR=<dir> to an OpenSSL install containing "
            "include/openssl/bn.h and lib{,64}/libcrypto.so "
            "(current OPENSSL_INSTALL_DIR='${OPENSSL_INSTALL_DIR}').")
    endif()
    if(WIN32)
        # On Windows OpenSSL ships an import library (libcrypto.lib) alongside
        # the runtime DLL; link the import lib into the unified library.
        if(EXISTS "${OPENSSL_INSTALL_DIR}/lib/libcrypto.lib")
            set(_alcp_ossl_crypto "${OPENSSL_INSTALL_DIR}/lib/libcrypto.lib")
        elseif(EXISTS "${OPENSSL_INSTALL_DIR}/lib64/libcrypto.lib")
            set(_alcp_ossl_crypto "${OPENSSL_INSTALL_DIR}/lib64/libcrypto.lib")
        else()
            message(FATAL_ERROR "[aocl] libcrypto.lib not found under "
                "'${OPENSSL_INSTALL_DIR}/lib' or '${OPENSSL_INSTALL_DIR}/lib64'")
        endif()
    elseif(EXISTS "${OPENSSL_INSTALL_DIR}/lib64/libcrypto.so")
        set(_alcp_ossl_crypto "${OPENSSL_INSTALL_DIR}/lib64/libcrypto.so")
    elseif(EXISTS "${OPENSSL_INSTALL_DIR}/lib/libcrypto.so")
        set(_alcp_ossl_crypto "${OPENSSL_INSTALL_DIR}/lib/libcrypto.so")
    else()
        message(FATAL_ERROR "[aocl] libcrypto.so not found under "
            "'${OPENSSL_INSTALL_DIR}/lib64' or '${OPENSSL_INSTALL_DIR}/lib'")
    endif()
    message(STATUS "[aocl] AOCL-Crypto using OpenSSL at ${OPENSSL_INSTALL_DIR} (${_alcp_ossl_crypto})")

    # On Windows ALCP's SystemRng uses the CNG API (BCryptGenRandom), which
    # lives in bcrypt.dll; the synthesized link needs its import library.
    set(_alcp_extra_libs "${_alcp_ossl_crypto}" ${CMAKE_DL_LIBS})
    if(WIN32)
        list(APPEND _alcp_extra_libs "bcrypt.lib")
    endif()

    # Source selection (precedence: local path > submodules > git clone).
    set(CRYPTO_PATH "" CACHE STRING "Local path of AOCL-Crypto source (parent dir containing 'aocl-crypto'); overrides submodules/git")
    set(CRYPTO_GIT_REPOSITORY "https://github.com/amd/aocl-crypto.git" CACHE STRING "AOCL-Crypto git repository (used when submodules are off and CRYPTO_PATH is empty)")
    set(CRYPTO_GIT_TAG "main" CACHE STRING "AOCL-Crypto git branch/tag")

    # Per-component DTL (ALCP exposes ALCP_ENABLE_DEBUG_LOGGING).
    aocl_resolve_component(CRYPTO)
    if(AOCL_CRYPTO_DTL_ON)
        set(_alcp_dtl ON)
    else()
        set(_alcp_dtl OFF)
    endif()

    block()
        # Static PIC archive only -- its objects feed libaocl (and /MT on Windows).
        set(BUILD_SHARED_LIBS OFF)
        set(CMAKE_INSTALL_LIBDIR "lib"           CACHE STRING   "" FORCE)
        set(ENABLE_AOCL_UTILS    ON              CACHE BOOL     "" FORCE)
        set(OPENSSL_INSTALL_DIR  "${OPENSSL_INSTALL_DIR}" CACHE STRING "" FORCE)
        set(7_ZIP                "${CMAKE_COMMAND}" CACHE FILEPATH "" FORCE)
        set(ALCP_ENABLE_DEBUG_LOGGING ${_alcp_dtl} CACHE BOOL  "" FORCE)
        set(ALCP_ENABLE_EXAMPLES OFF             CACHE BOOL     "" FORCE)
        set(ALCP_ENABLE_TESTS    OFF             CACHE BOOL     "" FORCE)
        set(ALCP_ENABLE_BENCH    OFF             CACHE BOOL     "" FORCE)
        set(ALCP_ENABLE_HTML     OFF             CACHE BOOL     "" FORCE)
        set(ALCP_ENABLE_FUZZ_TESTS OFF           CACHE BOOL     "" FORCE)
        set(ALCP_INSTALL_COMBINED_STATIC OFF     CACHE BOOL     "" FORCE)
        set(ENABLE_TESTS_OPENSSL_API OFF         CACHE BOOL     "" FORCE)
        set(ENABLE_TESTS_IPP_API OFF             CACHE BOOL     "" FORCE)
        if(OpenMP_libomp_LIBRARY)
            set(OpenMP_libomp_LIBRARY "${OpenMP_libomp_LIBRARY}" CACHE STRING "" FORCE)
        endif()

        aocl_tb_declare_source(aocl_crypto CRYPTO aocl-crypto)
        FetchContent_MakeAvailable(aocl_crypto)

        set(AOCL_TB_CRYPTO_SRC "${aocl_crypto_SOURCE_DIR}" CACHE INTERNAL "")
        set(AOCL_TB_CRYPTO_BIN "${aocl_crypto_BINARY_DIR}" CACHE INTERNAL "")
    endblock()

    set(_alcp_tgt alcp_static)

    aocl_tb_install_component(aocl-crypto
        TARGETS     ${_alcp_tgt}
        HEADER_DIRS "${AOCL_TB_CRYPTO_SRC}/include")

    aocl_tb_emit_shared(crypto aocl-crypto
        OUTPUT_NAME alcp
        STATICS     ${_alcp_tgt}
        SO_DEPS     aoclso_utils
        EXTERNAL    ${_alcp_extra_libs})

    # The unified libaocl whole-archives alcp_static, which references OpenSSL
    # (libcrypto) and, on Windows, bcrypt + dl. Unlike the Intel Fortran runtime
    # (auto-resolved via embedded default-lib directives + the oneAPI LIBPATH),
    # these have no auto-link directive, so every step that links the aggregate
    # (unified library, renamed re-link, tests) must be told about them. Register
    # AOCL-Crypto's own third-party libs into the shared external-deps list.
    aocl_tb_add_external_libs(${_alcp_extra_libs})

    aocl_tb_register_manifest(crypto aocl-crypto
        "debug_logging=${_alcp_dtl}")
endif()
