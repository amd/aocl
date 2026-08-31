# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
#
# AOCL-ScaLAPACK component -- built SEPARATELY and LINKED against the unified
# libaocl (NOT merged into it).
#
# PURPOSE
#   Every other AOCL component compiles its OBJECT files straight into the single
#   libaocl. ScaLAPACK is deliberately different: when ENABLE_AOCL_SCALAPACK is ON
#   it is built as its OWN library (libscalapack) that LINKS the already-built
#   unified libaocl. Its prerequisites -- AOCL-BLAS (blis), AOCL-Utils and
#   AOCL-LAPACK (libflame) -- therefore have to live INSIDE that libaocl, so
#   enabling ScaLAPACK auto-enables AOCL-LAPACK (which itself pulls in AOCL-BLAS +
#   AOCL-Utils); see the dependency resolution in aocl_targets_common.cmake.
#
# WHY ExternalProject (not FetchContent/add_subdirectory like the merged parts)
#   ScaLAPACK's own CMake runs a CONFIGURE-TIME Fortran link check
#   (CHECK_FORTRAN_FUNCTION_EXISTS(dgesv)) against the BLAS/LAPACK libraries it is
#   handed and, if that fails, silently downloads reference BLAS/LAPACK instead.
#   The unified libaocl does not exist until the BUILD phase, so an
#   add_subdirectory (configured during THIS configure) would never see it.
#   ExternalProject configures ScaLAPACK at BUILD time -- after 'aocl' is built
#   (DEPENDS aocl) -- so the link check resolves dgesv from the real libaocl.
#
# EXTERNAL PREREQUISITES (caller-provided)
#   * MPI  -- ScaLAPACK is an MPI library and FATAL_ERRORs without one. Point at
#             an install with -DMPI_BASE_DIR=<path> (or have a system MPI on PATH).
#   * A Fortran compiler (Linux: gfortran; Windows: ifx/ifort).
#
# SOURCE (precedence: local path > git clone), like the other components:
#   * -DSCALAPACK_PATH=<parent dir containing 'aocl-scalapack'>   (local), or
#   * -DSCALAPACK_GIT_REPOSITORY / -DSCALAPACK_GIT_TAG            (git clone).

if(ENABLE_AOCL_SCALAPACK)
    message(STATUS "[aocl] Configuring AOCL-ScaLAPACK (separate library; links the unified libaocl)")

    include(ExternalProject)

    # Source selection (precedence: local path > git clone). Defaults per request:
    # amd/aocl-scalapack.git @ master.
    set(SCALAPACK_PATH "" CACHE STRING "Local path of AOCL-ScaLAPACK source (parent dir containing 'aocl-scalapack'); overrides the git-clone default")
    set(SCALAPACK_GIT_REPOSITORY "https://github.com/amd/aocl-scalapack.git" CACHE STRING "AOCL-ScaLAPACK git repository (used when SCALAPACK_PATH is empty)")
    set(SCALAPACK_GIT_TAG "master" CACHE STRING "AOCL-ScaLAPACK git branch/tag")

    # MPI install root (ScaLAPACK requires MPI). Forwarded to ScaLAPACK's own
    # find_package(MPI); leave empty to use a system MPI on the default paths.
    set(MPI_BASE_DIR "" CACHE PATH "MPI installation root for AOCL-ScaLAPACK")

    # ScaLAPACK-specific pass-throughs (mirror ScaLAPACK's own option names).
    set(SCALAPACK_CDEFS "" CACHE STRING "ScaLAPACK Fortran-to-C name mangling: NoChange|UpCase|Add_ (empty = ScaLAPACK default)")

    # The unified library target is named after the root project() -- i.e.
    # AOCL_SINGLE_LIBRARY_NAME (default 'aocl'). Reference it by that name, never a
    # hardcoded literal, so a renamed single library still resolves.
    if(NOT TARGET ${AOCL_SINGLE_LIBRARY_NAME})
        message(FATAL_ERROR "[aocl] ENABLE_AOCL_SCALAPACK needs the unified '${AOCL_SINGLE_LIBRARY_NAME}' "
                            "library target; AOCL-LAPACK is auto-enabled so it is built. If you "
                            "see this, no components were enabled to compose the unified library.")
    endif()

    # Source arguments: a local path (parent dir that CONTAINS aocl-scalapack) or
    # a git clone into the build tree.
    if(SCALAPACK_PATH)
        file(TO_CMAKE_PATH "${SCALAPACK_PATH}" _sl_path)
        set(_sl_src_args SOURCE_DIR "${_sl_path}/aocl-scalapack")
        message(STATUS "[aocl] aocl_scalapack: using local source ${_sl_path}/aocl-scalapack")
    else()
        set(_sl_src_args
            GIT_REPOSITORY "${SCALAPACK_GIT_REPOSITORY}"
            GIT_TAG        "${SCALAPACK_GIT_TAG}"
            SOURCE_DIR     "${CMAKE_BINARY_DIR}/aocl-scalapack-src")
        message(STATUS "[aocl] aocl_scalapack: cloning ${SCALAPACK_GIT_REPOSITORY} @ ${SCALAPACK_GIT_TAG}")
    endif()

    set(_sl_install "${CMAKE_BINARY_DIR}/aocl-scalapack/install_package")

    # The unified library ScaLAPACK links for BOTH its BLAS and LAPACK inputs: it
    # is self-contained (blis + libflame + aocl-utils). TARGET_LINKER_FILE gives
    # the correct link input on every platform (libaocl.so / libaocl.a on ELF, the
    # aocl.lib import library for the Windows DLL).
    set(_sl_unified "$<TARGET_LINKER_FILE:${AOCL_SINGLE_LIBRARY_NAME}>")

    # ScaLAPACK runs a configure-time `dgesv` link check against the libraries it
    # is handed and links its own library against them. A SHARED libaocl.so records
    # its transitive runtime deps (Fortran runtime, OpenMP, libstdc++, ...) as
    # DT_NEEDED, so passing it alone is enough. A STATIC libaocl.a records none, so
    # both the check and the link fail to resolve those symbols (ScaLAPACK then
    # silently falls back to downloading reference BLAS/LAPACK). For a static
    # unified library, spell out those transitive deps: the BIY external-deps union
    # (Fortran runtime, ...), OpenMP, and the C++/math/thread runtimes (aocl-utils
    # is C++). Passed as the BLAS list; LAPACK stays the bare libaocl so the linker
    # sees the archive twice (helps resolve blis<->libflame cross-references).
    set(_sl_blas "${_sl_unified}")
    if(AOCL_LINKAGE_EFFECTIVE STREQUAL "static")
        get_property(_sl_ext GLOBAL PROPERTY AOCL_TB_EXTERNAL_LIBS)
        if(_sl_ext)
            list(APPEND _sl_blas ${_sl_ext})
        endif()
        if(ENABLE_MULTITHREADING)
            if(OpenMP_libomp_LIBRARY)
                list(APPEND _sl_blas "${OpenMP_libomp_LIBRARY}")
            else()
                list(APPEND _sl_blas "-fopenmp")
            endif()
        endif()
        if(NOT WIN32)
            list(APPEND _sl_blas -lstdc++ -lm -lpthread -ldl)
        endif()
    endif()
    # ExternalProject splits a ';' list into separate CMAKE_ARGS; carry the list
    # through as '|' and restore it with LIST_SEPARATOR below.
    string(REPLACE ";" "|" _sl_blas_arg "${_sl_blas}")

    # Compilers for ScaLAPACK. On non-Windows it overwrites CMAKE_C/Fortran_COMPILER
    # with the MPI wrappers it locates; handing it a different compiler would change
    # the compiler mid-configure, resetting the cache and dropping our
    # -DLAPACK_LIBRARIES/-DBLAS_LIBRARIES (it then downloads reference BLAS/LAPACK).
    # Pass the wrappers up front so that override is a no-op (they honour I_MPI_CC/
    # I_MPI_F90 for the underlying compiler). Windows keeps native compilers + MPI
    # import libs, so pass what the main build resolved.
    set(_sl_cc "${CMAKE_C_COMPILER}")
    set(_sl_fc "${CMAKE_Fortran_COMPILER}")
    if(NOT WIN32)
        find_program(AOCL_TB_SL_MPICC NAMES mpicc          HINTS "${MPI_BASE_DIR}/bin")
        find_program(AOCL_TB_SL_MPIFC NAMES mpif90 mpifort HINTS "${MPI_BASE_DIR}/bin")
        if(AOCL_TB_SL_MPICC)
            set(_sl_cc "${AOCL_TB_SL_MPICC}")
        endif()
        if(AOCL_TB_SL_MPIFC)
            set(_sl_fc "${AOCL_TB_SL_MPIFC}")
        endif()
    endif()

    set(_sl_extra_args "")
    if(_sl_fc)
        list(APPEND _sl_extra_args "-DCMAKE_Fortran_COMPILER=${_sl_fc}")
    endif()
    if(SCALAPACK_CDEFS)
        list(APPEND _sl_extra_args "-DCDEFS=${SCALAPACK_CDEFS}")
    endif()

    # Build + install ScaLAPACK at BUILD time, after the unified libaocl exists.
    ExternalProject_Add(aocl_scalapack
        ${_sl_src_args}
        PREFIX      "${CMAKE_BINARY_DIR}/aocl-scalapack/ep"
        BINARY_DIR  "${CMAKE_BINARY_DIR}/aocl-scalapack/build"
        INSTALL_DIR "${_sl_install}"
        DEPENDS     ${AOCL_SINGLE_LIBRARY_NAME}
        LIST_SEPARATOR "|"
        CMAKE_ARGS
            -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}
            -DCMAKE_INSTALL_PREFIX=<INSTALL_DIR>
            -DBUILD_SHARED_LIBS=${BUILD_SHARED_LIBS}
            -DENABLE_ILP64=${ENABLE_ILP64}
            -DLAPACK_LIBRARIES=${_sl_unified}
            -DBLAS_LIBRARIES=${_sl_blas_arg}
            -DMPI_BASE_DIR=${MPI_BASE_DIR}
            -DCMAKE_C_COMPILER=${_sl_cc}
            -DCMAKE_POSITION_INDEPENDENT_CODE=ON
            # AOCL-BIY ships only libscalapack, not ScaLAPACK's test suite. Skipping
            # the tests is faster and avoids a Ninja/ifx Fortran .mod name collision
            # (Testing/EIG/link_to_c_globals.mod) that stops the Windows-ninja build.
            -DSCALAPACK_BUILD_TESTS=OFF
            ${_sl_extra_args}
        BUILD_ALWAYS FALSE
        USES_TERMINAL_CONFIGURE TRUE
        USES_TERMINAL_BUILD     TRUE
        USES_TERMINAL_INSTALL   TRUE
    )

    # Install ONLY the ScaLAPACK library binary into the SAME top-level lib/ as the
    # unified libaocl -- ScaLAPACK ships no public headers, so nothing goes to
    # include/. _install() is the real install() (the BIY install() shim swallows
    # component installs); the ExternalProject install step populates ${_sl_install}
    # before the top-level install (run after the build) copies from it.
    #
    # ScaLAPACK puts its archive / import-lib in lib/ but the Windows DLL in
    # Testing/; re-home that DLL into lib/ so it sits beside the unified library,
    # exactly like aocl.dll. Its lib/ also carries cmake/ + pkgconfig/, so match
    # only the scalapack library files (libaocl itself is never copied here -- we
    # pass a working LAPACK_LIBRARIES, so ScaLAPACK skips its BLAS/LAPACK copy).
    _install(DIRECTORY "${_sl_install}/lib/"
             DESTINATION "lib"
             COMPONENT ${AOCL_INSTALL_COMPONENT}
             FILES_MATCHING
                 PATTERN "*scalapack*.a"
                 PATTERN "*scalapack*.so*"
                 PATTERN "*scalapack*.lib"
                 PATTERN "cmake" EXCLUDE
                 PATTERN "pkgconfig" EXCLUDE)
    if(WIN32)
        _install(DIRECTORY "${_sl_install}/Testing/"
                 DESTINATION "lib"
                 COMPONENT ${AOCL_INSTALL_COMPONENT}
                 FILES_MATCHING PATTERN "*scalapack*.dll")
    endif()

    unset(_sl_src_args)
    unset(_sl_path)
    unset(_sl_unified)
    unset(_sl_extra_args)
    unset(_sl_cc)
    unset(_sl_fc)
    unset(_sl_install)
endif()
