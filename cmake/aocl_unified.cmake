# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
#
# Assemble the unified libaocl -- the final step of the target-based build.
#
# PURPOSE
#   Build the single, self-contained libaocl directly from the OBJECT files that
#   every enabled component produced IN THIS BUILD (FetchContent +
#   add_subdirectory; see aocl_targets_common.cmake + the per-component files).
#   Each component registered its compiled objects as $<TARGET_OBJECTS:...>
#   generator expressions in the global AOCL_TB_OBJECT_LIBS property; the unified
#   static archive and shared library are both compiled from exactly those
#   objects, so the result has no inter-AOCL runtime dependency and no
#   per-component DLLs. This file is included LAST by the root CMakeLists.
#
# HOW IT WORKS (step by step)
#   1. Read the registered objects (AOCL_TB_OBJECT_LIBS) and build-order deps
#      (AOCL_TB_DEP_TARGETS) from the global properties; FATAL if none.
#   2. enable_language(Fortran) in THIS (root) scope when LAPACK/DA are enabled,
#      since their Fortran $<TARGET_OBJECTS> need the Fortran rules here.
#   3. Decide shared vs static from the global AOCL_LINKAGE_EFFECTIVE knob (NOT
#      BUILD_SHARED_LIBS, which the component blocks force OFF).
#   4. Collect runtime/external link libs (AOCL_TB_LINK_LIBS, OpenMP). On Windows
#      locate the Intel Fortran runtime lib dir (ifconsol/libircmt/...) and add
#      it to the link search path so BOTH the Ninja and Visual Studio generators
#      resolve the Fortran runtime.
#   5. Generate the self-describing manifest at BUILD time (after components
#      install, so versions can be harvested): emit aocl_manifest.c + a text
#      sidecar via aocl_gen_manifest.cmake, compile the C into aocl_manifest_obj,
#      and embed it as a ".aocl_manifest" section in the library.
#   6. Create the unified static archive from all component objects + the
#      manifest object (raw external .obj entries are marked EXTERNAL_OBJECT /
#      GENERATED for the VS generator). On shared builds also create the unified
#      shared library from the same objects.
#   7. On Windows, synthesize a module-definition (.def) file from the merged
#      archive (aocl_gen_def.cmake) so the DLL re-exports every symbol; on Unix
#      default ELF visibility handles it.
#   8. Install libaocl.{so,a} / aocl.{dll,lib} + the manifest text sidecar under
#      the AOCL install component.

get_property(_object_libs GLOBAL PROPERTY AOCL_TB_OBJECT_LIBS)
get_property(_dep_targets GLOBAL PROPERTY AOCL_TB_DEP_TARGETS)

if(NOT _object_libs)
    message(FATAL_ERROR "[aocl] no component objects registered to build libaocl")
endif()
list(REMOVE_DUPLICATES _object_libs)
if(_dep_targets)
    list(REMOVE_DUPLICATES _dep_targets)
endif()

# Reverse the component object-source list at the LOGICAL-genex level. Most
# entries are simple "$<TARGET_OBJECTS:foo>", but a component that selects its
# LP64 vs ILP64 object library with a conditional (e.g. libflame) registers a
# compound genex containing ';', which CMake stores as several list elements.
# A naive list(REVERSE) would split those fragments and leave an inactive-branch
# "$<TARGET_OBJECTS:lapacke_64_obj>" as a standalone element evaluated
# unconditionally -> "no such target". This helper regroups consecutive fragments
# until the '<'/'>' nesting is balanced (one whole genex per group), reverses the
# groups, and restores the internal ';' (carried through a sentinel).
function(_aocl_reverse_object_libs _out)
    set(_atoms "")
    set(_cur "")
    set(_have FALSE)
    set(_depth 0)
    foreach(_e IN LISTS ARGN)
        if(_have)
            string(APPEND _cur "@@AOCLSEMI@@${_e}")
        else()
            set(_cur "${_e}")
            set(_have TRUE)
        endif()
        string(REGEX MATCHALL "<" _opens "${_e}")
        string(REGEX MATCHALL ">" _closes "${_e}")
        list(LENGTH _opens _no)
        list(LENGTH _closes _nc)
        math(EXPR _depth "${_depth} + ${_no} - ${_nc}")
        if(NOT _depth GREATER 0)
            list(APPEND _atoms "${_cur}")
            set(_cur "")
            set(_have FALSE)
            set(_depth 0)
        endif()
    endforeach()
    if(_have)
        list(APPEND _atoms "${_cur}")
    endif()
    list(REVERSE _atoms)
    string(JOIN ";" _joined ${_atoms})
    string(REPLACE "@@AOCLSEMI@@" ";" _joined "${_joined}")
    set(${_out} "${_joined}" PARENT_SCOPE)
endfunction()

# Some components contribute Fortran object files (libflame/LAPACK and the
# data-analytics lbfgsb/nlls solvers). Those objects are compiled straight into
# the unified targets via $<TARGET_OBJECTS:...>, which requires the Fortran
# language rules (CMAKE_Fortran_COMPILE_OBJECT, ...) to be available in THIS
# (root) directory scope -- the components only enable Fortran inside their own
# child scopes, so enable it here too before the unified targets are created.
if(ENABLE_AOCL_LAPACK OR ENABLE_AOCL_DA)
    enable_language(Fortran)
    # Fortran is now enabled in this (root) scope, so CMake has recorded the
    # compiler's implicit runtime (CMAKE_Fortran_IMPLICIT_LINK_LIBRARIES). Register
    # the Fortran runtime the compiled Fortran objects (libflame, DA solvers)
    # depend on into the shared external-deps list -- resolved automatically, never
    # hardcoded (see aocl_tb_add_fortran_runtime() in aocl_targets_common.cmake).
    aocl_tb_add_fortran_runtime()
endif()

# Whether the unified library is shared. Driven by the global AOCL linkage knob,
# NOT BUILD_SHARED_LIBS (the component blocks force that OFF so they emit static
# OBJECT code, the only thing a single self-contained library can be built from).
if(AOCL_LINKAGE_EFFECTIVE STREQUAL "shared")
    set(_aocl_shared TRUE)
else()
    set(_aocl_shared FALSE)
endif()

# Runtime/external link libraries the merged library needs -- the de-duplicated
# union of every enabled component's OWN third-party deps (OpenSSL from Crypto,
# the Fortran runtime from LAPACK, OpenMP from the threaded components, ...),
# each registered via aocl_tb_add_external_libs() from inside its component block.
# The exact same list drives the renamed re-link and the test executables, so the
# three linking steps can never drift apart.
get_property(_runtime_libs GLOBAL PROPERTY AOCL_TB_EXTERNAL_LIBS)
if(_runtime_libs)
    list(REMOVE_DUPLICATES _runtime_libs)
endif()
# OpenMP is resolved automatically whenever multithreading is enabled -- it is
# deliberately kept OUT of the per-component external-deps list and found via
# find_package(OpenMP) at each link step instead.
if(ENABLE_MULTITHREADING)
    if(WIN32 OR NOT OpenMP_libomp_LIBRARY)
        find_package(OpenMP QUIET)
        list(APPEND _runtime_libs OpenMP::OpenMP_C)
    else()
        list(APPEND _runtime_libs "${OpenMP_libomp_LIBRARY}")
    endif()
endif()

# Intel Fortran runtime library directory (Windows) -- detected once in
# aocl_targets_common.cmake as AOCL_TB_FORTRAN_LIBDIR and shared here.
# libflame (LAPACK) compiles Fortran translation units with Intel ifx/ifort; the
# resulting objects embed '/DEFAULTLIB:ifconsol', '/DEFAULTLIB:libircmt', ...
# directives. When the unified library is linked these Intel runtime import libs
# must be resolvable. With the Ninja generator lld-link inherits the LIB env that
# oneAPI's setvars.bat populated, but the Visual Studio (MSBuild/ClangCl) toolset
# rebuilds its own LIB and drops the Intel compiler lib dir, so the final link
# fails with "could not open 'ifconsol.lib'". Adding that lib dir to the target's
# search path (below) makes BOTH generators succeed.
set(_aocl_fortran_libdir "${AOCL_TB_FORTRAN_LIBDIR}")

# Self-describing manifest (component list + per-library version & options +
# build configuration). Generated at BUILD time -- after the component
# ExternalProjects install -- so each component's version can be harvested from
# its install tree. Embedded into both libaocl.{so,a} as a ".aocl_manifest" ELF
# section (+ aocl_get_manifest() accessor) and shipped as a plain-text sidecar,
# so a delivered library reveals what it contains without `nm` inspection.
set(_manifest_c   "${CMAKE_BINARY_DIR}/aocl_manifest.c")
set(_manifest_txt "${CMAKE_BINARY_DIR}/aocl_manifest.txt")

get_property(_components GLOBAL PROPERTY AOCL_TB_COMPONENTS)
if(_components)
    list(REMOVE_DUPLICATES _components)
endif()
string(REPLACE ";" "|" _components_arg "${_components}")

if(_aocl_shared)
    set(_mf_linkage "shared")
else()
    set(_mf_linkage "static")
endif()

# Library file base name as actually produced: Windows has no "lib" prefix
# (aocl.dll / aocl.lib), every other platform does (libaocl.so / libaocl.a).
if(WIN32)
    set(_mf_libname "${PROJECT_NAME}")
else()
    set(_mf_libname "lib${PROJECT_NAME}")
endif()
if(ENABLE_ILP64)
    set(_mf_int "ILP64 (64-bit integers)")
else()
    set(_mf_int "LP64 (32-bit integers)")
endif()
if(ENABLE_MULTITHREADING)
    set(_mf_threading "multithreaded (OpenMP)")
else()
    set(_mf_threading "single-threaded")
endif()
if(BLIS_CONFIG_FAMILY)
    set(_mf_arch "${BLIS_CONFIG_FAMILY}")
else()
    set(_mf_arch "amdzen")
endif()
if(SYMBOL_RENAME_PREFIX)
    set(_mf_prefix "${SYMBOL_RENAME_PREFIX}")
else()
    set(_mf_prefix "(none)")
endif()

# Resolve the OpenMP runtime name (libiomp5 / libgomp / libomp / ...). Prefer the
# actual library wired in; otherwise infer from the compiler ID.
if(ENABLE_MULTITHREADING)
    if(OpenMP_libomp_LIBRARY)
        get_filename_component(_mf_threadlib "${OpenMP_libomp_LIBRARY}" NAME)
        string(REGEX REPLACE "\\.(so|a|dylib|lib)([0-9.]*)$" "" _mf_threadlib "${_mf_threadlib}")
    elseif(CMAKE_C_COMPILER_ID MATCHES "Intel")
        set(_mf_threadlib "libiomp5")
    elseif(CMAKE_C_COMPILER_ID MATCHES "Clang")
        set(_mf_threadlib "libomp")
    else()
        set(_mf_threadlib "libgomp")
    endif()
else()
    set(_mf_threadlib "none")
endif()

# Resolve a compiler-family label. CMAKE_C_COMPILER_ID reports AOCC and
# Intel's clang-based compilers both as "Clang", so disambiguate via the
# compiler's --version banner.
if(CMAKE_C_COMPILER_ID STREQUAL "GNU")
    set(_mf_compiler "GCC ${CMAKE_C_COMPILER_VERSION}")
elseif(CMAKE_C_COMPILER_ID MATCHES "Clang")
    execute_process(COMMAND "${CMAKE_C_COMPILER}" --version
        OUTPUT_VARIABLE _cc_banner ERROR_VARIABLE _cc_banner
        OUTPUT_STRIP_TRAILING_WHITESPACE)
    if(_cc_banner MATCHES "AOCC_?([0-9]+\\.[0-9]+\\.[0-9]+)")
        set(_mf_compiler "Clang ${CMAKE_C_COMPILER_VERSION} (AOCC ${CMAKE_MATCH_1})")
    elseif(_cc_banner MATCHES "AOCC")
        set(_mf_compiler "Clang ${CMAKE_C_COMPILER_VERSION} (AOCC)")
    elseif(CMAKE_C_COMPILER_ID STREQUAL "IntelLLVM" OR _cc_banner MATCHES "Intel")
        set(_mf_compiler "Clang ${CMAKE_C_COMPILER_VERSION} (Intel oneAPI)")
    else()
        set(_mf_compiler "Clang ${CMAKE_C_COMPILER_VERSION} (LLVM)")
    endif()
elseif(CMAKE_C_COMPILER_ID MATCHES "Intel")
    set(_mf_compiler "Intel ${CMAKE_C_COMPILER_VERSION}")
elseif(CMAKE_C_COMPILER_ID MATCHES "MSVC")
    set(_mf_compiler "MSVC ${CMAKE_C_COMPILER_VERSION}")
else()
    set(_mf_compiler "${CMAKE_C_COMPILER_ID} ${CMAKE_C_COMPILER_VERSION}")
endif()

# Re-run whenever a component rebuilds (its per-component static target) or its
# recorded config fragment changes (rewritten every configure).
set(_manifest_deps ${_dep_targets})
foreach(_k IN LISTS _components)
    list(APPEND _manifest_deps "${CMAKE_BINARY_DIR}/manifest.d/${_k}.cfg")
endforeach()

add_custom_command(
    OUTPUT "${_manifest_c}" "${_manifest_txt}"
    COMMAND "${CMAKE_COMMAND}"
        "-DPROJECT_NAME=${PROJECT_NAME}"
        "-DOUT_C=${_manifest_c}"
        "-DOUT_TXT=${_manifest_txt}"
        "-DMANIFEST_DIR=${CMAKE_BINARY_DIR}/manifest.d"
        "-DCOMPONENTS=${_components_arg}"
        "-DLINKAGE=${_mf_linkage}"
        "-DLIBNAME=${_mf_libname}"
        "-DINTSIZE=${_mf_int}"
        "-DTHREADING=${_mf_threading}"
        "-DTHREADLIB=${_mf_threadlib}"
        "-DARCH=${_mf_arch}"
        "-DSYMPREFIX=${_mf_prefix}"
        "-DBUILDTYPE=${CMAKE_BUILD_TYPE}"
        "-DCOMPILER=${_mf_compiler}"
        -P "${CMAKE_CURRENT_LIST_DIR}/aocl_gen_manifest.cmake"
    DEPENDS ${_manifest_deps} "${CMAKE_CURRENT_LIST_DIR}/aocl_gen_manifest.cmake"
    COMMENT "Generating AOCL manifest (components + versions + options)"
    VERBATIM)
set_source_files_properties("${_manifest_c}" PROPERTIES GENERATED TRUE)

add_library(aocl_manifest_obj OBJECT "${_manifest_c}")
set_target_properties(aocl_manifest_obj PROPERTIES POSITION_INDEPENDENT_CODE ON)
# Keep this TU's runtime consistent with the component archives (/MT) so the
# Windows DLL link does not mix static (libcpmt) and dynamic (ucrt) C runtimes.
if(WIN32)
    set_target_properties(aocl_manifest_obj PROPERTIES
        MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()
_install(FILES "${_manifest_txt}" DESTINATION lib COMPONENT ${AOCL_INSTALL_COMPONENT})

# --- unified static archive (compile every component object straight in) -----
# In a static build this IS the deliverable (aocl.lib / libaocl.a). In a shared
# build it is an auxiliary named with a "_static" suffix so it does not collide
# with the DLL's import library (aocl.lib); it is not shipped, but is still built
# because the Windows export .def is generated from it.
if(_aocl_shared)
    set(_static_tgt ${PROJECT_NAME}_static)
else()
    set(_static_tgt ${PROJECT_NAME})
endif()

# A few component objects are contributed by PATH rather than as
# $<TARGET_OBJECTS:...> genexes -- under the Visual Studio generator AOCL-LibM
# assembles its GAS .S sources via custom commands and hands back the .obj paths.
# Mark those entries EXTERNAL_OBJECT here, in the unified target's OWN directory
# scope, so the static/shared targets link them as prebuilt objects instead of
# trying to compile them. The custom targets that produce the files are in
# _dep_targets, so the unified targets already build them first.
foreach(_obj IN LISTS _object_libs)
    if(NOT _obj MATCHES "^\\$<")
        set_source_files_properties("${_obj}" PROPERTIES
            EXTERNAL_OBJECT TRUE GENERATED TRUE)
    endif()
endforeach()

add_library(${_static_tgt} STATIC
    ${_object_libs} $<TARGET_OBJECTS:aocl_manifest_obj>)
set_target_properties(${_static_tgt} PROPERTIES
    POSITION_INDEPENDENT_CODE ON
    LINKER_LANGUAGE CXX)
if(WIN32)
    set_target_properties(${_static_tgt} PROPERTIES
        MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()
# In a shared build the static target carries a "_static" suffix so its file name
# cannot collide with the deliverable. On Linux a static archive (.a) and a shared
# object (.so) never collide, so give the auxiliary the plain base name and ship a
# real libaocl.a next to libaocl.so. On Windows the suffix must stay (the static
# archive's base name would clash with the DLL import library aocl.lib).
if(_aocl_shared AND NOT WIN32)
    set_target_properties(${_static_tgt} PROPERTIES OUTPUT_NAME "${PROJECT_NAME}")
endif()
if(_dep_targets)
    add_dependencies(${_static_tgt} ${_dep_targets})
endif()
# Install the unified static archive to the top-level install_package/lib for a
# static build (the deliverable then) and, on Linux, also for a shared build so
# both libaocl.so and libaocl.a ship together. On Windows a shared build keeps the
# static archive as an unshipped auxiliary (used only to generate the export .def).
if(NOT _aocl_shared OR NOT WIN32)
    _install(TARGETS ${_static_tgt}
            COMPONENT ${AOCL_INSTALL_COMPONENT}
            ARCHIVE DESTINATION lib)
endif()

# Windows symbol renaming needs the unified static archive present in the install
# tree as aocl_static.lib: rename_symbols.cmake globs lib/*_static.lib, renames it,
# and (shared build) re-links a fully renamed aocl.dll from it via /WHOLEARCHIVE.
# A shared build already produces aocl_static.lib but does not ship it; a static
# build's deliverable is aocl.lib, so install a second copy under the aocl_static
# name. Only emitted when renaming is requested -- not part of a normal delivery.
if(WIN32 AND SYMBOL_RENAME_PREFIX)
    if(_aocl_shared)
        _install(TARGETS ${_static_tgt}
                COMPONENT ${AOCL_INSTALL_COMPONENT}
                ARCHIVE DESTINATION lib)
    else()
        _install(FILES "$<TARGET_FILE:${_static_tgt}>"
                COMPONENT ${AOCL_INSTALL_COMPONENT}
                DESTINATION lib
                RENAME aocl_static.lib)
    endif()
endif()

# --- unified shared libaocl.so (ELF) ----------------------------------------
# On ELF platforms every component object is compiled straight into the shared
# object, so all default-visibility symbols are exported automatically -- no
# whole-archive wrapping or export list is required.
if(_aocl_shared AND NOT WIN32)
    add_library(${PROJECT_NAME} SHARED
        ${_object_libs} $<TARGET_OBJECTS:aocl_manifest_obj>)
    set_target_properties(${PROJECT_NAME} PROPERTIES
        POSITION_INDEPENDENT_CODE ON
        LINKER_LANGUAGE CXX)
    if(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
        # Use LLVM's lld for Clang/AOCC: harmless for plain ELF objects and the
        # safer choice across the mixed C/C++/Fortran object set.
        target_link_options(${PROJECT_NAME} PRIVATE "-fuse-ld=lld")
    endif()
    target_link_libraries(${PROJECT_NAME} PRIVATE ${_runtime_libs})
    if(_dep_targets)
        add_dependencies(${PROJECT_NAME} ${_dep_targets})
    endif()
    # Build the unified static archive (libaocl.a) together with the shared
    # library so a default `--target aocl` Linux build produces and ships both.
    add_dependencies(${PROJECT_NAME} ${_static_tgt})

    _install(TARGETS ${PROJECT_NAME}
            COMPONENT ${AOCL_INSTALL_COMPONENT}
            LIBRARY DESTINATION lib
            ARCHIVE DESTINATION lib
            RUNTIME DESTINATION lib)
endif()

# --- unified aocl.dll (Windows) ---------------------------------------------
# A Windows DLL exports only explicitly named symbols, so synthesise the
# equivalent of the default-visibility ELF shared object: generate a .def that
# re-exports every external symbol found in the unified static archive
# (aocl_static.lib), then build the DLL from the same component objects. CMake
# auto-links the standard Windows import libraries (advapi32, kernel32, ...) that
# the components depend on (CryptGenRandom, etc.).
if(_aocl_shared AND WIN32)
    get_filename_component(_llvm_bindir "${CMAKE_AR}" DIRECTORY)
    find_program(AOCL_LLVM_NM NAMES llvm-nm HINTS "${_llvm_bindir}")
    if(NOT AOCL_LLVM_NM)
        message(FATAL_ERROR "[aocl] llvm-nm not found; required to generate the "
                            "Windows export .def for the unified DLL")
    endif()

    set(_def "${CMAKE_BINARY_DIR}/${PROJECT_NAME}.def")
    # Generate the export .def directly from the component OBJECT files -- the
    # shared library needs NO static archive as an intermediate. ${_object_libs}
    # holds $<TARGET_OBJECTS:...> genexes, some nested inside compound conditional
    # genexes (libflame LP64/ILP64) that cannot be safely list-split. Instead,
    # harvest every TARGET_OBJECTS name it references (MATCHALL sees the nested
    # ones too), keep the ones that are real targets in THIS configuration, and
    # re-emit them as clean simple genexes -- safe to $<JOIN:> into an object-list
    # file and to use verbatim as the .def's build dependency (so it regenerates
    # whenever any component object is recompiled).
    string(REGEX MATCHALL "TARGET_OBJECTS:[A-Za-z0-9_.+-]+" _to_refs "${_object_libs}")
    set(_def_obj_genexes "$<TARGET_OBJECTS:aocl_manifest_obj>")
    set(_def_obj_targets "aocl_manifest_obj")
    foreach(_ref IN LISTS _to_refs)
        string(REPLACE "TARGET_OBJECTS:" "" _tname "${_ref}")
        if(TARGET ${_tname})
            list(APPEND _def_obj_genexes "$<TARGET_OBJECTS:${_tname}>")
            list(APPEND _def_obj_targets "${_tname}")
        endif()
    endforeach()
    list(REMOVE_DUPLICATES _def_obj_genexes)
    list(REMOVE_DUPLICATES _def_obj_targets)
    # Some components (e.g. AOCL-LibM's GAS .S sources under the VS generator)
    # contribute prebuilt .obj files by PATH rather than as a $<TARGET_OBJECTS:...>
    # target; include those too so their symbols land in the export list. The
    # custom targets that produce them are in ${_dep_targets} (added to DEPENDS).
    set(_def_obj_paths "")
    foreach(_e IN LISTS _object_libs)
        if(NOT _e MATCHES "^\\$<")
            list(APPEND _def_obj_paths "${_e}")
        endif()
    endforeach()

    set(_def_objlist "${CMAKE_BINARY_DIR}/${PROJECT_NAME}_def_objs.txt")
    if(_def_obj_paths)
        string(REPLACE ";" "\n" _def_paths_block "${_def_obj_paths}")
        file(GENERATE OUTPUT "${_def_objlist}"
            CONTENT "$<JOIN:${_def_obj_genexes},\n>\n${_def_paths_block}\n")
    else()
        file(GENERATE OUTPUT "${_def_objlist}"
            CONTENT "$<JOIN:${_def_obj_genexes},\n>\n")
    endif()
    add_custom_command(OUTPUT "${_def}"
        COMMAND ${CMAKE_COMMAND}
                "-DNM=${AOCL_LLVM_NM}"
                "-DOBJLIST=${_def_objlist}"
                "-DOUT=${_def}"
                "-DLIBNAME=${PROJECT_NAME}"
                -P "${CMAKE_CURRENT_LIST_DIR}/aocl_gen_def.cmake"
        DEPENDS ${_def_obj_genexes} ${_dep_targets} "${_def_objlist}"
                "${CMAKE_CURRENT_LIST_DIR}/aocl_gen_def.cmake"
        COMMENT "Generating ${PROJECT_NAME}.def (Windows export list, from component objects)"
        VERBATIM)
    add_custom_target(${PROJECT_NAME}_def DEPENDS "${_def}")
    # Guarantee every contributing object is compiled before llvm-nm scans it
    # (build ORDER); the $<TARGET_OBJECTS:...> entries in the command DEPENDS
    # additionally re-run the scan when an object's symbols change.
    add_dependencies(${PROJECT_NAME}_def ${_def_obj_targets})
    if(_dep_targets)
        add_dependencies(${PROJECT_NAME}_def ${_dep_targets})
    endif()

    # Compose the DLL directly from the component OBJECT libraries -- no static
    # library target participates in the shared-library link. The objects must be
    # emitted in REVERSE registration order (see the long note below the def) to
    # get a loadable C++ static-initialiser order. _aocl_reverse_object_libs()
    # reverses at the logical-genex level so compound conditional genexes (e.g.
    # libflame's LP64/ILP64 selection, which embed ';' and span several list
    # elements) are kept intact -- a naive list(REVERSE) would split them and
    # evaluate an inactive branch's $<TARGET_OBJECTS:...> unconditionally.
    _aocl_reverse_object_libs(_object_libs_rev ${_object_libs})
    add_library(${PROJECT_NAME} SHARED
        ${_object_libs_rev} $<TARGET_OBJECTS:aocl_manifest_obj>)
    set_target_properties(${PROJECT_NAME} PROPERTIES
        LINKER_LANGUAGE CXX
        MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    target_link_options(${PROJECT_NAME} PRIVATE "/DEF:${_def}")
    # The shared library is built straight from the component object libraries
    # (${_object_libs}) -- no static archive is linked in. A raw FORWARD-order
    # object link, however, emits the C++ static-initialiser table (.CRT$XCU) in
    # genex registration order, which runs a global constructor before a runtime
    # it depends on has been initialised -> DllMain aborts at process load with
    # 0xC0000142 (STATUS_DLL_INIT_FAILED) and the DLL cannot be loaded at all.
    # Emitting the component objects in REVERSE registration order yields a
    # self-consistent initialiser order that loads cleanly. This was isolated by
    # direct A/B load experiments over the identical 12k-object set: forward
    # order -> LoadLibrary err 1114; reversed order -> err 0 (the same order the
    # /WHOLEARCHIVE archive link happens to emit, which is why the archive path
    # also loaded). The reversal is applied to _object_libs_rev above.
    # Oldnames.lib supplies the POSIX-name aliases (open->_open, ...) the zlib
    # (aocl-compression) objects reference.
    target_link_libraries(${PROJECT_NAME} PRIVATE Oldnames.lib)
    # The component stack mixes C and C++ TUs, all built /MT, so libucrt and
    # libcpmt each contribute their own copy of a handful of CRT-internal
    # complex-math helpers (_Sinh / _FSinh, ...). They are byte-for-byte
    # equivalent, so let the linker keep the first and drop the rest; the explicit
    # /DEF still drives the export table, so the import library stays correct.
    target_link_options(${PROJECT_NAME} PRIVATE "/FORCE:MULTIPLE")
    set_target_properties(${PROJECT_NAME} PROPERTIES LINK_DEPENDS "${_def}")
    target_link_libraries(${PROJECT_NAME} PRIVATE ${_runtime_libs})
    # Resolve the Intel Fortran runtime import libs (ifconsol, libircmt, ...) the
    # libflame Fortran objects request via embedded /DEFAULTLIB directives. Needed
    # for the Visual Studio generator, whose toolset does not inherit the oneAPI
    # LIB env that the Ninja generator's lld-link picks up.
    #
    # NB: emit the search path as a verbatim "/LIBPATH:" linker option rather than
    # via target_link_directories(). Because this target also consumes Fortran
    # object files, CMake routes link-directory entries through the Intel Fortran
    # linker-wrapper flag, producing "/Qoption,link,/LIBPATH:..." -- a driver
    # option lld-link (which actually performs this CXX link) cannot parse and
    # rejects as a bad input file. A raw /LIBPATH: token is passed through as-is.
    if(_aocl_fortran_libdir)
        # Search path so the Fortran objects' embedded /DEFAULTLIB:libifcoremt,
        # /DEFAULTLIB:ifconsol, ... directives resolve. The matching *dynamic*
        # Intel runtime import libs (which actually make the DLL loadable) are
        # linked from the shared external-deps list -- registered once by
        # aocl_tb_add_fortran_runtime() -- not hardcoded here.
        target_link_options(${PROJECT_NAME} PRIVATE "/LIBPATH:${_aocl_fortran_libdir}")
    endif()
    add_dependencies(${PROJECT_NAME} ${PROJECT_NAME}_def)
    if(_dep_targets)
        add_dependencies(${PROJECT_NAME} ${_dep_targets})
    endif()

    _install(TARGETS ${PROJECT_NAME}
            COMPONENT ${AOCL_INSTALL_COMPONENT}
            RUNTIME DESTINATION lib
            ARCHIVE DESTINATION lib)
endif()

# --- top-level merged include/ (the union of every component's headers) ------
# Each component already installed its public headers into the top-level include/
# tree via aocl_tb_install_component(); nothing extra to do here.

get_property(_components_final GLOBAL PROPERTY AOCL_TB_COMPONENTS)
message(STATUS "[aocl] Unified library '${PROJECT_NAME}' composed from the objects of: ${_components_final}")
