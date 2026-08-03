# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
#
# AOCL-LibMem component -- target-based build (FetchContent + add_subdirectory).
#
# PURPOSE
#   Builds AOCL-LibMem in-tree so its compiled OBJECT files (PIC) go straight into
#   the unified libaocl (via `$<TARGET_OBJECTS>`, not archive merging). LibMem
#   has no AOCL dependencies. It is a UNIX / x86 component only.
#
# HOW IT WORKS (step by step)
#   1. Guarded by ENABLE_AOCL_LIBMEM so the component is opt-in.
#   2. LIBMEM_PATH points at the patched sources under
#      submodules/aocl-libmem.
#   3. A block() isolates the forced cache settings: LibMem builds both shared
#      and static PIC variants in one configure -- BUILD_SHARED_LIBS is forced
#      OFF for stack consistency and the static target is what we merge;
#      ALMEM_DYN_DISPATCH ON selects runtime IFUNC dispatch. FetchContent then
#      add_subdirectory()s the tree; dirs cached as AOCL_TB_LIBMEM_SRC/_BIN.
#   4. LibMem's hand-written IFUNC resolvers must NOT become LTO bitcode (GNU ld
#      cannot whole-archive bitcode members and IFUNC relocations need real
#      object code), so -fno-lto is forced on the static target for Clang.
#   5. The unified libaocl is assembled from the component's compiled objects.
#   6. aocl_tb_install_component() stages the lib + include/ headers.
#   7. aocl_tb_emit_shared() (shared builds only) emits libaocl-libmem.so.
#   8. aocl_tb_register_manifest() records the component in the manifest.
#
# NOTE: LibMem exports the optimized string/memory functions (memcpy, ...) as
# IFUNCs, which are incompatible with symbol renaming (enforced in the root).

if(ENABLE_AOCL_LIBMEM)
    message(STATUS "[aocl] Configuring AOCL-LibMem (FetchContent + add_subdirectory)")

    # Source selection (precedence: local path > submodules > git clone).
    set(LIBMEM_PATH "" CACHE STRING "Local path of AOCL-LibMem source (parent dir containing 'aocl-libmem'); overrides submodules/git")
    set(LIBMEM_GIT_REPOSITORY "https://github.com/amd/aocl-libmem.git" CACHE STRING "AOCL-LibMem git repository (used when submodules are off and LIBMEM_PATH is empty)")
    set(LIBMEM_GIT_TAG "main" CACHE STRING "AOCL-LibMem git branch/tag")

    block()
        # Static PIC archive for the merge. LibMem builds both shared and static
        # PIC variants in one configure; force BUILD_SHARED_LIBS OFF for the rest
        # of the stack -- the static target is what we merge.
        set(BUILD_SHARED_LIBS OFF)
        set(ALMEM_DYN_DISPATCH    ON CACHE BOOL "" FORCE)
        set(AOCL_LIBMEM_SUBPROJECT ON CACHE BOOL "" FORCE)

        aocl_tb_declare_source(aocl_libmem LIBMEM aocl-libmem)
        FetchContent_MakeAvailable(aocl_libmem)

        set(AOCL_TB_LIBMEM_SRC "${aocl_libmem_SOURCE_DIR}" CACHE INTERNAL "")
        set(AOCL_TB_LIBMEM_BIN "${aocl_libmem_BINARY_DIR}" CACHE INTERNAL "")

        # LibMem's hand-written IFUNC resolvers and asm-style C must NOT be
        # compiled to LTO bitcode: GNU ld cannot whole-archive bitcode members,
        # and IFUNC relocations require real object code. Strip any -flto the
        # toolchain default added, for this subtree only.
        if(CMAKE_C_COMPILER_ID MATCHES "Clang")
            target_compile_options(aocl-libmem_static PRIVATE -fno-lto)
        endif()
    endblock()

    set(_libmem_tgt aocl-libmem_static)

    # LibMem's dynamic-dispatch (src/system/*) uses dlopen()/dlsym(), so consumers
    # of libaocl must link libdl. Register it as LibMem's own external dep.
    if(NOT WIN32 AND CMAKE_DL_LIBS)
        aocl_tb_add_external_libs(${CMAKE_DL_LIBS})
    endif()

    aocl_tb_install_component(aocl-libmem
        TARGETS     ${_libmem_tgt}
        HEADER_DIRS "${AOCL_TB_LIBMEM_SRC}/include")

    aocl_tb_emit_shared(libmem aocl-libmem
        OUTPUT_NAME aocl-libmem
        STATICS     ${_libmem_tgt})

    aocl_tb_register_manifest(libmem aocl-libmem)
endif()
