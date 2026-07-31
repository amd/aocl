# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
#
# AOCL-LibM component -- target-based build (FetchContent + add_subdirectory).
#
# PURPOSE
#   Builds AOCL-LibM in-tree so its compiled OBJECT files go straight into the
#   unified libaocl (via `$<TARGET_OBJECTS>`, not archive merging). LibM has no
#   AOCL dependencies, but OpenRNG's AOCL flavour needs it, so the root
#   auto-enables LibM whenever OpenRNG is enabled.
#
# HOW IT WORKS (step by step)
#   1. Guarded by ENABLE_AOCL_LIBM so the component is opt-in.
#   2. LIBM_PATH points at the sources under submodules/aocl-libm.
#   3. A block() isolates the forced cache settings: static PIC archives only;
#      tests/examples/docs/sanitizers off; ISA dispatch follows AMD_CONFIG
#      (ALM_STATIC_DISPATCH is only passed when non-empty -- an empty value fails
#      LibM's validation and omitting it selects dynamic dispatch). FetchContent
#      then add_subdirectory()s the tree; dirs cached as AOCL_TB_LIBM_SRC/_BIN.
#   4. LibM produces `libm_static` (OUTPUT_NAME `alm`) built from internal OBJECT
#      libraries; its objects are registered for libaocl via aocl_tb_add_objects().
#      LibM <= 5.2.x also produced a self-contained `alm_utils_static` CPU-id
#      helper (linked by libalm but not embedded), whose objects were registered
#      too; LibM 5.3 dropped it (CPU-id moved to the aocl-utils component), so all
#      alm_utils_static handling below is guarded by `if(TARGET alm_utils_static)`.
#   5. An `alm` ALIAS (and `libalm` on Windows) is exposed so OpenRNG's link of
#      the bare name resolves to the in-tree static target, and a synthetic AOCL
#      root (AOCL_TB_LIBM_ROOT, carrying amdlibm.h) is staged for OpenRNG's
#      AOCL_ROOT include lookup.
#   6. aocl_tb_install_component() / aocl_tb_emit_shared() / register_manifest
#      stage the lib + headers, emit the shared lib (shared builds), and record
#      the component in the manifest (see below).
#
# NOTE (Windows / Visual Studio generator): libm assembles GAS .S kernels via
# add_custom_command into raw .obj paths (its isa/CMakeLists.txt). Those custom
# assemble targets (avxasm / avx2asm) are registered as unified dep targets so
# the .obj files exist before the final link. Under Ninja real OBJECT libraries
# are used instead, so this only matters for the VS generator.

if(ENABLE_AOCL_LIBM)
    message(STATUS "[aocl] Configuring AOCL-LibM (FetchContent + add_subdirectory)")

    # Source selection (precedence: local path > submodules > git clone).
    set(LIBM_PATH "" CACHE STRING "Local path of AOCL-LibM source (parent dir containing 'aocl-libm'); overrides submodules/git")
    set(LIBM_GIT_REPOSITORY "https://github.com/amd/aocl-libm-ose.git" CACHE STRING "AOCL-LibM git repository (used when submodules are off and LIBM_PATH is empty)")
    set(LIBM_GIT_TAG "master" CACHE STRING "AOCL-LibM git branch/tag")

    block()
        # Static PIC archives only -- their objects feed libaocl (and /MT on Windows).
        set(BUILD_SHARED_LIBS OFF)
        set(CUST_PROJ_NAME       "libm" CACHE STRING "" FORCE)
        set(CUST_PROJ_PREFIX     "aocl" CACHE STRING "" FORCE)
        set(CUST_PROJ_CXX_STD    "17"   CACHE STRING "" FORCE)
        set(LIBM_BUILD_LIBRARY   ON     CACHE BOOL "" FORCE)
        set(LIBM_BUILD_TESTS     OFF    CACHE BOOL "" FORCE)
        set(LIBM_BUILD_TESTSUITE OFF    CACHE BOOL "" FORCE)
        set(LIBM_BUILD_EXAMPLES  OFF    CACHE BOOL "" FORCE)
        set(LIBM_BUILD_DOCS      OFF    CACHE BOOL "" FORCE)
        set(LIBM_ENABLE_ASAN     OFF    CACHE BOOL "" FORCE)
        set(LIBM_ENABLE_COVERAGE OFF    CACHE BOOL "" FORCE)
        # ISA dispatch follows AMD_CONFIG: only pass when non-empty -- an empty
        # ALM_STATIC_DISPATCH fails LibM's validation, and omitting it selects
        # dynamic dispatch (the default).
        if(ALM_STATIC_DISPATCH_OPTION)
            set(ALM_STATIC_DISPATCH "${ALM_STATIC_DISPATCH_OPTION}" CACHE STRING "" FORCE)
        endif()

        aocl_tb_declare_source(aocl_libm LIBM aocl-libm)
        FetchContent_MakeAvailable(aocl_libm)

        set(AOCL_TB_LIBM_SRC "${aocl_libm_SOURCE_DIR}" CACHE INTERNAL "")
        set(AOCL_TB_LIBM_BIN "${aocl_libm_BINARY_DIR}" CACHE INTERNAL "")
    endblock()

    # Fold LibM's object files into the single libaocl. libm_static is assembled
    # purely from $<TARGET_OBJECTS:...> genexes (src + the optimized/isa/iface/
    # arch/ref subdirectory OBJECT libraries), so harvest those from its SOURCES
    # and register them directly. (The libm PR branch builds the standalone
    # libalm but does not itself register objects for the unified build.)
    get_target_property(_libm_objs libm_static SOURCES)
    if(NOT _libm_objs)
        message(FATAL_ERROR "[aocl] libm_static carries no SOURCES to register")
    endif()
    aocl_tb_add_objects(${_libm_objs})

    # Under the Visual Studio generator LibM assembles its GAS .S kernels via
    # add_custom_command (the avxasm/avx2asm custom targets) and contributes the
    # resulting .obj files to libm_static by PATH -- so they appear in the SOURCES
    # harvested above, but the custom targets that PRODUCE them are not otherwise
    # build-order dependencies of the unified library. Register them so the .obj
    # files exist before libaocl links. Under Ninja these are real OBJECT
    # libraries already pulled in via $<TARGET_OBJECTS>, so this is a harmless
    # add_dependencies() on targets that would build anyway.
    foreach(_asm avxasm avx2asm)
        if(TARGET ${_asm})
            set_property(GLOBAL APPEND PROPERTY AOCL_TB_DEP_TARGETS ${_asm})
        endif()
    endforeach()

    # alm_utils_static: older LibM (<= 5.2.x) built a self-contained CPU-id helper
    # archive (cpuid.c) that libalm links but does not embed, so its objects had
    # to be recompiled into an OBJECT twin and registered for the unified library.
    # AOCL-LibM 5.3 dropped this target -- CPU identification now comes from the
    # aocl-utils component (get_au_flag / Cct_Libaoclutils, provided in the
    # unified build by ENABLE_AOCL_UTILS) -- so only register it when present.
    if(TARGET alm_utils_static)
        aocl_tb_objectify(alm_utils_static)
    endif()

    # Both static archives are merged (libalm.a links but does not embed
    # alm_utils). Kept as the informational whole-archive record.
    aocl_tb_add_whole_lib(libm_static)
    if(TARGET alm_utils_static)
        aocl_tb_add_whole_lib(alm_utils_static)
    endif()

    # OpenRNG links the bare 'alm' name; expose an ALIAS to the static target.
    # On Windows the patched OpenRNG links 'libalm' instead, so alias both.
    if(NOT TARGET alm)
        add_library(alm ALIAS libm_static)
    endif()
    if(WIN32 AND NOT TARGET libalm)
        add_library(libalm ALIAS libm_static)
    endif()

    # Stage a synthetic AOCL root carrying LibM's public headers so OpenRNG's
    # AOCL_ROOT/include lookup (amdlibm.h / amdlibm_vec.h) is satisfied in-tree.
    set(AOCL_TB_LIBM_ROOT "${CMAKE_BINARY_DIR}/aocl-libm/aocl_root" CACHE INTERNAL "")
    file(MAKE_DIRECTORY "${AOCL_TB_LIBM_ROOT}/include")
    configure_file("${AOCL_TB_LIBM_SRC}/include/external/amdlibm.h"
                   "${AOCL_TB_LIBM_ROOT}/include/amdlibm.h" COPYONLY)
    configure_file("${AOCL_TB_LIBM_SRC}/include/external/amdlibm_vec.h"
                   "${AOCL_TB_LIBM_ROOT}/include/amdlibm_vec.h" COPYONLY)

    # LibM static targets to install/emit: libm_static always, plus the
    # standalone alm_utils_static only on LibM versions that still define it.
    set(_libm_static_targets libm_static)
    if(TARGET alm_utils_static)
        list(APPEND _libm_static_targets alm_utils_static)
    endif()

    aocl_tb_install_component(aocl-libm
        TARGETS     ${_libm_static_targets}
        HEADER_DIRS "${AOCL_TB_LIBM_SRC}/include/external")

    aocl_tb_emit_shared(libm aocl-libm
        OUTPUT_NAME alm
        STATICS     ${_libm_static_targets})

    aocl_tb_register_manifest(libm aocl-libm)
endif()
