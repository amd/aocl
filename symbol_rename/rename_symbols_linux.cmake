# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
# ---------------------------------------------------------------------------
# rename_symbols_linux.cmake -- Linux-specific functionality
#   Included by rename_symbols.cmake when running on Linux. Provides the Linux
#   tool detection (nm / objcopy / python3), ELF symbol extraction / .so export
#   reading, and renamed-.so creation. The common driver owns the orchestration;
#   the regex-heavy map generation + header rewrite are delegated to
#   rename_engine_linux.py (--emit-map / --emit-headers), invoked from the
#   common dispatchers.
# ---------------------------------------------------------------------------

# --- Linux tool detection (runs on include) ---
_find_tool(NM_TOOL       nm)
_find_tool(OBJCOPY_TOOL  objcopy)
if(NOT NM_TOOL)
    set(NM_TOOL "${LLVM_NM_TOOL}")
endif()
if(NOT OBJCOPY_TOOL)
    set(OBJCOPY_TOOL "${LLVM_OBJCOPY_TOOL}")
endif()
if(NOT NM_TOOL)
    message(FATAL_ERROR "rename_symbols.cmake: nm not found on Linux.")
endif()
if(NOT OBJCOPY_TOOL)
    message(FATAL_ERROR "rename_symbols.cmake: objcopy not found on Linux.")
endif()
# Python drives the two regex-heavy steps on Linux (map generation + header
# rewrite), exactly as PowerShell does on Windows. CMake still owns the
# orchestration. rename_engine_linux.py exposes focused --emit-map /
# --emit-headers sub-task modes that reuse its validated internal functions.
find_program(PYTHON3_EXE NAMES python3 python)
if(NOT PYTHON3_EXE)
    message(FATAL_ERROR "rename_symbols.cmake: python3 not found on Linux "
                        "(needed for symbol-map generation and header rewriting).")
endif()
if(NOT DEFINED COMPILER OR COMPILER STREQUAL "")
    set(COMPILER "gcc")
endif()
message(STATUS "nm            : ${NM_TOOL}")
message(STATUS "objcopy       : ${OBJCOPY_TOOL}")
message(STATUS "python3       : ${PYTHON3_EXE}")

# ---------------------------------------------------------------------------
# 3. Symbol extraction
# ---------------------------------------------------------------------------
function(extract_symbols_linux LIB_FILE OUT_SYMBOLS)
    execute_process(
        COMMAND "${NM_TOOL}" --no-sort "${LIB_FILE}"
        OUTPUT_VARIABLE _nm_out
        ERROR_VARIABLE  _nm_err
        RESULT_VARIABLE _nm_ret
    )
    if(NOT _nm_ret EQUAL 0)
        execute_process(
            COMMAND "${NM_TOOL}" --defined-only "${LIB_FILE}"
            OUTPUT_VARIABLE _nm_out
            ERROR_VARIABLE  _nm_err
            RESULT_VARIABLE _nm_ret
        )
        if(NOT _nm_ret EQUAL 0)
            message(WARNING "nm failed for ${LIB_FILE}: ${_nm_err}")
            set(${OUT_SYMBOLS} "" PARENT_SCOPE)
            return()
        endif()
    endif()

    set(_syms "")
    string(REPLACE "\n" ";" _lines "${_nm_out}")
    foreach(_line ${_lines})
        string(STRIP "${_line}" _line)
        # nm output: [addr] type name
        string(REGEX MATCH "^[0-9a-fA-F]* ([TDRBWVtdrbwv]) (.+)$" _m "${_line}")
        if(CMAKE_MATCH_2)
            list(APPEND _syms "${CMAKE_MATCH_2}")
        endif()
    endforeach()
    list(REMOVE_DUPLICATES _syms)
    set(${OUT_SYMBOLS} "${_syms}" PARENT_SCOPE)
endfunction()

# ---------------------------------------------------------------------------
# 6a. Export extraction from an ELF shared library (Linux)
#     Uses nm --dynamic --defined-only to get the authoritative exported-symbol
#     list from the original .so -- the Linux equivalent of reading aocl.lib on
#     Windows via llvm-nm --defined-only.
# ---------------------------------------------------------------------------
function(get_so_exports_linux SO_FILE OUT_EXPORTS)
    set(_exports "")
    set(_nm_cmd "${NM_TOOL}")
    if(NOT _nm_cmd)
        set(_nm_cmd "${LLVM_NM_TOOL}")
    endif()

    if(_nm_cmd AND EXISTS "${SO_FILE}")
        message(STATUS "  Reading exports from .so: ${SO_FILE}")
        execute_process(
            COMMAND "${_nm_cmd}" --dynamic --defined-only --extern-only "${SO_FILE}"
            OUTPUT_VARIABLE _nm_out
            ERROR_VARIABLE  _nm_err
            RESULT_VARIABLE _nm_ret
        )
        if(_nm_ret EQUAL 0 AND NOT _nm_out STREQUAL "")
            string(REPLACE "\n" ";" _nm_lines "${_nm_out}")
            foreach(_line ${_nm_lines})
                string(STRIP "${_line}" _line)
                # nm --dynamic output: "<addr> <type> <symbol>[@@<version>]"
                # Accept: T (text), D (data), B (bss), R (read-only),
                #         W (weak), V (versioned), i (indirect)
                if("${_line}" MATCHES "^[0-9a-fA-F]+ [TDBRWViIw] (.+)$")
                    set(_sym "${CMAKE_MATCH_1}")
                    # Strip ELF version suffix: "sym@@VER" or "sym@VER"
                    string(REGEX REPLACE "@.*$" "" _sym "${_sym}")
                    string(STRIP "${_sym}" _sym)
                    # Only plain C/C++ identifiers; skip ELF housekeeping symbols
                    if("${_sym}" MATCHES "^[A-Za-z_][A-Za-z0-9_]*$" AND
                       NOT "${_sym}" STREQUAL "_init" AND
                       NOT "${_sym}" STREQUAL "_fini" AND
                       NOT "${_sym}" STREQUAL "_start" AND
                       NOT "${_sym}" MATCHES "^__bss_" AND
                       NOT "${_sym}" MATCHES "^__data_")
                        list(APPEND _exports "${_sym}")
                    endif()
                endif()
            endforeach()
            list(REMOVE_DUPLICATES _exports)
        else()
            message(STATUS "  nm --dynamic failed (${_nm_ret}): ${_nm_err}")
        endif()
    endif()

    # Fallback: extract from the matching .a static lib (superset of exports)
    if("${_exports}" STREQUAL "")
        message(STATUS "  Falling back to static lib for export list")
        string(REGEX REPLACE "\\.so(\\.[0-9.]+)?$" ".a" _static_candidate "${SO_FILE}")
        if(EXISTS "${_static_candidate}")
            extract_symbols_linux("${_static_candidate}" _exports)
        endif()
    endif()

    list(LENGTH _exports _n)
    message(STATUS "  SO exports found      : ${_n}")
    set(${OUT_EXPORTS} "${_exports}" PARENT_SCOPE)
endfunction()

# 6b. Shared library creation (Linux: gcc --whole-archive + version script)
#     The ORIGINAL_SO is used to derive the authoritative export list; symbols
#     are renamed via _compute_new_symbol and written into a GCC version script
#     so the renamed .so exposes exactly the same surface as the original.
# ---------------------------------------------------------------------------
function(create_shared_library_linux RENAMED_STATIC ORIGINAL_SO OUT_SO)
    get_filename_component(_lib_base "${RENAMED_STATIC}" NAME_WE)
    get_filename_component(_lib_dir  "${RENAMED_STATIC}" DIRECTORY)
    set(_output_so "${_lib_dir}/${_lib_base}.so")

    # --- get original exports and compute renamed list ---
    get_so_exports_linux("${ORIGINAL_SO}" _orig_exports)
    list(LENGTH _orig_exports _n_orig)
    message(STATUS "  Original SO exports   : ${_n_orig}")

    set(_renamed_exports "")
    foreach(_sym ${_orig_exports})
        _compute_new_symbol("${_sym}")
        if(_NEW_SYM STREQUAL "")
            # Not renamed (filtered or no change) -- keep original name
            list(APPEND _renamed_exports "${_sym}")
        else()
            list(APPEND _renamed_exports "${_NEW_SYM}")
        endif()
    endforeach()

    list(LENGTH _renamed_exports _n_renamed)
    if(_n_renamed EQUAL 0)
        message(WARNING "  No exports found for ${_lib_base}.so --“ skipping")
        set(${OUT_SO} "" PARENT_SCOPE)
        return()
    endif()

    # --- write GCC version script for precise export control ---
    get_filename_component(_lib_stem "${_lib_base}" NAME_WE)
    set(_verscript "${_lib_dir}/${_lib_stem}_exports.map")
    file(WRITE  "${_verscript}" "{\n    global:\n")
    foreach(_sym ${_renamed_exports})
        file(APPEND "${_verscript}" "        ${_sym};\n")
    endforeach()
    # Also export EVERY renamed symbol via a prefix-token glob. The explicit
    # list above is built with the cmake renamer (_compute_new_symbol), which
    # diverges from the actual Python-engine rename for complex C++ template
    # instantiations (std::complex<T> args + embedded type tags such as
    # _aoclsparse_matrix -> av1__aoclsparse_matrix). Those mangled names then
    # match no `global:` entry and are localized by `local: *`, hiding e.g.
    # aoclsparse::trsv<T> / mv<T> from the .so. The glob catches all renamed
    # global/weak symbols (mangled C++ names contain the prefix token), so they
    # stay exported. Safe for coexistence: every such symbol is prefix-namespaced
    # and cannot clash with MKL/system symbols.
    string(REGEX REPLACE "[^A-Za-z0-9_]" "" _pfx_tok "${PREFIX}")
    if(NOT _pfx_tok STREQUAL "")
        file(APPEND "${_verscript}" "        *${_pfx_tok}*;\n")
    endif()
    file(APPEND "${_verscript}" "    local:\n        *;\n};\n")
    message(STATUS "  Version script exports: ${_n_renamed}")

    # --- build the compiler command ---
    set(_cmd "${COMPILER}" -shared -o "${_output_so}"
        -Wl,--whole-archive "${RENAMED_STATIC}" -Wl,--no-whole-archive
        "-Wl,--version-script,${_verscript}"
    )

    if(DEFINED SO_LIBS AND NOT SO_LIBS STREQUAL "")
        string(REPLACE ";" " " _so_libs_str "${SO_LIBS}")
        separate_arguments(_so_libs_list UNIX_COMMAND "${_so_libs_str}")
        # SO_LIBS carries the third-party deps collected per component. Most are
        # already link-ready (-lfoo, -L<dir> or an absolute path), but a bare
        # library name (e.g. the "dl" that ${CMAKE_DL_LIBS} expands to) would be
        # mistaken by the driver for an input file. Normalise those to -l<name>.
        foreach(_tok IN LISTS _so_libs_list)
            if(_tok MATCHES "^[A-Za-z0-9_]+$")
                list(APPEND _cmd "-l${_tok}")
            else()
                list(APPEND _cmd "${_tok}")
            endif()
        endforeach()
    endif()

    if(DEFINED LINKER_FLAGS AND NOT LINKER_FLAGS STREQUAL "")
        separate_arguments(_lflags UNIX_COMMAND "${LINKER_FLAGS}")
        list(APPEND _cmd ${_lflags})
    endif()

    message(STATUS "  Creating shared lib   : ${_output_so}")
    execute_process(
        COMMAND ${_cmd}
        OUTPUT_VARIABLE _so_out
        ERROR_VARIABLE  _so_err
        RESULT_VARIABLE _so_ret
    )
    if(NOT _so_ret EQUAL 0)
        message(WARNING "  Shared library creation failed:\n${_so_err}")
        set(${OUT_SO} "" PARENT_SCOPE)
        return()
    endif()
    message(STATUS "  Shared library created: ${_output_so}")
    set(${OUT_SO} "${_output_so}" PARENT_SCOPE)
endfunction()


