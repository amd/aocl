# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
#
# AOCL-Sparse component -- target-based build (FetchContent + add_subdirectory).
#
# PURPOSE
#   Builds AOCL-Sparse in-tree so its compiled OBJECT files go straight into the
#   unified libaocl (via `$<TARGET_OBJECTS>`, not archive merging). Sparse depends
#   on AOCL-BLAS, AOCL-LAPACK and AOCL-Utils (all already brought in-tree before
#   this file), and in turn exports include dirs consumed by AOCL-DA.
#
# HOW IT WORKS (step by step)
#   1. Guarded by ENABLE_AOCL_SPARSE so the component is opt-in.
#   2. SPARSE_PATH points at the patched sources under
#      submodules/aocl-sparse.
#   3. aocl_resolve_component(SPARSE) resolves the per-component OpenMP flag
#      (`_sparse_omp`, may inherit the global value).
#   4. A block() isolates the forced cache settings (static PIC archive only,
#      ILP64, AVX512 ISA, OpenMP, no samples/benchmarks/tests). FetchContent then
#      add_subdirectory()s the tree; the resolved dirs are cached as
#      AOCL_TB_SPARSE_SRC / AOCL_TB_SPARSE_BIN. Sparse's patched
#      cmake/Dependencies.cmake takes the IN-TREE target branch
#      (if TARGET AOCL::BLAS AND flame AND aoclutils) and reads the
#      parent-exported build-tree include dirs instead of install-path discovery
#      (which would FATAL since deps are not installed at configure time).
#   5. AOCL_TB_SPARSE_INCLUDE_DIR exports the include dirs for DA, including
#      library/src/include (DA's KT_PATH kernel templates) and <bindir>/include
#      (the GENERATED aoclsparse_version.h).
#   6. The generated, flattened BLIS headers are forced to build first
#      (add_dependencies on flat-header / flat-cblas-header) to avoid a
#      parallel-build race on blis.h / cblas.h.
#   7. The unified libaocl is assembled from the component's compiled objects.
#   8. aocl_tb_install_component() stages the lib + public headers.
#   9. aocl_tb_emit_shared() (shared builds only) emits libaoclsparse.so with a
#      runtime dependency on libblis[-mt].so, libflame.so and libaoclutils.so.
#  10. aocl_tb_register_manifest() records int-size and threading.

if(ENABLE_AOCL_SPARSE)
    message(STATUS "[aocl] Configuring AOCL-Sparse (FetchContent + add_subdirectory)")

    # Source selection (precedence: local path > submodules > git clone).
    set(SPARSE_PATH "" CACHE STRING "Local path of AOCL-Sparse source (parent dir containing 'aocl-sparse'); overrides submodules/git")
    set(SPARSE_GIT_REPOSITORY "https://github.com/amd/aocl-sparse.git" CACHE STRING "AOCL-Sparse git repository (used when submodules are off and SPARSE_PATH is empty)")
    set(SPARSE_GIT_TAG "master" CACHE STRING "AOCL-Sparse git branch/tag")

    # Per-component threading (inherit => identical to the global value).
    aocl_resolve_component(SPARSE)
    if(AOCL_SPARSE_THREADS_ON)
        set(_sparse_omp ON)
    else()
        set(_sparse_omp OFF)
    endif()

    block()
        # Static PIC archive only -- its objects feed libaocl (and /MT on Windows).
        set(BUILD_SHARED_LIBS OFF)
        set(BUILD_ILP64               ${ENABLE_ILP64}      CACHE BOOL   "" FORCE)
        set(USE_AVX512                ${SPARSE_ISA_CONFIG} CACHE BOOL   "" FORCE)
        set(SUPPORT_OMP               ${_sparse_omp}       CACHE BOOL   "" FORCE)
        set(BUILD_CLIENTS_SAMPLES     OFF                  CACHE BOOL   "" FORCE)
        set(BUILD_CLIENTS_BENCHMARKS  OFF                  CACHE BOOL   "" FORCE)
        set(BUILD_UNIT_TESTS          OFF                  CACHE BOOL   "" FORCE)
        if(OpenMP_libomp_LIBRARY)
            set(OpenMP_libomp_LIBRARY "${OpenMP_libomp_LIBRARY}" CACHE STRING "" FORCE)
        endif()

        aocl_tb_declare_source(aocl_sparse SPARSE aocl-sparse)
        FetchContent_MakeAvailable(aocl_sparse)

        set(AOCL_TB_SPARSE_SRC "${aocl_sparse_SOURCE_DIR}" CACHE INTERNAL "")
        set(AOCL_TB_SPARSE_BIN "${aocl_sparse_BINARY_DIR}" CACHE INTERNAL "")
    endblock()

    # Public include dirs for consumers (DA). The DA build defaults its
    # kernel-templates path (KT_PATH) to SPARSE_INCLUDE_DIR, so the export also
    # carries library/src/include for DA's `#include "kernel-templates/..."`.
    # aoclsparse_version.h is GENERATED (configure_file) into <bindir>/include,
    # so that directory must be on the export too or DA cannot include aoclsparse.h.
    set(AOCL_TB_SPARSE_INCLUDE_DIR
        "${AOCL_TB_SPARSE_SRC}/library/include;${AOCL_TB_SPARSE_SRC}/library/src/include;${AOCL_TB_SPARSE_BIN}/include"
        CACHE INTERNAL "AOCL-Sparse include dirs (in-tree build)")

    # The static library target is named 'aoclsparse' on both platforms.
    set(_sparse_tgt aoclsparse)

    # aocl-sparse includes the (generated, flattened) BLIS headers; force their
    # generation first to avoid a parallel-build race on blis.h / cblas.h.
    if(TARGET flat-header)
        add_dependencies(${_sparse_tgt} flat-header)
    endif()
    if(TARGET flat-cblas-header)
        add_dependencies(${_sparse_tgt} flat-cblas-header)
    endif()

    aocl_tb_install_component(aocl-sparse
        TARGETS     ${_sparse_tgt}
        HEADER_DIRS "${AOCL_TB_SPARSE_SRC}/library/include"
                    "${AOCL_TB_SPARSE_BIN}/include")

    # Per-component shared library (shared builds only): libaoclsparse.so,
    # recording a normal runtime dependency on libblis[-mt].so, libflame.so and
    # libaoclutils.so.
    if(NOT WIN32)
        set(_sparse_ext gfortran)
    else()
        set(_sparse_ext "")
    endif()
    aocl_tb_emit_shared(sparse aocl-sparse
        OUTPUT_NAME aoclsparse
        STATICS     ${_sparse_tgt}
        SO_DEPS     aoclso_lapack aoclso_blas aoclso_utils
        EXTERNAL    ${_sparse_ext})

    aocl_tb_register_manifest(sparse aocl-sparse
        "int-size=${AOCL_INT_SIZE_EFFECTIVE}"
        "multithreading=${_sparse_omp}")
endif()
