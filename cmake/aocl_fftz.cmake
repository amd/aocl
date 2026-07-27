# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
#
# AOCL-FFTZ component -- target-based build (FetchContent + add_subdirectory).
#
# PURPOSE
#   Builds AOCL-FFTZ in-tree so its compiled OBJECT files go straight into the
#   unified libaocl (via `$<TARGET_OBJECTS>`, not archive merging). FFTZ is
#   self-contained -- it depends only on libm and, when multi-threaded, OpenMP.
#
# HOW IT WORKS (step by step)
#   1. Guarded by ENABLE_AOCL_FFTZ so the component is opt-in.
#   2. FFTZ_PATH points at the sources under submodules/aocl-fftz.
#   3. aocl_resolve_component(FFTZ) resolves the per-component multithreading
#      flag (`_fftz_mt`, may inherit the global value).
#   4. A block() isolates the forced cache settings: FFTZ's single library type
#      follows BUILD_STATIC_LIBS, so it is forced ON (with BUILD_SHARED_LIBS OFF)
#      to emit the static PIC archive; coverage/docs/wrappers/strict-warnings are
#      off. FetchContent then add_subdirectory()s the tree; the resolved dirs are
#      cached as AOCL_TB_FFTZ_SRC / AOCL_TB_FFTZ_BIN.
#   5. The static target is named platform-dependently (`aocl_fftz_static` on
#      Windows, `aocl_fftz` on Linux).
#   6. aocl_tb_add_whole_lib() registers the archive for merge into libaocl.
#   7. aocl_tb_install_component() stages the lib + include/ headers.
#   8. aocl_tb_emit_shared() (shared builds only) emits libaocl_fftz.so.
#   9. aocl_tb_register_manifest() records the threading choice in the manifest.

if(ENABLE_AOCL_FFTZ)
    message(STATUS "[aocl] Configuring AOCL-FFTZ (FetchContent + add_subdirectory)")

    # Source selection (precedence: local path > submodules > git clone).
    set(FFTZ_PATH "" CACHE STRING "Local path of AOCL-FFTZ source (parent dir containing 'aocl-fftz'); overrides submodules/git")
    set(FFTZ_GIT_REPOSITORY "https://github.com/amd/aocl-fftz.git" CACHE STRING "AOCL-FFTZ git repository (used when submodules are off and FFTZ_PATH is empty)")
    set(FFTZ_GIT_TAG "amd-main" CACHE STRING "AOCL-FFTZ git branch/tag")

    # Per-component threading (inherit => identical to the global value).
    aocl_resolve_component(FFTZ)
    if(AOCL_FFTZ_THREADS_ON)
        set(_fftz_mt ON)
    else()
        set(_fftz_mt OFF)
    endif()

    block()
        # Static PIC archive only -- its objects feed libaocl (and /MT on Windows).
        set(BUILD_SHARED_LIBS OFF)
        set(BUILD_STATIC_LIBS          ON         CACHE BOOL "" FORCE)
        set(ENABLE_MULTI_THREADING     ${_fftz_mt} CACHE BOOL "" FORCE)
        set(AOCL_TEST_COVERAGE         OFF        CACHE BOOL "" FORCE)
        set(BUILD_DOC                  OFF        CACHE BOOL "" FORCE)
        set(BUILD_THIRD_PARTY_WRAPPERS OFF        CACHE BOOL "" FORCE)
        set(ENABLE_STRICT_WARNINGS     OFF        CACHE BOOL "" FORCE)
        if(OpenMP_libomp_LIBRARY)
            set(OpenMP_libomp_LIBRARY "${OpenMP_libomp_LIBRARY}" CACHE STRING "" FORCE)
        endif()

        aocl_tb_declare_source(aocl_fftz FFTZ aocl-fftz)
        FetchContent_MakeAvailable(aocl_fftz)

        set(AOCL_TB_FFTZ_SRC "${aocl_fftz_SOURCE_DIR}" CACHE INTERNAL "")
        set(AOCL_TB_FFTZ_BIN "${aocl_fftz_BINARY_DIR}" CACHE INTERNAL "")
    endblock()

    if(WIN32)
        set(_fftz_tgt aocl_fftz_static)
    else()
        set(_fftz_tgt aocl_fftz)
    endif()

    aocl_tb_add_whole_lib(${_fftz_tgt})

    aocl_tb_install_component(aocl-fftz
        TARGETS     ${_fftz_tgt}
        HEADER_DIRS "${AOCL_TB_FFTZ_SRC}/include")

    aocl_tb_emit_shared(fftz aocl-fftz
        OUTPUT_NAME aocl_fftz
        STATICS     ${_fftz_tgt})

    aocl_tb_register_manifest(fftz aocl-fftz
        "multithreading=${_fftz_mt}")
endif()
