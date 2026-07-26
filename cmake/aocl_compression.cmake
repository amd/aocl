# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
#
# AOCL-Compression component -- target-based build (FetchContent +
# add_subdirectory).
#
# PURPOSE
#   Builds AOCL-Compression in-tree so its compiled OBJECT files go straight into
#   the unified libaocl (via `$<TARGET_OBJECTS>`, not archive merging).
#   Compression is self-contained -- it has no AOCL dependencies.
#
# HOW IT WORKS (step by step)
#   1. Guarded by ENABLE_AOCL_COMPRESSION so the component is opt-in.
#   2. COMPRESSION_PATH points at the patched sources under
#      submodules/aocl-compression.
#   3. aocl_resolve_component(COMPRESSION) resolves the per-component threading
#      flag (`_comp_threads`, may inherit the global value).
#   4. A block() isolates the forced cache settings: Compression's single library
#      type follows BUILD_STATIC_LIBS, so it is forced ON (with BUILD_SHARED_LIBS
#      OFF) to emit the static PIC archive; tests/docs/examples/utility are off.
#      FetchContent then add_subdirectory()s the tree; the resolved dirs are
#      cached as AOCL_TB_COMPRESSION_SRC / AOCL_TB_COMPRESSION_BIN.
#   5. aocl_tb_add_whole_lib() registers the archive for whole-archive merge into
#      libaocl.
#   6. aocl_tb_install_component() stages the lib + the public api/ headers.
#   7. aocl_tb_emit_shared() (shared builds only) emits libaocl_compression.so.
#   8. aocl_tb_register_manifest() records the threading choice in the manifest.
#
# NOTE (Windows / Visual Studio generator): the bundled zstd .S Huffman decoder
# (huf_decompress_amd64.S) has no MSBuild ClangCl build rule, so under the VS
# generator that asm path is dropped and the portable C decoder is used instead
# (see the ZSTD_SRC_FILES / -DZSTD_DISABLE_ASM handling below). Ninja keeps the
# optimized asm.

if(ENABLE_AOCL_COMPRESSION)
    message(STATUS "[aocl] Configuring AOCL-Compression (FetchContent + add_subdirectory)")

    # Source selection (precedence: local path > submodules > git clone).
    set(COMPRESSION_PATH "" CACHE STRING "Local path of AOCL-Compression source (parent dir containing 'aocl-compression'); overrides submodules/git")
    set(COMPRESSION_GIT_REPOSITORY "https://github.com/amd/aocl-compression.git" CACHE STRING "AOCL-Compression git repository (used when submodules are off and COMPRESSION_PATH is empty)")
    set(COMPRESSION_GIT_TAG "amd-main" CACHE STRING "AOCL-Compression git branch/tag")

    # Per-component threading (inherit => identical to the global value).
    aocl_resolve_component(COMPRESSION)
    set(_comp_threads ${AOCL_COMPRESSION_THREADS_ON})

    block()
        # Static PIC archive only -- its objects feed libaocl (and /MT on Windows).
        # Compression's single library type follows BUILD_STATIC_LIBS, so force it
        # ON (BUILD_SHARED_LIBS OFF keeps the rest of the stack consistent / /MT).
        set(BUILD_SHARED_LIBS OFF)
        set(BUILD_STATIC_LIBS         ON             CACHE BOOL "" FORCE)
        set(AOCL_ENABLE_THREADS       ${_comp_threads} CACHE BOOL "" FORCE)
        set(AOCL_TEST_COVERAGE        OFF            CACHE BOOL "" FORCE)
        set(TEST_COVERAGE_THIRD_PARTY OFF            CACHE BOOL "" FORCE)
        set(BUILD_DOC                 OFF            CACHE BOOL "" FORCE)
        set(BUILD_EXAMPLE             OFF            CACHE BOOL "" FORCE)
        set(BUILD_UTILITY             OFF            CACHE BOOL "" FORCE)
        if(OpenMP_libomp_LIBRARY)
            set(OpenMP_libomp_LIBRARY "${OpenMP_libomp_LIBRARY}" CACHE STRING "" FORCE)
        endif()

        aocl_tb_declare_source(aocl_compression COMPRESSION aocl-compression)
        FetchContent_MakeAvailable(aocl_compression)

        set(AOCL_TB_COMPRESSION_SRC "${aocl_compression_SOURCE_DIR}" CACHE INTERNAL "")
        set(AOCL_TB_COMPRESSION_BIN "${aocl_compression_BINARY_DIR}" CACHE INTERNAL "")
    endblock()

    set(_comp_tgt aocl_compression)

    aocl_tb_add_whole_lib(${_comp_tgt})

    aocl_tb_install_component(aocl-compression
        TARGETS     ${_comp_tgt}
        HEADER_DIRS "${AOCL_TB_COMPRESSION_SRC}/api")

    aocl_tb_emit_shared(compression aocl-compression
        OUTPUT_NAME aocl_compression
        STATICS     ${_comp_tgt})

    aocl_tb_register_manifest(compression aocl-compression
        "multithreading=${_comp_threads}")
endif()
