# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
#
# Common setup + helpers for the target-based AOCL unified build.
#
# The unified libaocl is built by bringing each enabled AOCL component into THIS
# build via FetchContent + add_subdirectory and compiling the components' OBJECT
# files directly into it (object-level inclusion via $<TARGET_OBJECTS>) -- no
# nested configure / object-file scraping and no merging of finished archives.
#
# This file is included first by the root CMakeLists.txt; it must run in the
# root scope (it is pulled in via include(), which is scope-transparent) so the
# per-component files that follow share the same variables and helpers.
#
# Include order (set by the root): common -> utils -> compression -> blas ->
# lapack -> sparse -> da -> libmem -> libm -> openrng -> fftz -> crypto ->
# unified.

include(FetchContent)

# Root of the (patched) AOCL component sources brought in via add_subdirectory.
if(NOT DEFINED AOCL_LIB_SRC)
    set(AOCL_LIB_SRC "${CMAKE_CURRENT_SOURCE_DIR}/submodules")
endif()

# ---------------------------------------------------------------------------
# Resolve a component's source and register it with FetchContent, so the
# caller's FetchContent_MakeAvailable() pulls it in via add_subdirectory().
#
# Three source modes, highest precedence first (mirrors the classic AOCL-BIY
# driver's local-path > submodules > git-clone selection):
#
#   1. Local path  -- <PFX>_PATH set to a directory that CONTAINS <subdir>
#                     (e.g. -DUTILS_PATH=/work/src -> /work/src/aocl-utils).
#   2. Submodules  -- USE_SOURCES_FROM_SUBMODULES=ON (default) AND the
#                     tree ${AOCL_LIB_SRC}/<subdir> exists (the in-repo
#                     submodules/ checkout).
#   3. Git clone   -- otherwise FetchContent clones <PFX>_GIT_REPOSITORY at
#                     <PFX>_GIT_TAG into ${CMAKE_BINARY_DIR}/<subdir> (the build
#                     tree), naming the clone directory to match the submodule
#                     folder name (<subdir>).
#
# In every mode the source is handed to FetchContent_Declare(); the component
# then calls FetchContent_MakeAvailable(<fc_name>) inside its option block() to
# add_subdirectory() it and compile its objects straight into libaocl.
#
# Args: <fc_name>  FetchContent name (e.g. aocl_utils)
#       <PFX>      cache-variable prefix (e.g. UTILS -> UTILS_PATH,
#                  UTILS_GIT_REPOSITORY, UTILS_GIT_TAG)
#       <subdir>   component folder name under a source root (e.g. aocl-utils)
# ---------------------------------------------------------------------------
macro(aocl_tb_declare_source _fc_name _pfx _subdir)
    if(${_pfx}_PATH)
        # Normalise to forward slashes: this path is embedded verbatim into the
        # generated FetchContent sub-build CMake code, where a Windows backslash
        # path (e.g. C:\Users\...) triggers "Invalid character escape '\U'".
        file(TO_CMAKE_PATH "${${_pfx}_PATH}" _aocl_path)
        set(_aocl_src "${_aocl_path}/${_subdir}")
        message(STATUS "[aocl] ${_fc_name}: using local source ${_aocl_src}")
        FetchContent_Declare(${_fc_name} SOURCE_DIR "${_aocl_src}")
    elseif(USE_SOURCES_FROM_SUBMODULES AND EXISTS "${AOCL_LIB_SRC}/${_subdir}")
        set(_aocl_src "${AOCL_LIB_SRC}/${_subdir}")
        message(STATUS "[aocl] ${_fc_name}: using submodule source ${_aocl_src}")
        FetchContent_Declare(${_fc_name} SOURCE_DIR "${_aocl_src}")
    else()
        set(_aocl_src "${CMAKE_BINARY_DIR}/${_subdir}")
        message(STATUS "[aocl] ${_fc_name}: cloning ${${_pfx}_GIT_REPOSITORY} @ ${${_pfx}_GIT_TAG} into ${_aocl_src}")
        FetchContent_Declare(${_fc_name}
            GIT_REPOSITORY "${${_pfx}_GIT_REPOSITORY}"
            GIT_TAG        "${${_pfx}_GIT_TAG}"
            SOURCE_DIR     "${_aocl_src}")
    endif()
    unset(_aocl_src)
    unset(_aocl_path)
endmacro()

# ---------------------------------------------------------------------------
# Force a build-order dependency from EVERY compiled target a component defines
# (including the internal per-ISA OBJECT libraries it splits itself into) onto a
# set of prerequisite targets -- used to make BLAS-consuming components
# (libflame/LAPACK, DA) wait for the generated, flattened BLIS headers
# (blis.h / cblas.h via flat-header / flat-cblas-header).
#
# add_dependencies() on a component's aggregate library target does NOT propagate
# to the sibling OBJECT libraries that actually compile the sources, so under the
# Unix Makefiles generator (recursive submakes, no global file graph) those
# objects race ahead of the header generation and fail with "'cblas.h' file not
# found". Ninja's single global graph happens to order them, but Make needs the
# dependency stated on each compiled target. Walk the component's whole directory
# subtree and attach the prerequisite to every library/executable target.
function(aocl_tb_force_target_deps_recursive _dir)
    set(_prereqs ${ARGN})
    if(NOT _prereqs)
        return()
    endif()
    get_property(_tgts DIRECTORY "${_dir}" PROPERTY BUILDSYSTEM_TARGETS)
    foreach(_t IN LISTS _tgts)
        get_target_property(_ty ${_t} TYPE)
        if(_ty STREQUAL "OBJECT_LIBRARY" OR _ty STREQUAL "STATIC_LIBRARY"
           OR _ty STREQUAL "SHARED_LIBRARY" OR _ty STREQUAL "EXECUTABLE")
            foreach(_p IN LISTS _prereqs)
                if(TARGET ${_p})
                    add_dependencies(${_t} ${_p})
                endif()
            endforeach()
        endif()
    endforeach()
    get_property(_subs DIRECTORY "${_dir}" PROPERTY SUBDIRECTORIES)
    foreach(_s IN LISTS _subs)
        aocl_tb_force_target_deps_recursive("${_s}" ${_prereqs})
    endforeach()
endfunction()

message(STATUS "=====================================================================")
message(STATUS "AOCL unified build (target-based: FetchContent + add_subdirectory)")
message(STATUS "=====================================================================")

# ---------------------------------------------------------------------------
# All AOCL components are now wired into the target-based flow (no deferred
# libraries remain). AOCL-Crypto additionally requires an external OpenSSL
# (OPENSSL_INSTALL_DIR); aocl_crypto.cmake validates that.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Resolve inter-component dependencies (mirrors the legacy auto-enable): each
# component pulls in everything it links against, so enabling just AOCL-DA (for
# example) still produces a valid build.
# ---------------------------------------------------------------------------
# OpenRNG's AOCL flavour links AOCL-LibM (target 'alm', amdlibm.h), so pull in
# LibM whenever OpenRNG is enabled.
if(ENABLE_AOCL_OPENRNG)
    set(ENABLE_AOCL_LIBM ON)
endif()
# AOCL-Crypto needs AOCL-Utils (CPUID dispatch); enabling Crypto pulls in Utils.
if(ENABLE_AOCL_CRYPTO)
    set(ENABLE_AOCL_UTILS ON)
endif()
if(ENABLE_AOCL_DA)
    set(ENABLE_AOCL_SPARSE ON)
endif()
# AOCL-DA links AOCL-DLP on non-Windows (fp16 GEMM/SYRK path); pull DLP in.
if(ENABLE_AOCL_DA AND NOT WIN32)
    set(ENABLE_AOCL_DLP ON)
endif()
if(ENABLE_AOCL_SPARSE)
    set(ENABLE_AOCL_LAPACK ON)
endif()
if(ENABLE_AOCL_LAPACK)
    set(ENABLE_AOCL_BLAS ON)
    set(ENABLE_AOCL_UTILS ON)
endif()

# Every component still builds its STATIC library: it feeds the per-component
# shared library (whole-archived by aocl_tb_emit_shared) and the per-component
# install_package, even though the unified libaocl is assembled from object files
# (see the OBJECT-library composition model below). Build the static variants
# everywhere; the shared variants (where a component produces them) feed the
# per-component install_package.
set(BUILD_STATIC_LIBS ON)

# Component static archives must be position-independent so they can be linked
# into the shared libaocl.so.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Windows: pin the static multithreaded CRT (/MT) for every component brought in
# via FetchContent. The unified libaocl DLL and every per-component DLL link
# with /MT, so the component object code must match -- otherwise objects compiled
# against the dynamic CRT (/MD, the default for some components such as
# AOCL-Compression) reference __declspec(dllimport) CRT symbols that are absent
# when linking the static runtime. CMP0091 (NEW since our cmake_minimum) makes
# this variable authoritative; it is inherited by the add_subdirectory scopes.
if(WIN32)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

# Opt-in -Werror (/WX on MSVC) across the BIY build; OFF keeps warnings non-fatal.
option(AOCL_BIY_WARNINGS_AS_ERRORS "Treat compiler warnings as errors in the AOCL BIY build" OFF)
if(AOCL_BIY_WARNINGS_AS_ERRORS)
    if(MSVC)
        add_compile_options(/WX)
    else()
        add_compile_options(-Werror)
    endif()
endif()

# ---------------------------------------------------------------------------
# Third-party (external) runtime dependency collection.
#
# The unified library is assembled from whichever components are enabled, and
# each component links against its OWN third-party runtime libraries -- and only
# those: AOCL-Crypto needs OpenSSL, the Fortran components need the Fortran
# runtime, and so on. (OpenMP is the exception: it is resolved automatically via
# find_package(OpenMP) at each link step whenever multithreading is enabled, so
# it is deliberately NOT registered into this list.)
# Instead of maintaining a combined hardcoded list in every consumer, each
# component registers just the libraries IT requires from inside its own
# `if(ENABLE_...)` block -- so a disabled component contributes nothing. The
# de-duplicated union is then consumed identically everywhere it is needed:
#   * the unified libaocl link         (aocl_unified.cmake)
#   * the renamed-library re-link      (rename_symbols*.cmake, via -DSO_LIBS)
#   * the standalone test executables  (test/CMakeLists.txt)
# Add or remove a component and its third-party deps appear/disappear from all
# three steps automatically -- there is nothing to update by hand.
#
# Tokens are stored fully RESOLVED (absolute library paths or literal linker
# flags such as -lfoo/-L<dir>), never CMake imported-target names: the rename
# step runs in a separate `cmake -P` process that cannot dereference targets
# like OpenMP::OpenMP_C. A GLOBAL property (not a directory variable) is used so
# the value is visible in the add_subdirectory(test) scope as well.
#
# Register with aocl_tb_add_external_libs(<token>...); read back with
#   get_property(<var> GLOBAL PROPERTY AOCL_TB_EXTERNAL_LIBS)
define_property(GLOBAL PROPERTY AOCL_TB_EXTERNAL_LIBS
    BRIEF_DOCS "Resolved third-party libraries required by the enabled components"
    FULL_DOCS  "Union of each enabled component's own third-party runtime libs; "
               "consumed by the unified link, the renamed re-link and the tests.")

function(aocl_tb_add_external_libs)
    foreach(_lib IN LISTS ARGN)
        if(NOT _lib STREQUAL "")
            set_property(GLOBAL APPEND PROPERTY AOCL_TB_EXTERNAL_LIBS "${_lib}")
        endif()
    endforeach()
endfunction()

# Register the Fortran runtime the compiled Fortran objects depend on. Called by
# the Fortran-bearing component(s). Resolution is fully automatic -- no library
# name is hardcoded on the platform CMake can probe:
#   * ELF (Linux): CMake already linked a probe with the Fortran compiler and
#     recorded its implicit runtime in CMAKE_Fortran_IMPLICIT_LINK_LIBRARIES /
#     _DIRECTORIES -- gfortran+quadmath for GCC, flang+flangrti+pgmath for
#     AOCC/Flang, and so on. Reuse that verbatim, dropping only the Fortran
#     program entry point (flangmain -- a library/test provides its own main)
#     and the OpenMP *stub* (ompstub -- it must not shadow the real OpenMP
#     runtime the threaded components register).
#   * Windows (Intel ifx): the MSVC-ABI probe leaves the implicit list empty and
#     the Fortran objects instead embed /DEFAULTLIB directives for the *static*
#     runtime (libifcoremt). Pulled into a DLL that way the runtime is never
#     initialised (for_rtl_init is absent) and the DLL fails to load
#     (ERROR_DLL_INIT_FAILED). Link the matching *dynamic* Intel runtime import
#     libs so their own DllMain initialises the RTL. These names are the one
#     place they appear; AOCL_TB_FORTRAN_LIBDIR locates them.
function(aocl_tb_add_fortran_runtime)
    if(WIN32)
        if(AOCL_TB_FORTRAN_LIBDIR)
            foreach(_l IN ITEMS libifcoremd libircmd svml_dispmd ifmodintr libmmd)
                if(EXISTS "${AOCL_TB_FORTRAN_LIBDIR}/${_l}.lib")
                    aocl_tb_add_external_libs("${AOCL_TB_FORTRAN_LIBDIR}/${_l}.lib")
                endif()
            endforeach()
        endif()
        return()
    endif()
    # ELF: add the compiler's implicit search dirs, then its implicit runtime
    # libraries as -l flags (so the driver resolves them exactly as it would when
    # it links a Fortran program itself).
    foreach(_d IN LISTS CMAKE_Fortran_IMPLICIT_LINK_DIRECTORIES)
        aocl_tb_add_external_libs("-L${_d}")
    endforeach()
    foreach(_l IN LISTS CMAKE_Fortran_IMPLICIT_LINK_LIBRARIES)
        if(_l STREQUAL "flangmain" OR _l STREQUAL "ompstub")
            continue()
        endif()
        aocl_tb_add_external_libs("-l${_l}")
    endforeach()
endfunction()

# ---------------------------------------------------------------------------
# OBJECT-library composition model.
#
# The unified libaocl is assembled by compiling every enabled component into one
# or more CMake OBJECT libraries and pulling their object files
# ($<TARGET_OBJECTS:...>) directly into the unified target -- so the single
# self-contained aocl.{dll,lib}/libaocl.{so,a} is built from each component's own
# build targets, not by merging finished static archives. Each component appends
# the object SOURCES that hold ALL of its object code into the GLOBAL property
# AOCL_TB_OBJECT_LIBS (via aocl_tb_add_objects); aocl_unified.cmake consumes them.
#
# Entries may be EITHER an OBJECT-library target name (e.g. "openrngobj") OR an
# already-formed generator expression (e.g. "$<TARGET_OBJECTS:FRAME>"); some
# upstream projects accumulate their objects as genex lists (BLIS/libflame's
# ${OBJECT_LIBRARIES}), others as plain target names. Both forms are normalised to
# a $<TARGET_OBJECTS:...> source here. Position-independent code is already forced
# globally (CMAKE_POSITION_INDEPENDENT_CODE ON above), so every component object
# is PIC and safe to link into the shared libaocl.
#
# AOCL_TB_UNIFIED_BUILD is a globally-visible marker so the component
# CMakeLists can guard their registration calls and still build standalone.
set(AOCL_TB_UNIFIED_BUILD ON CACHE INTERNAL "components are part of the unified AOCL build")
function(aocl_tb_add_objects)
    foreach(_o IN LISTS ARGN)
        if(_o MATCHES "^\\$<")
            # Already a generator expression (e.g. $<TARGET_OBJECTS:FRAME>).
            set_property(GLOBAL APPEND PROPERTY AOCL_TB_OBJECT_LIBS "${_o}")
        else()
            # A bare entry: normally an OBJECT-library target name. But under the
            # Visual Studio generator some components (AOCL-LibM's GAS .S sources)
            # assemble their objects through add_custom_command and contribute the
            # resulting .obj files by PATH rather than as $<TARGET_OBJECTS:...>.
            # Pass such prebuilt object files straight through as link sources; the
            # custom target that produces them is registered separately as a unified
            # dependency (AOCL_TB_DEP_TARGETS), and aocl_unified.cmake marks the
            # paths EXTERNAL_OBJECT in the unified target's own scope.
            if(NOT TARGET ${_o})
                if(_o MATCHES "\\.(o|obj)$")
                    set_property(GLOBAL APPEND PROPERTY AOCL_TB_OBJECT_LIBS "${_o}")
                    continue()
                endif()
                message(FATAL_ERROR "[aocl] object source '${_o}' is not a target "
                                    "and not a generator expression")
            endif()
            get_target_property(_ty ${_o} TYPE)
            if(_ty STREQUAL "OBJECT_LIBRARY")
                set_property(TARGET ${_o} PROPERTY POSITION_INDEPENDENT_CODE ON)
                # Real objects, not LTO bitcode: keep libaocl.a GNU-ld-linkable.
                if(NOT MSVC)
                    set_property(TARGET ${_o} PROPERTY INTERPROCEDURAL_OPTIMIZATION OFF)
                    set_property(TARGET ${_o} APPEND PROPERTY COMPILE_OPTIONS -fno-lto)
                endif()
                set_property(GLOBAL APPEND PROPERTY AOCL_TB_OBJECT_LIBS "$<TARGET_OBJECTS:${_o}>")
            elseif(_ty STREQUAL "INTERFACE_LIBRARY")
                # An INTERFACE aggregator (e.g. AOCL-LibMem's uarch_objlib) holds no
                # objects of its own; it carries its real object code as
                # $<TARGET_OBJECTS:...> entries in INTERFACE_SOURCES, one per inner
                # OBJECT library (lib_zen1, lib_zen2, ...). Harvest those genexes
                # directly so they land in the unified library.
                get_target_property(_isrc ${_o} INTERFACE_SOURCES)
                if(NOT _isrc)
                    message(FATAL_ERROR "[aocl] aocl_tb_add_objects: INTERFACE target "
                                        "'${_o}' carries no INTERFACE_SOURCES objects")
                endif()
                foreach(_s IN LISTS _isrc)
                    if(_s MATCHES "^\\$<TARGET_OBJECTS:(.+)>$")
                        set(_inner "${CMAKE_MATCH_1}")
                        if(TARGET ${_inner})
                            set_property(TARGET ${_inner} PROPERTY POSITION_INDEPENDENT_CODE ON)
                            # Real objects, not LTO bitcode (IFUNC + linkable .a).
                            set_property(TARGET ${_inner} PROPERTY INTERPROCEDURAL_OPTIMIZATION OFF)
                            if(NOT MSVC)
                                set_property(TARGET ${_inner} APPEND PROPERTY COMPILE_OPTIONS -fno-lto)
                            endif()
                        endif()
                        set_property(GLOBAL APPEND PROPERTY AOCL_TB_OBJECT_LIBS "${_s}")
                    endif()
                endforeach()
            else()
                message(FATAL_ERROR "[aocl] aocl_tb_add_objects: '${_o}' is '${_ty}', "
                                    "expected OBJECT_LIBRARY or INTERFACE_LIBRARY")
            endif()
        endif()
    endforeach()
endfunction()

# Build an OBJECT-library twin of an existing in-tree library target and register
# its objects with the unified libaocl. For components whose primary library
# compiles its sources DIRECTLY (no internal OBJECT libraries to register), this
# recompiles the SAME source files into a sibling OBJECT library carrying the SAME
# usage requirements as the original -- its own include dirs, compile definitions
# and options, plus the include dirs propagated by everything it links. All are
# captured with $<TARGET_PROPERTY:...> genexes, which are evaluated at generation
# time, so settings applied to the target AFTER this call are still picked up;
# the call may therefore sit immediately after add_library().
#
# Pre-existing object files in the target's SOURCES (e.g. $<TARGET_OBJECTS:...>
# from sibling OBJECT libraries) are filtered out -- they are not re-compiled here
# and must be registered separately by the caller.
function(aocl_tb_objectify LIBTGT)
    if(NOT TARGET ${LIBTGT})
        message(FATAL_ERROR "[aocl] aocl_tb_objectify: '${LIBTGT}' is not a target")
    endif()
    get_target_property(_srcs ${LIBTGT} SOURCES)
    if(NOT _srcs)
        message(FATAL_ERROR "[aocl] aocl_tb_objectify: '${LIBTGT}' has no SOURCES")
    endif()
    # Split real (compilable) sources from $<TARGET_OBJECTS:...> genexes.
    set(_real_srcs "${_srcs}")
    list(FILTER _real_srcs EXCLUDE REGEX "^\\$<")
    if(NOT _real_srcs)
        # Target has no sources of its own -- it is assembled purely from sibling
        # OBJECT libraries via $<TARGET_OBJECTS:...>. Register those directly (PIC).
        foreach(_s IN LISTS _srcs)
            if(_s MATCHES "^\\$<TARGET_OBJECTS:(.+)>$")
                if(TARGET "${CMAKE_MATCH_1}")
                    set_property(TARGET "${CMAKE_MATCH_1}" PROPERTY POSITION_INDEPENDENT_CODE ON)
                endif()
                set_property(GLOBAL APPEND PROPERTY AOCL_TB_OBJECT_LIBS "${_s}")
            endif()
        endforeach()
        return()
    endif()
    add_library(${LIBTGT}_aoclobjs OBJECT ${_real_srcs})
    set_target_properties(${LIBTGT}_aoclobjs PROPERTIES POSITION_INDEPENDENT_CODE ON)
    target_include_directories(${LIBTGT}_aoclobjs PRIVATE
        $<TARGET_PROPERTY:${LIBTGT},INCLUDE_DIRECTORIES>)
    target_compile_definitions(${LIBTGT}_aoclobjs PRIVATE
        $<TARGET_PROPERTY:${LIBTGT},COMPILE_DEFINITIONS>)
    target_compile_options(${LIBTGT}_aoclobjs PRIVATE
        $<TARGET_PROPERTY:${LIBTGT},COMPILE_OPTIONS>)
    target_link_libraries(${LIBTGT}_aoclobjs PRIVATE
        $<TARGET_PROPERTY:${LIBTGT},LINK_LIBRARIES>)
    set_property(GLOBAL APPEND PROPERTY AOCL_TB_OBJECT_LIBS "$<TARGET_OBJECTS:${LIBTGT}_aoclobjs>")
endfunction()

# Install component that carries the unified deliverable AND the per-component
# staging. The top-level install_package must contain ONLY the unified libaocl;
# every AOCL component keeps its own native install() rules (which would dump the
# component libraries into the top-level prefix), so those native rules are left
# in the default "Unspecified" component and the deliverable is produced by
# installing ONLY this component:
#
#   cmake --install <build> --prefix <pkg> --component aocl
#
# That install runs exactly the unified-library install rules (relative dest, so
# the merged libaocl lands in <pkg>/lib) plus the aocl_tb_* helper rules (absolute
# dest, so each component is staged into build/<comp>/install_package) -- and
# nothing else.
set(AOCL_INSTALL_COMPONENT "aocl")

# --- clean default install (header-honouring shim) ---------------------------
# Each component keeps its own native install() rules, which would dump the
# component LIBRARIES (au_cpuid_static.lib, aoclsparse.lib, ...) into the top-level
# prefix. The unified deliverable is the single libaocl, so install() is overridden
# with a shim that:
#   * HONOURS a component's own header installs -- install(FILES ...) and
#     install(DIRECTORY ...) whose DESTINATION lands in an include/ dir are
#     re-emitted verbatim, so the unified include/ contains EXACTLY the public
#     headers each component ships (e.g. libflame's lapack.h + generated
#     lapacke_mangling.h, aocl-sparse's kernel-templates/), matching every
#     component's individual install-header rules.
#   * SWALLOWS everything else -- install(TARGETS) component libs, EXPORT,
#     PROGRAMS, pkgconfig (.pc), docs, examples, CODE/SCRIPT -- so component
#     libraries never pollute the top-level prefix.
# The real command is available as _install() (auto-aliased by overriding it here);
# the BIY's own deliverable/staging rules call _install() directly. Headers a
# component installs via install(TARGETS ... PUBLIC_HEADER) (not FILES/DIRECTORY)
# are staged separately by aocl_tb_install_component()'s HEADER_DIRS. Net effect of
#
#     cmake --build <build> --target install      (== cmake --install <build>)
#
# is the unified aocl deliverable + a merged include/ faithful to each component.
if(AOCL_TB_UNIFIED_BUILD)
    macro(install)
        set(_aocl_inst_mode "${ARGV0}")
        if("${_aocl_inst_mode}" STREQUAL "FILES" OR "${_aocl_inst_mode}" STREQUAL "DIRECTORY")
            # Honour only header installs: DESTINATION under include/, or the
            # GNUInstallDirs shorthand TYPE INCLUDE (e.g. AOCL-Crypto's alcp/).
            cmake_parse_arguments(_AOCL_INST "" "DESTINATION;TYPE" "" ${ARGV})
            if(_AOCL_INST_DESTINATION MATCHES "(^|/)include($|/)"
               OR "${_AOCL_INST_TYPE}" STREQUAL "INCLUDE")
                # Re-emit verbatim (order preserved -- DIRECTORY installs require
                # DESTINATION before FILES_MATCHING/PATTERN/REGEX). A component's
                # absolute ${CMAKE_INSTALL_PREFIX}/include resolves to the unified
                # deliverable prefix (set at configure), so headers land in the
                # merged include/; a relative include dest honours --prefix.
                _install(${ARGV})
            endif()
        endif()
        # Any other install() form (TARGETS/EXPORT/PROGRAMS/CODE/SCRIPT, or a
        # non-include FILES/DIRECTORY such as .pc/docs/examples) is swallowed.
    endmacro()
endif()

# Intel Fortran runtime lib dir (Windows). libflame's f2c objects request the
# Intel Fortran runtime (ifconsol/libircmt/...) via embedded /DEFAULTLIB
# directives; both the unified DLL and the per-component libflame.dll need that
# lib dir on their link search path. Detected once here so both consumers share
# it (the Visual Studio toolset does not inherit the oneAPI LIB env that the
# Ninja generator's lld-link picks up).
set(AOCL_TB_FORTRAN_LIBDIR "")
if(WIN32 AND ENABLE_AOCL_LAPACK)
    find_program(AOCL_TB_FC NAMES ifx ifort)
    if(AOCL_TB_FC)
        get_filename_component(_fc_bin "${AOCL_TB_FC}" DIRECTORY)
        get_filename_component(_fc_root "${_fc_bin}" DIRECTORY)
        if(EXISTS "${_fc_root}/lib/ifconsol.lib")
            set(AOCL_TB_FORTRAN_LIBDIR "${_fc_root}/lib")
        endif()
    endif()
    if(NOT AOCL_TB_FORTRAN_LIBDIR AND DEFINED ENV{ONEAPI_ROOT})
        file(TO_CMAKE_PATH "$ENV{ONEAPI_ROOT}" _oneapi_root)
        if(EXISTS "${_oneapi_root}/compiler/latest/lib/ifconsol.lib")
            set(AOCL_TB_FORTRAN_LIBDIR "${_oneapi_root}/compiler/latest/lib")
        endif()
    endif()
endif()

# Record a component's STATIC library target in the GLOBAL AOCL_TB_WHOLE_LIBS
# property. NOTE: the unified libaocl is assembled from object files
# ($<TARGET_OBJECTS>, see aocl_tb_add_objects / the composition model above), so
# this list is currently informational only -- no consumer reads it. It is kept
# as a stable hook for components that prefer to advertise their static archive,
# and to validate (FATAL) that the named target actually exists.
function(aocl_tb_add_whole_lib TGT)
    if(NOT TARGET ${TGT})
        message(FATAL_ERROR "[aocl] whole-archive target '${TGT}' does not exist")
    endif()
    set_property(GLOBAL APPEND PROPERTY AOCL_TB_WHOLE_LIBS ${TGT})
endfunction()

# Record a component in the unified manifest. Writes a per-component fragment
# (manifest.d/<key>.cfg) that aocl_gen_manifest.cmake consumes at build time to
# harvest the component version (from its install_package) and list the configure
# options. KEY is the manifest key (utils/blas/lapack/...); COMP_DIR is the
# component's directory under build/ (its install_package lives there). Extra
# args are recorded verbatim as "option=" lines.
#
#   aocl_tb_register_manifest(<key> <comp_dir> [<opt> ...])
function(aocl_tb_register_manifest KEY COMP_DIR)
    set_property(GLOBAL APPEND PROPERTY AOCL_TB_COMPONENTS "${KEY}")
    set(_frag "key=${KEY}\n")
    string(APPEND _frag "install=${CMAKE_BINARY_DIR}/${COMP_DIR}/install_package\n")
    # Record the component's source tree so the manifest generator can harvest a
    # version directly from sources when the install tree has no pkg-config /
    # SONAME version (always the case on Windows). COMP_DIR matches the source
    # folder name under AOCL_LIB_SRC for every component.
    if(AOCL_LIB_SRC AND EXISTS "${AOCL_LIB_SRC}/${COMP_DIR}")
        string(APPEND _frag "source=${AOCL_LIB_SRC}/${COMP_DIR}\n")
    endif()
    foreach(_o IN LISTS ARGN)
        string(APPEND _frag "option=${_o}\n")
    endforeach()
    file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/manifest.d")
    file(WRITE "${CMAKE_BINARY_DIR}/manifest.d/${KEY}.cfg" "${_frag}")
endfunction()

# Produce a component's own install_package under
# build/<comp_dir>/install_package and merge its public headers into the final
# install tree.
#
#   aocl_tb_install_component(<comp_dir> TARGETS <t>... HEADER_DIRS <dir>...
#                             [HEADER_FILES <file>...])
#
# HEADER_DIRS entries copy "<dir>/" contents, filtered to header files only.
# HEADER_FILES are explicit public headers (for components whose public set is
# NOT a whole-directory copy -- e.g. libflame ships the monolithic FLAME.h /
# lapacke.h that sit beside intermediate blis1.h / FLA_f2c.h we must not copy).
function(aocl_tb_install_component COMP_DIR)
    cmake_parse_arguments(TBI "" "" "TARGETS;HEADER_DIRS;HEADER_FILES" ${ARGN})
    set(_pkg "${CMAKE_BINARY_DIR}/${COMP_DIR}/install_package")

    # (a) per-component install_package/lib  -- the component's own STATIC
    #     archive(s). Staged ONLY for a static build: a single linkage switch
    #     governs the per-component deliverable, mirroring aocl_tb_emit_shared()
    #     (which emits the synthesized shared lib ONLY for a shared build). In a
    #     shared build the deliverable is that .dll/.so, so installing the static
    #     archive too would put two libraries -- and, where the static archive and
    #     the shared import lib share a name (e.g. aoclsparse.lib), a colliding
    #     pair -- in the same folder. The targets are ALWAYS registered as unified
    #     dependencies regardless of linkage, because the unified library (shared
    #     OR static) consumes these static archives.
    if(TBI_TARGETS)
        if(NOT AOCL_LINKAGE_EFFECTIVE STREQUAL "shared")
            _install(TARGETS ${TBI_TARGETS}
                    COMPONENT ${AOCL_INSTALL_COMPONENT}
                    RUNTIME DESTINATION "${_pkg}/lib"
                    LIBRARY DESTINATION "${_pkg}/lib"
                    ARCHIVE DESTINATION "${_pkg}/lib")
        endif()
        # These component libraries are EXCLUDE_FROM_ALL; record them so the
        # unified target can depend on them and force their build before install.
        set_property(GLOBAL APPEND PROPERTY AOCL_TB_DEP_TARGETS ${TBI_TARGETS})

        # Ship each target's OWN declared PUBLIC_HEADER set -- defer to the
        # component's install(TARGETS ... PUBLIC_HEADER) rule (via the target's
        # PUBLIC_HEADER property) instead of a hardcoded file list, so a header a
        # component adds later is picked up automatically. Relative entries
        # (libflame uses build-tree-relative paths like include/FLAME.h) are
        # resolved against the owning target's SOURCE_DIR. Done here (not in the
        # install() shim) so it works regardless of the calling scope.
        foreach(_t IN LISTS TBI_TARGETS)
            if(TARGET ${_t})
                get_target_property(_ph ${_t} PUBLIC_HEADER)
                if(_ph)
                    get_target_property(_tsrc ${_t} SOURCE_DIR)
                    set(_ph_files "")
                    foreach(_h IN LISTS _ph)
                        if(IS_ABSOLUTE "${_h}")
                            set(_hp "${_h}")
                        else()
                            set(_hp "${_tsrc}/${_h}")
                        endif()
                        if(EXISTS "${_hp}")
                            list(APPEND _ph_files "${_hp}")
                        endif()
                    endforeach()
                    if(_ph_files)
                        _install(FILES ${_ph_files} DESTINATION "${_pkg}/include"
                                COMPONENT ${AOCL_INSTALL_COMPONENT})
                        _install(FILES ${_ph_files} DESTINATION "include"
                                COMPONENT ${AOCL_INSTALL_COMPONENT})
                    endif()
                endif()
            endif()
        endforeach()
    endif()

    # (b) per-component install_package/include  +  (c) merged final include
    foreach(_hd IN LISTS TBI_HEADER_DIRS)
        if(EXISTS "${_hd}")
            _install(DIRECTORY "${_hd}/"
                    DESTINATION "${_pkg}/include"
                    COMPONENT ${AOCL_INSTALL_COMPONENT}
                    FILES_MATCHING REGEX ".*\\.(h|hh|hpp|H)$")
            _install(DIRECTORY "${_hd}/"
                    DESTINATION "include"
                    COMPONENT ${AOCL_INSTALL_COMPONENT}
                    FILES_MATCHING REGEX ".*\\.(h|hh|hpp|H)$")
        endif()
    endforeach()

    # (d) explicit public header FILES -- curated set for components whose public
    #     headers are NOT a whole-directory copy (e.g. libflame's monolithic
    #     FLAME.h/lapacke.h beside intermediate blis1.h/FLA_f2c.h we must skip).
    set(_tbi_hf "")
    foreach(_f IN LISTS TBI_HEADER_FILES)
        if(EXISTS "${_f}")
            list(APPEND _tbi_hf "${_f}")
        endif()
    endforeach()
    if(_tbi_hf)
        _install(FILES ${_tbi_hf} DESTINATION "${_pkg}/include"
                COMPONENT ${AOCL_INSTALL_COMPONENT})
        _install(FILES ${_tbi_hf} DESTINATION "include"
                COMPONENT ${AOCL_INSTALL_COMPONENT})
    endif()
endfunction()

# ---------------------------------------------------------------------------
# Per-component SHARED library emission (normal / dependency-graph model).
#
# Synthesizes lib<OUTPUT_NAME>.so for a single component by whole-archiving that
# component's OWN static PIC archive(s) only, and links its sibling AOCL component
# .so targets (SO_DEPS) so the result records a normal runtime dependency
# (DT_NEEDED) on them -- exactly like upstream libflame.so needs libblis.so. The
# .so is installed into the component's own install_package/lib (NOT the top-level
# lib, which is reserved for the unified libaocl.{so,a}).
#
#   aocl_tb_emit_shared(<KEY> <comp_dir>
#       OUTPUT_NAME <libname>          # -> lib<libname>.so
#       STATICS     <static_tgt>...    # this component's own archive(s)
#       [SO_DEPS    <aoclso_KEY>...]   # sibling component .so targets (DT_NEEDED)
#       [EXTERNAL   <lib>...])         # extra external libs (libcrypto, gfortran)
#
# The target is named aoclso_<KEY> so dependents can reference it by SO_DEPS.
# Only emitted for shared builds (single linkage switch); a static build keeps the
# per-component .a only.
function(aocl_tb_emit_shared KEY COMP_DIR)
    # AOCL Build-It-Yourself does NOT ship per-component shared libraries: the
    # single, self-contained libaocl is composed directly from every component's
    # OBJECT files (see aocl_unified.cmake together with aocl_tb_objectify() /
    # aocl_tb_add_objects()). This emitter is therefore intentionally a no-op, so
    # the existing per-component call sites stay valid but produce no .so/.dll.
    return()

    # ----- legacy per-component .so/.dll synthesis (unreachable, kept for ref) --
    # Gate on the GLOBAL linkage, not the block-local BUILD_SHARED_LIBS (the
    # component blocks force that OFF for their static merge archive).
    if(NOT AOCL_LINKAGE_EFFECTIVE STREQUAL "shared")
        return()
    endif()
    cmake_parse_arguments(ES "" "OUTPUT_NAME" "STATICS;SO_DEPS;EXTERNAL" ${ARGN})
    if(NOT ES_STATICS)
        message(FATAL_ERROR "[aocl] aocl_tb_emit_shared(${KEY}): no STATICS given")
    endif()

    set(_tgt "aoclso_${KEY}")

    # Shared, (essentially empty) translation unit; content comes from archives.
    set(_dummy "${CMAKE_BINARY_DIR}/aocl_tb_so_dummy.c")
    if(NOT EXISTS "${_dummy}")
        file(WRITE "${_dummy}" "/* per-component AOCL shared library: content from component archives */\n")
    endif()

    add_library(${_tgt} SHARED "${_dummy}")
    set_target_properties(${_tgt} PROPERTIES
        OUTPUT_NAME "${ES_OUTPUT_NAME}"
        POSITION_INDEPENDENT_CODE ON
        LINKER_LANGUAGE CXX
        EXCLUDE_FROM_ALL ON)
    # Build the synthesized .so/.dll (and, on Windows, its import library) in a
    # dedicated per-component directory so its output paths never collide with
    # the component's static archive (e.g. a static 'aoclsparse.lib' and the
    # shared 'aoclsparse.dll' import lib 'aoclsparse.lib' would otherwise both
    # resolve to the same file).
    set(_so_outdir "${CMAKE_BINARY_DIR}/${COMP_DIR}/so")
    set_target_properties(${_tgt} PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY "${_so_outdir}"
        LIBRARY_OUTPUT_DIRECTORY "${_so_outdir}"
        ARCHIVE_OUTPUT_DIRECTORY "${_so_outdir}")
    if(NOT WIN32 AND CMAKE_CXX_COMPILER_ID MATCHES "Clang")
        target_link_options(${_tgt} PRIVATE "-fuse-ld=ld")
    endif()

    # Whole-archive this component's OWN static archive(s) only.
    set(_whole "")
    foreach(_s IN LISTS ES_STATICS)
        if(TARGET ${_s})
            list(APPEND _whole "$<TARGET_FILE:${_s}>")
        endif()
    endforeach()

    # Sibling component .so dependencies (filter to those actually present).
    set(_so_deps "")
    foreach(_d IN LISTS ES_SO_DEPS)
        if(TARGET ${_d})
            list(APPEND _so_deps ${_d})
        endif()
    endforeach()

    # OpenMP runtime, mirroring the unified library.
    set(_omp "")
    if(ENABLE_MULTITHREADING)
        if(WIN32 OR NOT OpenMP_libomp_LIBRARY)
            set(_omp OpenMP::OpenMP_C)
        else()
            set(_omp "${OpenMP_libomp_LIBRARY}")
        endif()
    endif()

    if(WIN32)
        # lld-link / link.exe ignore GNU --whole-archive AND CMake's
        # WINDOWS_EXPORT_ALL_SYMBOLS does not follow archives pulled in via
        # /WHOLEARCHIVE link options, so a DLL built that way would export
        # nothing (and siblings could not resolve against it). Mirror the unified
        # DLL: merge this component's own archive(s) into one temp .lib, generate
        # a .def re-exporting every external symbol from it (llvm-nm), then build
        # the DLL by whole-archiving the temp .lib with that .def. Sibling
        # component DLLs (SO_DEPS) supply their import libraries, so cross-DLL
        # references (e.g. libflame.dll -> blis.dll for cgeru_) resolve normally.
        get_filename_component(_llvm_bindir "${CMAKE_AR}" DIRECTORY)
        find_program(AOCL_LLVM_NM NAMES llvm-nm HINTS "${_llvm_bindir}")
        if(NOT AOCL_LLVM_NM)
            message(FATAL_ERROR "[aocl] llvm-nm not found; required to generate the "
                                "Windows export .def for per-component DLL ${ES_OUTPUT_NAME}")
        endif()

        set(_own_lib "${_so_outdir}/${KEY}_own.lib")
        add_custom_command(OUTPUT "${_own_lib}"
            COMMAND ${CMAKE_AR} /NOLOGO "/OUT:${_own_lib}" ${_whole}
            DEPENDS ${ES_STATICS}
            COMMENT "Merging ${ES_OUTPUT_NAME} archive(s) for DLL export list"
            COMMAND_EXPAND_LISTS
            VERBATIM)

        set(_so_def "${_so_outdir}/${ES_OUTPUT_NAME}.def")
        add_custom_command(OUTPUT "${_so_def}"
            COMMAND ${CMAKE_COMMAND}
                    "-DNM=${AOCL_LLVM_NM}"
                    "-DLIB=${_own_lib}"
                    "-DOUT=${_so_def}"
                    "-DLIBNAME=${ES_OUTPUT_NAME}"
                    -P "${CMAKE_CURRENT_LIST_DIR}/aocl_gen_def.cmake"
            DEPENDS "${_own_lib}" "${CMAKE_CURRENT_LIST_DIR}/aocl_gen_def.cmake"
            COMMENT "Generating ${ES_OUTPUT_NAME}.def (per-component export list)"
            VERBATIM)
        add_custom_target(${_tgt}_def DEPENDS "${_so_def}")

        set_target_properties(${_tgt} PROPERTIES
            MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
        foreach(_w IN LISTS _whole)
            target_link_options(${_tgt} PRIVATE "/WHOLEARCHIVE:${_w}")
        endforeach()
        target_link_options(${_tgt} PRIVATE "/DEF:${_so_def}" "/FORCE:MULTIPLE")
        set_target_properties(${_tgt} PROPERTIES LINK_DEPENDS "${_so_def}")
        target_link_libraries(${_tgt} PRIVATE ${_so_deps} ${ES_EXTERNAL} ${_omp})
        # libflame's Fortran objects (and dependents) need the Intel Fortran
        # runtime import libs.
        if(AOCL_TB_FORTRAN_LIBDIR)
            target_link_directories(${_tgt} PRIVATE "${AOCL_TB_FORTRAN_LIBDIR}")
        endif()
        add_dependencies(${_tgt} ${_tgt}_def ${ES_STATICS})
    else()
        target_link_libraries(${_tgt} PRIVATE
            -Wl,--whole-archive ${_whole} -Wl,--no-whole-archive
            ${_so_deps} ${ES_EXTERNAL} ${_omp})
        add_dependencies(${_tgt} ${ES_STATICS})
    endif()

    # Install into the component's own install_package/lib (built on demand via
    # the AOCL_TB_DEP_TARGETS force-build hook the unified target wires up).
    set(_pkg "${CMAKE_BINARY_DIR}/${COMP_DIR}/install_package")
    if(WIN32)
        _install(TARGETS ${_tgt}
                COMPONENT ${AOCL_INSTALL_COMPONENT}
                RUNTIME DESTINATION "${_pkg}/lib"
                ARCHIVE DESTINATION "${_pkg}/lib")
    else()
        _install(TARGETS ${_tgt}
                COMPONENT ${AOCL_INSTALL_COMPONENT}
                LIBRARY DESTINATION "${_pkg}/lib")
    endif()
    set_property(GLOBAL APPEND PROPERTY AOCL_TB_DEP_TARGETS ${_tgt})

    if(WIN32)
        message(STATUS "[aocl] per-component shared: ${ES_OUTPUT_NAME}.dll "
                       "(${COMP_DIR}) <- ${ES_STATICS} (needs: ${_so_deps})")
    else()
        message(STATUS "[aocl] per-component shared: lib${ES_OUTPUT_NAME}.so "
                       "(${COMP_DIR}) <- ${ES_STATICS} (needs: ${_so_deps})")
    endif()
endfunction()
