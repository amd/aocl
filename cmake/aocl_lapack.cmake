# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
#
# AOCL-LAPACK / libflame component -- target-based build (FetchContent +
# add_subdirectory).
#
# PURPOSE
#   Builds AOCL-LAPACK (libflame) in-tree so its compiled OBJECT files go straight
#   into the unified libaocl (via `$<TARGET_OBJECTS>`, not archive merging).
#   LAPACK sits on top of AOCL-BLAS and AOCL-Utils (both brought in-tree before
#   this file) and is itself consumed by Sparse and DA.
#
# HOW IT WORKS (step by step)
#   1. Guarded by ENABLE_AOCL_LAPACK so the component is opt-in.
#   2. LAPACK_PATH points at the patched sources under
#      submodules/libflame.
#   3. aocl_resolve_component(LAPACK) resolves per-component multithreading
#      (`_lapack_mt`) and DTL (`_lapack_dtl`).
#   4. On Windows, libflame derives its output name from the BLAS lib name, so
#      the in-tree BLIS static target's real .lib name is supplied via
#      EXT_BLAS_LIBNAME.
#   5. A block() isolates the forced cache settings: static PIC archive only;
#      it consumes AOCL-BLAS via the in-tree target (the patched CMakeLists does
#      if(TARGET AOCL::BLAS) set(BLAS_LIBRARY AOCL::BLAS)) and AOCL-Utils via
#      LIBAOCLUTILS_INCLUDE_PATH. ENABLE_EMBED_AOCLUTILS OFF keeps the archive
#      free of duplicate Utils symbols at the final merge. FetchContent then
#      add_subdirectory()s the tree; dirs cached as AOCL_TB_LAPACK_SRC/_BIN.
#   6. The target name is normalized: on Windows an ALIAS `flame` is added so
#      Sparse/DA can reference the canonical name. libflame's PUBLIC_HEADER set is
#      left intact and read by aocl_tb_install_component to stage the public headers.
#   7. The generated BLIS headers (flat-header / flat-cblas-header) are forced to
#      build first. Because libflame splits its sources across many internal
#      OBJECT libraries, add_dependencies on the aggregate is not enough under
#      the Unix Makefiles generator -- aocl_tb_force_target_deps_recursive walks
#      the whole directory subtree and attaches the dependency to every compiled
#      target (fixes a 'blis.h not found' race).
#   8. AOCL_TB_LAPACK_INCLUDE_DIR exports include dirs for consumers. On Unix
#      libgfortran is added to the link libs (f2c-translated objects); on Windows
#      the Intel Fortran runtime is resolved by aocl_unified.cmake.
#   9. The unified libaocl is assembled from libflame's compiled objects.
#  10. aocl_tb_install_component() stages the lib + headers; aocl_tb_emit_shared()
#      (shared builds only) emits libflame.so with runtime deps on libblis[-mt].so
#      and libaoclutils.so; aocl_tb_register_manifest() records int-size + MT.

if(ENABLE_AOCL_LAPACK)
    message(STATUS "[aocl] Configuring AOCL-LAPACK (libflame, FetchContent + add_subdirectory)")

    # Source selection (precedence: local path > submodules > git clone).
    set(LAPACK_PATH "" CACHE STRING "Local path of AOCL-LAPACK source (parent dir containing 'libflame'); overrides submodules/git")
    set(LAPACK_GIT_REPOSITORY "https://github.com/amd/libflame.git" CACHE STRING "AOCL-LAPACK (libflame) git repository (used when submodules are off and LAPACK_PATH is empty)")
    set(LAPACK_GIT_TAG "master" CACHE STRING "AOCL-LAPACK (libflame) git branch/tag")

    # Per-component threading / DTL (inherit => identical to the global values).
    aocl_resolve_component(LAPACK)
    if(AOCL_LAPACK_THREADS_ON)
        set(_lapack_mt ON)
    else()
        set(_lapack_mt OFF)
    endif()
    if(AOCL_LAPACK_DTL_ON)
        set(_lapack_dtl "ALL")
    else()
        set(_lapack_dtl "OFF")
    endif()

    # Windows: libflame derives its own output name from the BLAS library name
    # (LibBlis -> LibFlame). Supply the in-tree BLIS static target's real name.
    set(_ext_blas_libname "")
    if(WIN32 AND TARGET blis_static)
        get_target_property(_blis_out blis_static OUTPUT_NAME)
        if(NOT _blis_out)
            set(_blis_out "AOCL-LibBlis-Win")
        endif()
        set(_ext_blas_libname "${_blis_out}.lib")
    endif()

    block()
        # Static PIC archive only -- its objects feed libaocl (and /MT on Windows).
        set(BUILD_SHARED_LIBS OFF)
        # libflame's ENABLE_AOCL_BLAS ("couple LAPACK to AOCL-BLAS") is a different
        # knob from the BIY ENABLE_AOCL_BLAS ("include BLAS in libaocl"). Feed it as
        # a block-scoped NORMAL var, not a cache FORCE: an inherited normal var would
        # shadow a cache value (so FORCE never reaches libflame) and the cache write
        # would clobber the top-level option. libflame's CMP0077 NEW honours this var.
        set(ENABLE_AOCL_BLAS         ${ENABLE_AOCL_LAPACK_BLAS_COUPLING})
        set(ENABLE_EMBED_AOCLUTILS   OFF                         CACHE BOOL   "" FORCE)
        set(LIBAOCLUTILS_INCLUDE_PATH "${AOCL_TB_UTILS_INCLUDE_DIR}" CACHE STRING "" FORCE)
        set(ENABLE_MULTITHREADING    ${_lapack_mt}               CACHE BOOL   "" FORCE)
        set(ENABLE_AOCL_DTL         "${_lapack_dtl}"             CACHE STRING "" FORCE)
        set(ENABLE_ILP64             ${ENABLE_ILP64}             CACHE BOOL   "" FORCE)
        set(ENABLE_BLAS_EXT_GEMMT    ${ENABLE_BLAS_EXT_GEMMT}    CACHE BOOL   "" FORCE)
        set(ENABLE_TRSM_PREINVERSION ${ENABLE_TRSM_PREINVERSION} CACHE BOOL   "" FORCE)
        set(ENABLE_AMD_FLAGS         ${ENABLE_AMD_FLAGS}         CACHE BOOL   "" FORCE)
        set(ENABLE_AMD_AOCC_FLAGS    ${ENABLE_AMD_AOCC_FLAGS}    CACHE BOOL   "" FORCE)
        set(LF_ISA_CONFIG           "${LF_ISA_CONFIG}"           CACHE STRING "" FORCE)
        set(COMPLEX_RETURN          "${COMPLEX_RETURN}"          CACHE STRING "" FORCE)
        if(_ext_blas_libname)
            set(EXT_BLAS_LIBNAME "${_ext_blas_libname}"          CACHE STRING "" FORCE)
        endif()
        if(OpenMP_libomp_LIBRARY)
            set(OpenMP_libomp_LIBRARY "${OpenMP_libomp_LIBRARY}" CACHE STRING "" FORCE)
        endif()

        aocl_tb_declare_source(aocl_lapack LAPACK libflame)
        FetchContent_MakeAvailable(aocl_lapack)

        set(AOCL_TB_LAPACK_SRC "${aocl_lapack_SOURCE_DIR}" CACHE INTERNAL "")
        set(AOCL_TB_LAPACK_BIN "${aocl_lapack_BINARY_DIR}" CACHE INTERNAL "")
    endblock()

    # Platform-dependent target name.
    if(WIN32)
        set(_lapack_tgt AOCL-LibFLAME-Win)
        # Consuming components (sparse/DA) reference the canonical 'flame' name;
        # expose it as an ALIAS to the real Windows target.
        if(TARGET ${_lapack_tgt} AND NOT TARGET flame)
            add_library(flame ALIAS ${_lapack_tgt})
        endif()
    else()
        set(_lapack_tgt flame)
    endif()

    # libflame includes the (generated, flattened) BLIS headers; force their
    # generation first. The aggregate dependency below is not enough on its own:
    # libflame splits its sources across many internal OBJECT libraries (e.g.
    # FLA_LAPACK_AVX2) that do the actual compiling, and add_dependencies on the
    # aggregate does not reach them -- so under the Unix Makefiles generator they
    # race the header generation ("'blis.h' file not found"). Attach the
    # dependency to every compiled target in libflame's directory subtree.
    if(TARGET flat-header)
        add_dependencies(${_lapack_tgt} flat-header)
    endif()
    if(TARGET flat-cblas-header)
        add_dependencies(${_lapack_tgt} flat-cblas-header)
    endif()
    aocl_tb_force_target_deps_recursive("${AOCL_TB_LAPACK_SRC}"
        flat-header flat-cblas-header)

    set(AOCL_TB_LAPACK_INCLUDE_DIR
        "${AOCL_TB_LAPACK_BIN}/include;${AOCL_TB_LAPACK_SRC}/include"
        CACHE INTERNAL "AOCL-LAPACK include dirs (in-tree build)")

    # libflame's f2c-translated objects reference the Fortran runtime. The
    # Fortran runtime is registered into the shared external-deps list from
    # aocl_unified.cmake -- right after enable_language(Fortran) makes CMake's
    # auto-detected implicit runtime available in the root scope -- so nothing is
    # named here (see aocl_tb_add_fortran_runtime()).

    # Public headers are taken from libflame's own PUBLIC_HEADER set (no hardcoded
    # list); LAPACKE's lapack.h + generated lapacke_mangling.h are added by the
    # install() shim honouring LAPACKE's own install(FILES ...).
    aocl_tb_install_component(libflame TARGETS ${_lapack_tgt})

    # Per-component shared library (shared builds only): libflame.so, recording a
    # normal runtime dependency on libblis[-mt].so and libaoclutils.so.
    if(NOT WIN32)
        set(_lapack_ext gfortran)
    else()
        set(_lapack_ext "")
    endif()
    aocl_tb_emit_shared(lapack libflame
        OUTPUT_NAME flame
        STATICS     ${_lapack_tgt}
        SO_DEPS     aoclso_blas aoclso_utils
        EXTERNAL    ${_lapack_ext})

    aocl_tb_register_manifest(lapack libflame
        "int-size=${AOCL_INT_SIZE_EFFECTIVE}"
        "multithreading=${_lapack_mt}")
endif()
