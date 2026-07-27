# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
#
# AOCL-DLP component -- FetchContent + add_subdirectory so DLP's OBJECT files fold
# directly into the single unified libaocl. DLP is self-contained (OpenMP/pthreads).
# AOCL-DA consumes DLP on non-Windows (aocl_dlp.h), so DLP is included BEFORE DA
# and exports its include dir + static target (see aocl_da.cmake).
#
#   1. Opt-in via ENABLE_AOCL_DLP (auto-enabled by the root for non-Windows DA).
#   2. block() forces static PIC archive; tests/examples/benchmarks/docs off.
#   3. aocl_tb_objectify() folds DLP's objects into libaocl (see below).
#   4. install_component / emit_shared / register_manifest stage the component.

if(ENABLE_AOCL_DLP)
    message(STATUS "[aocl] Configuring AOCL-DLP (FetchContent + add_subdirectory)")

    # Source selection (precedence: local path > submodules > git clone).
    set(DLP_PATH "" CACHE STRING "Local path of AOCL-DLP source (parent dir containing 'aocl-dlp'); overrides submodules/git")
    set(DLP_GIT_REPOSITORY "https://github.com/amd/aocl-dlp.git" CACHE STRING "AOCL-DLP git repository (used when submodules are off and DLP_PATH is empty)")
    set(DLP_GIT_TAG "master" CACHE STRING "AOCL-DLP git branch/tag")

    block()
        # Static PIC archive only -- its objects feed libaocl (and /MT on Windows).
        set(BUILD_SHARED_LIBS OFF)
        set(BUILD_TESTING    OFF CACHE BOOL "" FORCE)
        set(BUILD_EXAMPLES   OFF CACHE BOOL "" FORCE)
        set(BUILD_BENCHMARKS OFF CACHE BOOL "" FORCE)
        set(BUILD_DOXYGEN    OFF CACHE BOOL "" FORCE)
        set(BUILD_SPHINX     OFF CACHE BOOL "" FORCE)
        # Recent clang-cl errors on C pointer/int-conversion warnings that DLP's
        # kernels build cleanly (as warnings) on gcc/older clang. Downgrade them.
        if(WIN32)
            set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -Wno-error=incompatible-pointer-types -Wno-error=incompatible-function-pointer-types -Wno-error=int-conversion")
        endif()
        if(OpenMP_libomp_LIBRARY)
            set(OpenMP_libomp_LIBRARY "${OpenMP_libomp_LIBRARY}" CACHE STRING "" FORCE)
        endif()

        aocl_tb_declare_source(aocl_dlp DLP aocl-dlp)
        FetchContent_MakeAvailable(aocl_dlp)

        set(AOCL_TB_DLP_SRC "${aocl_dlp_SOURCE_DIR}" CACHE INTERNAL "")
        set(AOCL_TB_DLP_BIN "${aocl_dlp_BINARY_DIR}" CACHE INTERNAL "")
    endblock()

    # DLP writes aocl_dlp_config.h to ${CMAKE_BINARY_DIR}/include, but its classic
    # kernels look for it under DLP's own binary dir (they coincide only in a
    # standalone build). Mirror it so those targets compile.
    if(EXISTS "${CMAKE_BINARY_DIR}/include/aocl_dlp_config.h")
        configure_file("${CMAKE_BINARY_DIR}/include/aocl_dlp_config.h"
                       "${AOCL_TB_DLP_BIN}/include/aocl_dlp_config.h" COPYONLY)
    endif()

    # Public include dirs for consumers (DA): aocl_dlp.h lives in include/; the
    # generated aocl_dlp_config.h lands under the build tree's include/.
    set(AOCL_TB_DLP_INCLUDE_DIR
        "${AOCL_TB_DLP_SRC}/include;${CMAKE_BINARY_DIR}/include"
        CACHE INTERNAL "AOCL-DLP include dirs (in-tree build)")

    set(_dlp_tgt aocl-dlp_static)

    # aocl-dlp_static is built purely from $<TARGET_OBJECTS:...> sibling OBJECT
    # libs; objectify harvests those genexes so DLP's objects land in libaocl.
    aocl_tb_objectify(${_dlp_tgt})

    # aocl_dlp.h -> classic/dlp_macros.h #includes the GENERATED aocl_dlp_config.h,
    # so the installed public headers are unusable without it. Ship it alongside
    # aocl_dlp.h by adding DLP's binary include/ (mirrored above; contains only the
    # generated config header) to the installed header set.
    aocl_tb_install_component(aocl-dlp
        TARGETS     ${_dlp_tgt}
        HEADER_DIRS "${AOCL_TB_DLP_SRC}/include" "${AOCL_TB_DLP_BIN}/include")

    aocl_tb_emit_shared(dlp aocl-dlp
        OUTPUT_NAME aocl-dlp
        STATICS     ${_dlp_tgt})

    aocl_tb_register_manifest(dlp aocl-dlp "")
endif()
