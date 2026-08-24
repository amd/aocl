# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
#
# OpenRNG component -- target-based build (FetchContent + add_subdirectory).
#
# PURPOSE
#   Builds OpenRNG in-tree so its compiled OBJECT files go straight into the
#   unified libaocl (via `$<TARGET_OBJECTS>`, not archive merging). The AOCL
#   flavour depends on AOCL-LibM, so the root auto-enables LibM whenever OpenRNG
#   is enabled.
#
# HOW IT WORKS (step by step)
#   1. Guarded by ENABLE_AOCL_OPENRNG so the component is opt-in.
#   2. OPENRNG_PATH points at the sources under submodules/openrng;
#      the interface (lp64/ilp64) follows ENABLE_ILP64.
#   3. A block() isolates the forced cache settings: static PIC archive only;
#      AOCL_OPENRNG_BUILD ON selects the AOCL flavour, which includes amdlibm.h
#      from AOCL_ROOT/include and links `alm` (Unix) / `libalm` (Windows). The
#      AOCL_ROOT lookup is pointed at the in-tree LibM synthetic root
#      (AOCL_TB_LIBM_ROOT) and the `alm` ALIAS resolves the link; tests/bench/
#      docs are off. FetchContent then add_subdirectory()s the tree; dirs cached
#      as AOCL_TB_OPENRNG_SRC / AOCL_TB_OPENRNG_BIN.
#   4. OpenRNG builds an empty `openrng` library that just links the `openrngobj`
#      OBJECT library (which holds every compiled object). aocl_tb_add_objects()
#      collects that OBJECT library directly into libaocl.
#   5. aocl_tb_install_component() stages the lib + include/ headers.
#   6. aocl_tb_emit_shared() (shared builds only) emits libopenrng.so with a
#      runtime dependency on libalm (libm).
#   7. aocl_tb_register_manifest() (below) records the component in the manifest.

if(ENABLE_AOCL_OPENRNG)
    message(STATUS "[aocl] Configuring OpenRNG (FetchContent + add_subdirectory)")

    # Source selection (precedence: local path > submodules > git clone).
    set(OPENRNG_PATH "" CACHE STRING "Local path of OpenRNG source (parent dir containing 'openrng'); overrides submodules/git")
    set(OPENRNG_GIT_REPOSITORY "https://github.com/amd/openrng.git" CACHE STRING "OpenRNG git repository (used when submodules are off and OPENRNG_PATH is empty)")
    set(OPENRNG_GIT_TAG "main" CACHE STRING "OpenRNG git branch/tag")

    if(ENABLE_ILP64)
        set(_orng_iface "ilp64")
    else()
        set(_orng_iface "lp64")
    endif()

    block()
        # Static PIC archive only -- its objects feed libaocl (and /MT on Windows).
        set(BUILD_SHARED_LIBS OFF)
        set(AOCL_OPENRNG_BUILD ON                   CACHE BOOL   "" FORCE)
        # Point OpenRNG's AOCL_ROOT lookup at the in-tree LibM synthetic root
        # (carries amdlibm.h); the 'alm' ALIAS resolves the link.
        set(AOCL_ROOT "${AOCL_TB_LIBM_ROOT}"        CACHE PATH   "" FORCE)
        set(OPENRNG_INTERFACE "${_orng_iface}"      CACHE STRING "" FORCE)
        set(BUILD_TESTING OFF                      CACHE BOOL   "" FORCE)
        set(BUILD_BENCH   OFF                       CACHE BOOL   "" FORCE)
        set(BUILD_DOCS    OFF                       CACHE BOOL   "" FORCE)

        aocl_tb_declare_source(openrng OPENRNG openrng)
        FetchContent_MakeAvailable(openrng)

        set(AOCL_TB_OPENRNG_SRC "${openrng_SOURCE_DIR}" CACHE INTERNAL "")
        set(AOCL_TB_OPENRNG_BIN "${openrng_BINARY_DIR}" CACHE INTERNAL "")
    endblock()

    set(_openrng_tgt openrngobj)

    # getLibM.cmake defers the LibM/Utils include dirs to the integrator under
    # AOCL_TB_UNIFIED_BUILD; supply the in-tree dirs so openrngobj finds
    # amdlibm.h (LibM) and the AOCL-Utils headers.
    target_include_directories(openrngobj SYSTEM PRIVATE
        "${AOCL_TB_LIBM_ROOT}/include"
        ${AOCL_TB_UTILS_INCLUDE_DIRS})

    # getLibM.cmake also defers the LibM link. OpenRNG still builds+installs a
    # standalone 'openrng' shared lib (and a C-link self-test), so link the
    # in-tree LibM ('alm') to resolve its amd_* symbols.
    if(TARGET alm)
        target_link_libraries(openrng        PRIVATE alm)
        target_link_libraries(openrng_static PRIVATE alm)
    endif()

    # Fold OpenRNG's objects into libaocl.
    aocl_tb_add_objects(openrngobj)

    aocl_tb_install_component(openrng
        TARGETS     ${_openrng_tgt}
        HEADER_DIRS "${AOCL_TB_OPENRNG_SRC}/include")

    aocl_tb_emit_shared(openrng openrng
        OUTPUT_NAME openrng
        STATICS     ${_openrng_tgt}
        SO_DEPS     aoclso_libm)

    aocl_tb_register_manifest(openrng openrng
        "interface=${_orng_iface}")
endif()
