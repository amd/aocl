# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
#
# AOCL-BLAS (BLIS) component -- target-based build (FetchContent + add_subdirectory).
#
# PURPOSE
#   Builds AOCL-BLAS (BLIS) in-tree (no ExternalProject / separate configure) so
#   its compiled OBJECT files go straight into the unified libaocl (via
#   `$<TARGET_OBJECTS>`, not archive merging); BLIS's public headers are staged
#   into the component install. BLIS sits at the bottom of the dependency graph:
#   it has no AOCL dependencies, while LAPACK, Sparse and DA consume its headers.
#
# HOW IT WORKS (step by step)
#   1. Guarded by ENABLE_AOCL_BLAS, so the whole component is opt-in.
#   2. BLAS_PATH points at the BLIS sources under submodules/blis.
#   3. aocl_resolve_component(BLAS) resolves the per-component threading and DTL
#      settings (each may "inherit" the global AOCL values). These drive the
#      OpenMP-vs-sequential variant (`_blas_threading`) and the SONAME stem
#      (`_blas_soname` = blis-mt when threaded, blis otherwise).
#   4. A block() creates an isolated variable/option scope so the BLIS-specific
#      cache settings forced below (BUILD_SHARED_LIBS OFF, BUILD_STATIC_LIBS ON,
#      config family, CBLAS, addons, int size, complex return, TRSM preinversion,
#      DTL, OpenMP) do not leak out and affect the other AOCL components.
#      FetchContent_Declare(SOURCE_DIR=...) + FetchContent_MakeAvailable() then
#      add_subdirectory() the BLIS tree, defining its targets here. The resolved
#      source/binary dirs are cached as AOCL_TB_BLAS_SRC / AOCL_TB_BLAS_BIN.
#   5. AOCL_TB_BLAS_INCLUDE_DIR exposes BLIS's include dirs to downstream AOCL
#      components: the generated flat headers (blis.h / cblas.h) under
#      <bindir>/include/<config-family>, plus the C++ wrappers (blis.hh /
#      cblas.hh) shipped in the source tree under vendor/cpp.
#   6. blis registers its compiled objects for the unified library from inside
#      its patched CMakeLists (aocl_tb_add_objects). aocl_tb_add_whole_lib(
#      blis_static) additionally records the static archive; that record feeds
#      the per-component shared lib (step 8) and install (step 7) -- the unified
#      libaocl itself is built from objects, not from this archive.
#   7. aocl_tb_install_component() stages blis_static and the public headers into
#      the per-component install_package layout. Because blis.h / cblas.h are
#      GENERATED at build time by the flat-header / flat-cblas-header custom
#      targets, those targets are appended to AOCL_TB_DEP_TARGETS so the unified
#      build orders header generation before the install / downstream consumers.
#   8. aocl_tb_emit_shared() (shared builds only) emits the per-component shared
#      library libblis[-mt].so by whole-archiving the static archive.
#   9. aocl_tb_register_manifest() records the chosen config-family, threading and
#      int-size in the embedded build manifest.

if(ENABLE_AOCL_BLAS)
    message(STATUS "[aocl] Configuring AOCL-BLAS (BLIS, FetchContent + add_subdirectory)")

    # Source selection (precedence: local path > submodules > git clone).
    set(BLAS_PATH "" CACHE STRING "Local path of AOCL-BLAS source (parent dir containing 'blis'); overrides submodules/git")
    set(BLAS_GIT_REPOSITORY "https://github.com/amd/blis.git" CACHE STRING "AOCL-BLAS (BLIS) git repository (used when submodules are off and BLAS_PATH is empty)")
    set(BLAS_GIT_TAG "master" CACHE STRING "AOCL-BLAS (BLIS) git branch/tag")

    # Per-component threading / DTL (inherit => identical to the global values).
    aocl_resolve_component(BLAS)
    if(AOCL_BLAS_THREADS_ON)
        set(_blas_threading "openmp")
        set(_blas_soname    "blis-mt")
    else()
        set(_blas_threading "no")
        set(_blas_soname    "blis")
    endif()
    if(AOCL_BLAS_DTL_ON)
        set(_blas_dtl "ALL")
    else()
        set(_blas_dtl "OFF")
    endif()

    # Bring BLIS into this build in an isolated option scope.
    block()
        # Static PIC archive only -- its objects feed libaocl (and /MT on Windows).
        set(BUILD_SHARED_LIBS OFF)
        set(BLIS_CONFIG_FAMILY        "${BLIS_CONFIG_FAMILY}"        CACHE STRING "" FORCE)
        set(ENABLE_CBLAS              ${ENABLE_CBLAS}                CACHE BOOL   "" FORCE)
        set(ENABLE_ADDON             "${ENABLE_ADDON}"              CACHE STRING "" FORCE)
        set(ENABLE_THREADING         "${_blas_threading}"           CACHE STRING "" FORCE)
        set(BLAS_INT_SIZE            "${BLAS_INT_SIZE}"             CACHE STRING "" FORCE)
        set(COMPLEX_RETURN          "${COMPLEX_RETURN}"            CACHE STRING "" FORCE)
        set(ENABLE_TRSM_PREINVERSION ${ENABLE_TRSM_PREINVERSION}    CACHE BOOL   "" FORCE)
        set(ENABLE_AOCL_DTL         "${_blas_dtl}"                 CACHE STRING "" FORCE)
        set(BUILD_STATIC_LIBS        ON                            CACHE BOOL   "" FORCE)
        # Build BLIS with -fvisibility=default so the netlib BLAS/CBLAS symbols
        # (dgemm_, cblas_dgemm, ...) stay exported when merged into libaocl.so.
        # Linux only -- Windows exports via the generated .def.
        if(NOT WIN32)
            set(EXPORT_SHARED "all" CACHE STRING "" FORCE)
        endif()
        if(OpenMP_libomp_LIBRARY)
            set(OpenMP_libomp_LIBRARY "${OpenMP_libomp_LIBRARY}"   CACHE STRING "" FORCE)
        endif()

        aocl_tb_declare_source(aocl_blas BLAS blis)
        FetchContent_MakeAvailable(aocl_blas)

        set(AOCL_TB_BLAS_SRC "${aocl_blas_SOURCE_DIR}" CACHE INTERNAL "")
        set(AOCL_TB_BLAS_BIN "${aocl_blas_BINARY_DIR}" CACHE INTERNAL "")
    endblock()

    # Public include dirs for consumers (LAPACK/Sparse/DA).
    set(AOCL_TB_BLAS_INCLUDE_DIR
        "${AOCL_TB_BLAS_BIN}/include/${BLIS_CONFIG_FAMILY};${AOCL_TB_BLAS_SRC}/vendor/cpp"
        CACHE INTERNAL "AOCL-BLAS include dirs (in-tree build)")

    # Merge the static archive into libaocl.
    aocl_tb_add_whole_lib(blis_static)

    aocl_tb_install_component(blis
        TARGETS     blis_static
        HEADER_DIRS "${AOCL_TB_BLAS_BIN}/include/${BLIS_CONFIG_FAMILY}"
                    "${AOCL_TB_BLAS_SRC}/vendor/cpp")
    if(TARGET flat-header)
        set_property(GLOBAL APPEND PROPERTY AOCL_TB_DEP_TARGETS flat-header)
    endif()
    if(TARGET flat-cblas-header)
        set_property(GLOBAL APPEND PROPERTY AOCL_TB_DEP_TARGETS flat-cblas-header)
    endif()

    # Per-component shared library (shared builds only): libblis[-mt].so.
    aocl_tb_emit_shared(blas blis
        OUTPUT_NAME "${_blas_soname}"
        STATICS     blis_static)

    aocl_tb_register_manifest(blas blis
        "config-family=${BLIS_CONFIG_FAMILY}"
        "threading=${_blas_threading}"
        "int-size=${BLAS_INT_SIZE}")
endif()
