# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
#
# AOCL-Utils component -- target-based build (FetchContent + add_subdirectory).
#
# PURPOSE
#   Builds AOCL-Utils in-tree so its compiled OBJECT files go straight into the
#   unified libaocl (via `$<TARGET_OBJECTS>`, not archive merging). AOCL-Utils
#   provides the CPU-id / feature dispatch used by several other AOCL components,
#   so it is configured FIRST and has no AOCL dependencies of its own.
#
# HOW IT WORKS (step by step)
#   1. Guarded by ENABLE_AOCL_UTILS so the component is opt-in.
#   2. UTILS_PATH points at the sources under submodules/aocl-utils.
#   3. A block() creates an isolated option scope: BUILD_SHARED_LIBS OFF +
#      AU_BUILD_STATIC_LIBS ON build only the static PIC archive (and force /MT
#      on Windows); tests/examples/docs are turned off. FetchContent then
#      add_subdirectory()s the source, defining its targets here; the resolved
#      source/binary dirs are cached as AOCL_TB_UTILS_SRC / AOCL_TB_UTILS_BIN.
#   4. AOCL_TB_UTILS_INCLUDE_DIR(S) exports the public include dirs (SDK/Include,
#      SDK/Bcl, <bindir>/generated) for downstream consumers (LAPACK / Sparse /
#      DA / Crypto). Both singular and plural names are set because patched
#      components reference either.
#   5. The static target is named platform-dependently (`aoclutils` on Unix,
#      `libaoclutils` on Windows); on Windows an ALIAS exposes the canonical
#      `aoclutils` name so consumers resolve uniformly.
#   6. AOCL-Utils contributes its objects to libaocl via its OBJECT-library twin
#      (registered inside aocl-utils/Library/CMakeLists.txt), so no explicit
#      whole-lib call is needed here.
#   7. aocl_tb_install_component() stages the static lib + public headers into
#      the per-component install_package layout.
#   8. aocl_tb_emit_shared() (shared builds only) emits libaoclutils.so.
#   9. aocl_tb_register_manifest() records the component in the build manifest.

if(ENABLE_AOCL_UTILS)
    message(STATUS "[aocl] Configuring AOCL-Utils (FetchContent + add_subdirectory)")

    # Source selection (precedence: local path > submodules > git clone).
    set(UTILS_PATH "" CACHE STRING "Local path of AOCL-Utils source (parent dir containing 'aocl-utils'); overrides submodules/git")
    set(UTILS_GIT_REPOSITORY "https://github.com/amd/aocl-utils.git" CACHE STRING "AOCL-Utils git repository (used when submodules are off and UTILS_PATH is empty)")
    set(UTILS_GIT_TAG "main" CACHE STRING "AOCL-Utils git branch/tag")

    # Bring AOCL-Utils into this build in an isolated option scope. block()
    # confines the forced cache/option settings; the created targets remain
    # globally visible after endblock().
    block()
        # Static PIC archive only -- its objects feed libaocl. On Windows this
        # also forces the /MT runtime (BUILD_SHARED_LIBS=OFF), matching the rest
        # of the unified stack.
        set(BUILD_SHARED_LIBS OFF)
        set(AU_BUILD_TESTS        OFF CACHE BOOL   "" FORCE)
        set(AU_BUILD_EXAMPLES     OFF CACHE BOOL   "" FORCE)
        set(AU_BUILD_DOCS         OFF CACHE BOOL   "" FORCE)
        set(ALCI_EXAMPLES         OFF CACHE BOOL   "" FORCE)
        set(AU_BUILD_SHARED_LIBS  OFF CACHE BOOL   "" FORCE)
        set(AU_BUILD_STATIC_LIBS  ON  CACHE BOOL   "" FORCE)
        set(CMAKE_INSTALL_LIBDIR  lib CACHE STRING "" FORCE)

        aocl_tb_declare_source(aocl_utils UTILS aocl-utils)
        FetchContent_MakeAvailable(aocl_utils)

        # Export source/binary dirs (cache so they survive the block scope and
        # are visible to later components that depend on Utils).
        set(AOCL_TB_UTILS_SRC "${aocl_utils_SOURCE_DIR}" CACHE INTERNAL "")
        set(AOCL_TB_UTILS_BIN "${aocl_utils_BINARY_DIR}" CACHE INTERNAL "")
    endblock()

    # Public include dirs for consumers (LAPACK/Sparse/DA/Crypto). Exported under
    # both the singular and plural names some patched components reference
    # (aocl-sparse reads AOCL_TB_UTILS_INCLUDE_DIRS).
    set(AOCL_TB_UTILS_INCLUDE_DIR
        "${AOCL_TB_UTILS_SRC}/SDK/Include;${AOCL_TB_UTILS_SRC}/SDK/Bcl;${AOCL_TB_UTILS_BIN}/generated"
        CACHE INTERNAL "AOCL-Utils include dirs (in-tree build)")
    set(AOCL_TB_UTILS_INCLUDE_DIRS "${AOCL_TB_UTILS_INCLUDE_DIR}"
        CACHE INTERNAL "AOCL-Utils include dirs (in-tree build)")

    # AOCL-Utils builds its umbrella library as target 'aoclutils' (shared) or
    # 'aoclutils_static' (static-only build -- the case this component forces),
    # matching AOCL-Utils' own objectify selection in Library/CMakeLists.txt.
    # Resolve whichever target the in-tree build produced ('libaoclutils' covers
    # older AOCL-Utils sources) and expose the canonical 'aoclutils' name that
    # consuming components (sparse/DA/crypto) reference as TARGET aoclutils.
    if(TARGET aoclutils)
        set(_utils_tgt aoclutils)
    elseif(TARGET aoclutils_static)
        set(_utils_tgt aoclutils_static)
    elseif(TARGET libaoclutils)
        set(_utils_tgt libaoclutils)
    endif()
    if(NOT TARGET aoclutils)
        add_library(aoclutils ALIAS ${_utils_tgt})
    endif()

    # Merge into libaocl. AOCL-Utils contributes its objects to the unified
    # library directly: its OBJECT-library twin is registered at the end of
    # aocl-utils/Library/CMakeLists.txt (see aocl_tb_objectify there).

    # Per-component install_package + merged public headers.
    aocl_tb_install_component(aocl-utils
        TARGETS     ${_utils_tgt}
        HEADER_DIRS "${AOCL_TB_UTILS_SRC}/SDK/Include"
                    "${AOCL_TB_UTILS_SRC}/SDK/Bcl"
                    "${AOCL_TB_UTILS_BIN}/generated")

    # Per-component shared library (shared builds only): libaoclutils.so.
    aocl_tb_emit_shared(utils aocl-utils
        OUTPUT_NAME aoclutils
        STATICS     ${_utils_tgt})

    aocl_tb_register_manifest(utils aocl-utils)
endif()
