# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
# ---------------------------------------------------------------------------
# rename_symbols_windows.cmake -- Windows-specific functionality
#   Included by rename_symbols.cmake when running on Windows. Provides the
#   Windows tool detection, MSVC symbol extraction / DLL export reading, and
#   renamed-DLL creation. The common driver (rename_symbols.cmake) owns the
#   orchestration; the regex-heavy map generation + header rewrite are done by
#   rename_engine_windows.ps1 (-Mode map) / the embedded PowerShell (invoked from the common
#   dispatchers).
# ---------------------------------------------------------------------------

# --- Windows tool detection (runs on include) ---
_find_tool(LINKER_TOOL  lld-link  lld-link.exe  link.exe)
_find_tool(DUMPBIN_TOOL dumpbin   dumpbin.exe)
if(NOT LLVM_NM_TOOL)
    if(NOT DUMPBIN_TOOL)
        message(FATAL_ERROR
            "rename_symbols.cmake: Neither llvm-nm nor dumpbin found.\n"
            "Run vcvarsall.bat x64 or add LLVM bin to PATH.")
    endif()
endif()
if(NOT LLVM_OBJCOPY_TOOL)
    message(FATAL_ERROR
        "rename_symbols.cmake: llvm-objcopy not found.\n"
        "Install LLVM and add its bin/ to PATH.")
endif()
if(NOT LINKER_TOOL)
    message(FATAL_ERROR
        "rename_symbols.cmake: No linker found (lld-link / link.exe).\n"
        "Run vcvarsall.bat x64 or add LLVM bin to PATH.")
endif()
message(STATUS "llvm-nm       : ${LLVM_NM_TOOL}")
message(STATUS "llvm-objcopy  : ${LLVM_OBJCOPY_TOOL}")
message(STATUS "Linker        : ${LINKER_TOOL}")

# Directory holding this engine and its PowerShell engine script
# (rename_engine_windows.ps1, which also provides -Mode data / -Mode parobjcopy).
# Captured at include time so it resolves correctly from inside the
# create_dll_windows function.
set(_AOCL_WIN_ENGINE_DIR "${CMAKE_CURRENT_LIST_DIR}")

function(extract_symbols_windows LIB_FILE OUT_SYMBOLS)
    set(_syms "")

    # Try llvm-nm first
    if(LLVM_NM_TOOL)
        execute_process(
            COMMAND "${LLVM_NM_TOOL}" --no-sort "${LIB_FILE}"
            OUTPUT_VARIABLE _nm_out
            ERROR_VARIABLE  _nm_err
            RESULT_VARIABLE _nm_ret
        )
        if(_nm_ret EQUAL 0)
            string(REPLACE "\n" ";" _lines "${_nm_out}")
            foreach(_line ${_lines})
                string(STRIP "${_line}" _line)
                string(REGEX MATCH "^[0-9a-fA-F]* ([TDRBWVtdrbwv]) (.+)$" _m "${_line}")
                if(CMAKE_MATCH_2)
                    list(APPEND _syms "${CMAKE_MATCH_2}")
                endif()
            endforeach()
            list(REMOVE_DUPLICATES _syms)
            set(${OUT_SYMBOLS} "${_syms}" PARENT_SCOPE)
            return()
        endif()
    endif()

    # Fallback: dumpbin /symbols
    if(DUMPBIN_TOOL)
        execute_process(
            COMMAND "${DUMPBIN_TOOL}" /symbols "${LIB_FILE}"
            OUTPUT_VARIABLE _dump_out
            ERROR_VARIABLE  _dump_err
            RESULT_VARIABLE _dump_ret
        )
        if(_dump_ret EQUAL 0)
            string(REPLACE "\n" ";" _lines "${_dump_out}")
            foreach(_line ${_lines})
                string(REGEX MATCH "External[[:space:]]+\\|[[:space:]]+([^ ]+)" _m "${_line}")
                if(CMAKE_MATCH_1)
                    list(APPEND _syms "${CMAKE_MATCH_1}")
                endif()
                string(REGEX MATCH "Static[[:space:]]+\\|[[:space:]]+([^ ]+)" _m2 "${_line}")
                if(CMAKE_MATCH_1)
                    list(APPEND _syms "${CMAKE_MATCH_1}")
                endif()
            endforeach()
            list(REMOVE_DUPLICATES _syms)
            set(${OUT_SYMBOLS} "${_syms}" PARENT_SCOPE)
            return()
        endif()
    endif()

    message(WARNING "Could not extract symbols from ${LIB_FILE}")
    set(${OUT_SYMBOLS} "" PARENT_SCOPE)
endfunction()

function(get_dll_exports_windows DLL_FILE OUT_EXPORTS)
    set(_exports "")
    if(DUMPBIN_TOOL)
        execute_process(
            COMMAND "${DUMPBIN_TOOL}" /exports "${DLL_FILE}"
            OUTPUT_VARIABLE _dump_out
            ERROR_VARIABLE  _dump_err
            RESULT_VARIABLE _dump_ret
        )
        if(_dump_ret EQUAL 0)
            set(_in_exports FALSE)
            string(REPLACE "\n" ";" _lines "${_dump_out}")
            foreach(_line ${_lines})
                string(TOLOWER "${_line}" _line_lower)
                if("${_line_lower}" MATCHES "ordinal.*hint")
                    set(_in_exports TRUE)
                    continue()
                endif()
                if(_in_exports)
                    string(STRIP "${_line}" _line_s)
                    if(_line_s STREQUAL "")
                        if(_exports)
                            break()
                        endif()
                        continue()
                    endif()
                    # "  ordinal  hint  RVA  name"
                    string(REGEX MATCH "^([0-9]+)[[:space:]]+([0-9A-Fa-f]+)[[:space:]]+([0-9A-Fa-f]+)[[:space:]]+(.+)$" _m "${_line_s}")
                    if(CMAKE_MATCH_4)
                        string(STRIP "${CMAKE_MATCH_4}" _sym_name)
                        list(APPEND _exports "${_sym_name}")
                    endif()
                endif()
            endforeach()
        endif()
    endif()

    # Fallback: try llvm-objdump --exports (works on COFF DLLs without -D)
    if(NOT _exports AND LLVM_NM_TOOL)
        # Try llvm-objdump if available (it's in the same bin dir as llvm-nm)
        get_filename_component(_llvm_bin "${LLVM_NM_TOOL}" DIRECTORY)
        find_program(_LLVM_OBJDUMP_TOOL NAMES llvm-objdump llvm-objdump.exe
            PATHS "${_llvm_bin}" NO_DEFAULT_PATH)
        if(_LLVM_OBJDUMP_TOOL)
            execute_process(
                COMMAND "${_LLVM_OBJDUMP_TOOL}" --exports "${DLL_FILE}"
                OUTPUT_VARIABLE _od_out
                ERROR_VARIABLE  _od_err
                RESULT_VARIABLE _od_ret
            )
            if(_od_ret EQUAL 0)
                string(REPLACE "\n" ";" _lines "${_od_out}")
                set(_in_exp FALSE)
                foreach(_line ${_lines})
                    string(STRIP "${_line}" _line)
                    if("${_line}" MATCHES "^Export Table:")
                        set(_in_exp TRUE)
                        continue()
                    endif()
                    if(_in_exp AND "${_line}" MATCHES "^[A-Za-z_][A-Za-z0-9_@?$]*")
                        list(APPEND _exports "${_line}")
                    endif()
                endforeach()
            endif()
        endif()
    endif()

    # Second fallback: read from companion exports.def in the install path
    if(NOT _exports)
        get_filename_component(_dll_dir "${DLL_FILE}" DIRECTORY)
        set(_def_candidate "${_dll_dir}/../exports.def")
        if(NOT EXISTS "${_def_candidate}")
            set(_def_candidate "${INSTALL_PATH}/exports.def")
        endif()
        if(EXISTS "${_def_candidate}")
            message(STATUS "  Using exports.def fallback: ${_def_candidate}")
            file(STRINGS "${_def_candidate}" _def_lines)
            set(_past_exports FALSE)
            foreach(_line ${_def_lines})
                string(STRIP "${_line}" _line)
                string(TOLOWER "${_line}" _line_lower)
                if("${_line_lower}" STREQUAL "exports")
                    set(_past_exports TRUE)
                    continue()
                endif()
                if(_past_exports AND NOT "${_line}" STREQUAL "")
                    # Each line: "    SYMBOL_NAME" or "    SYMBOL_NAME  DATA"
                    string(REGEX MATCH "^([A-Za-z_][A-Za-z0-9_@?$]*)" _m "${_line}")
                    if(CMAKE_MATCH_1)
                        list(APPEND _exports "${CMAKE_MATCH_1}")
                    endif()
                endif()
            endforeach()
        endif()
    endif()

    # Third fallback (always runs): read from import library (.lib) using llvm-nm.
    # The import library is the authoritative list of DLL exports -- it captures
    # symbols added via __declspec(dllexport) in object files that are absent from
    # the manually-maintained exports.def.
    # Strategy: use the import lib as the definitive source (replaces any def-based list).
    if(LLVM_NM_TOOL)
        get_filename_component(_dll_dir "${DLL_FILE}" DIRECTORY)
        get_filename_component(_dll_stem "${DLL_FILE}" NAME_WE)
        set(_imp_lib_candidate "${_dll_dir}/${_dll_stem}.lib")
        if(NOT EXISTS "${_imp_lib_candidate}")
            set(_imp_lib_candidate "${INSTALL_PATH}/lib/${_dll_stem}.lib")
        endif()
        if(EXISTS "${_imp_lib_candidate}")
            message(STATUS "  Reading exports from import lib: ${_imp_lib_candidate}")
            execute_process(
                COMMAND "${LLVM_NM_TOOL}" --extern-only "${_imp_lib_candidate}"
                OUTPUT_VARIABLE _nm_imp_out
                ERROR_VARIABLE  _nm_imp_err
                RESULT_VARIABLE _nm_imp_ret
            )
            if(NOT _nm_imp_out STREQUAL "")
                set(_imp_exports "")
                string(REPLACE "\n" ";" _imp_lines "${_nm_imp_out}")
                foreach(_iline ${_imp_lines})
                    string(STRIP "${_iline}" _iline)
                    # "00000000 T <sym>" -- defined (exported) symbol, skip __imp_ thunks
                    if("${_iline}" MATCHES "^[0-9a-fA-F]+ T ([A-Za-z_?@][A-Za-z0-9_?@$]*)$")
                        set(_sym_candidate "${CMAKE_MATCH_1}")
                        if(NOT "${_sym_candidate}" MATCHES "^__imp_")
                            list(APPEND _imp_exports "${_sym_candidate}")
                        endif()
                    endif()
                endforeach()
                list(LENGTH _imp_exports _n_imp)
                message(STATUS "  Import lib exports found: ${_n_imp}")
                if(_n_imp GREATER 0)
                    # Import lib is authoritative: use it as the complete export list
                    set(_exports "${_imp_exports}")
                endif()
            endif()
        endif()
    endif()

    set(${OUT_EXPORTS} "${_exports}" PARENT_SCOPE)
endfunction()

function(create_dll_windows RENAMED_STATIC ORIGINAL_DLL MAP_FILE)
    get_filename_component(_dll_name "${ORIGINAL_DLL}" NAME)
    set(_renamed_dir "${INSTALL_PATH}/renamed/lib")
    set(_output_dll "${_renamed_dir}/${_dll_name}")

    # --- read original exports from DLL ---
    get_dll_exports_windows("${ORIGINAL_DLL}" _orig_exports)
    list(LENGTH _orig_exports _n_orig_exports)
    message(STATUS "  Original DLL exports  : ${_n_orig_exports}")

    # --- build renamed exports from the AUTHORITATIVE map file ---
    # The static library was renamed using MAP_FILE (generated by the fast
    # PowerShell path rename_engine_windows.ps1 (-Mode map), which includes namespace and
    # Option-A embedded-type-component renames). The cmake fallback macro
    # _compute_new_symbol does NOT reproduce those type-component renames, so
    # recomputing .def names here would emit export names that don't byte-match
    # the renamed static-lib symbols (e.g. ...da_status_... vs ...av1_da_status_...),
    # causing lld-link "undefined symbol" failures. Use the map as the single
    # source of truth: look each original export up in the map (MD5-keyed for
    # O(1) access) and fall back to _compute_new_symbol only for exports that
    # were not renamed / not present in the map.
    set(_renamed_exports "")
    if(EXISTS "${MAP_FILE}")
        file(STRINGS "${MAP_FILE}" _dllmap_lines)
        foreach(_ml IN LISTS _dllmap_lines)
            string(FIND "${_ml}" " " _sp)
            if(_sp GREATER 0)
                string(SUBSTRING "${_ml}" 0 ${_sp} _mo)
                math(EXPR _vp "${_sp} + 1")
                string(SUBSTRING "${_ml}" ${_vp} -1 _mn)
                string(MD5 _mh "${_mo}")
                set("_DLLMAP_${_mh}" "${_mn}")
            endif()
        endforeach()
        unset(_dllmap_lines)
    endif()
    foreach(_sym ${_orig_exports})
        string(MD5 _sh "${_sym}")
        if(DEFINED _DLLMAP_${_sh})
            # Renamed by the authoritative map -- use its exact renamed name.
            list(APPEND _renamed_exports "${_DLLMAP_${_sh}}")
        else()
            # Not in the map; try the direct compute, else keep original.
            _compute_new_symbol("${_sym}")
            if(_NEW_SYM STREQUAL "")
                list(APPEND _renamed_exports "${_sym}")
            else()
                list(APPEND _renamed_exports "${_NEW_SYM}")
            endif()
        endif()
    endforeach()

    # --- DATA exports ---------------------------------------------------------
    # get_dll_exports_windows harvests only code (T) symbols from the import lib.
    # DATA exports (e.g. the public libflame progress pointer
    # aocl_fla_progress_glb_ptr, declared 'extern' in FLAME.h) appear in an import
    # library ONLY as an __imp_<sym> thunk with no plain code entry, so they were
    # being silently dropped from the renamed DLL -> unresolved externals for
    # consumers that use the renamed headers. Harvest the data-only exports here,
    # map them through the SAME authoritative map, and emit them with the .def
    # "DATA" keyword so the renamed DLL re-exports exactly what the original did.
    set(_orig_data "")
    get_filename_component(_odll_dir "${ORIGINAL_DLL}" DIRECTORY)
    get_filename_component(_odll_stem "${ORIGINAL_DLL}" NAME_WE)
    set(_oimp "${_odll_dir}/${_odll_stem}.lib")
    if(NOT EXISTS "${_oimp}")
        set(_oimp "${INSTALL_PATH}/lib/${_odll_stem}.lib")
    endif()
    if(LLVM_NM_TOOL AND EXISTS "${_oimp}")
        # Fast path: a tiny PowerShell helper computes the data-only export set in
        # one pass. The pure-CMake set-difference over the ~100k llvm-nm lines is
        # otherwise a multi-minute step. PowerShell is already a hard rename
        # dependency (map generation runs rename_engine_windows.ps1).
        set(_data_txt "${_renamed_dir}/_data_exports_${_odll_stem}.txt")
        find_program(_AOCL_PS NAMES pwsh.exe powershell.exe)
        if(_AOCL_PS AND EXISTS "${_AOCL_WIN_ENGINE_DIR}/rename_engine_windows.ps1")
            execute_process(
                COMMAND "${_AOCL_PS}" -NoProfile -ExecutionPolicy Bypass
                        -File "${_AOCL_WIN_ENGINE_DIR}/rename_engine_windows.ps1"
                        -Mode data -LlvmNm "${LLVM_NM_TOOL}" -ImportLib "${_oimp}" -Out "${_data_txt}"
                RESULT_VARIABLE _de_rc ERROR_VARIABLE _de_err)
            if(_de_rc EQUAL 0 AND EXISTS "${_data_txt}")
                file(STRINGS "${_data_txt}" _orig_data)
            else()
                message(STATUS "  data-export helper failed (rc=${_de_rc}); using CMake fallback")
            endif()
        endif()
        if(NOT _orig_data)
            # Pure-CMake fallback (no PowerShell). Extract every __imp_ token in ONE
            # native regex pass, then subtract the code names already parsed into
            # _orig_exports (each function has an __imp_ thunk whose base name IS a
            # code export; a data export's base name is NOT).
            execute_process(COMMAND "${LLVM_NM_TOOL}" --extern-only "${_oimp}"
                OUTPUT_VARIABLE _nmi RESULT_VARIABLE _nmir ERROR_VARIABLE _nmie)
            foreach(_cn IN LISTS _orig_exports)
                string(MD5 _ch "${_cn}")
                set("_CODESET_${_ch}" 1)
            endforeach()
            string(REGEX MATCHALL "__imp_[A-Za-z0-9_?@$.]+" _imp_all "${_nmi}")
            foreach(_im IN LISTS _imp_all)
                string(SUBSTRING "${_im}" 6 -1 _dn)
                string(MD5 _dh "${_dn}")
                if(NOT DEFINED _CODESET_${_dh})
                    list(APPEND _orig_data "${_dn}")
                endif()
            endforeach()
            if(_orig_data)
                list(REMOVE_DUPLICATES _orig_data)
            endif()
        endif()
    endif()
    set(_renamed_data "")
    foreach(_sym ${_orig_data})
        string(MD5 _sh "${_sym}")
        if(DEFINED _DLLMAP_${_sh})
            list(APPEND _renamed_data "${_DLLMAP_${_sh}}")
        else()
            _compute_new_symbol("${_sym}")
            if(_NEW_SYM STREQUAL "")
                list(APPEND _renamed_data "${_sym}")
            else()
                list(APPEND _renamed_data "${_NEW_SYM}")
            endif()
        endif()
    endforeach()
    list(LENGTH _renamed_data _n_renamed_data)

    list(LENGTH _renamed_exports _n_renamed)
    if(_n_renamed EQUAL 0)
        message(WARNING "  No exports found for DLL ${_dll_name} --“ skipping DLL creation")
        return()
    endif()

    # --- write .def file ---
    # Build the entire content in memory then write once. Doing 32 k+
    # file(APPEND) calls (one per export) takes ~30 s on Windows because each
    # call is its own open/write/close syscall.
    get_filename_component(_dll_stem "${_dll_name}" NAME_WE)
    set(_def_file "${_renamed_dir}/${_dll_stem}_renamed.def")
    set(_def_content "LIBRARY ${_dll_stem}\nEXPORTS\n")
    foreach(_sym ${_renamed_exports})
        # Quote export names with chars invalid unquoted in a .def (e.g. '<'/'>' from MSVC
        # lambda closures) so the linker exports them instead of silently dropping them.
        if("${_sym}" MATCHES "[^A-Za-z0-9_?@$.]")
            string(APPEND _def_content "    \"${_sym}\"\n")
        else()
            string(APPEND _def_content "    ${_sym}\n")
        endif()
    endforeach()
    # DATA exports carry the "DATA" keyword so consumers import them as data
    # (indirect through __imp_) instead of as a call target.
    foreach(_sym ${_renamed_data})
        if("${_sym}" MATCHES "[^A-Za-z0-9_?@$.]")
            string(APPEND _def_content "    \"${_sym}\" DATA\n")
        else()
            string(APPEND _def_content "    ${_sym} DATA\n")
        endif()
    endforeach()
    file(WRITE "${_def_file}" "${_def_content}")
    unset(_def_content)
    message(STATUS "  .def file exports     : ${_n_renamed} code + ${_n_renamed_data} data")

    # Absolute paths for linker
    cmake_path(ABSOLUTE_PATH RENAMED_STATIC BASE_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}" OUTPUT_VARIABLE _abs_static)
    cmake_path(ABSOLUTE_PATH _output_dll    BASE_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}" OUTPUT_VARIABLE _abs_dll)
    file(TO_NATIVE_PATH "${_abs_static}" _abs_static)
    file(TO_NATIVE_PATH "${_abs_dll}"    _abs_dll)
    file(TO_NATIVE_PATH "${_def_file}"   _native_def)

    # Choose the CRT import libraries to match how the component objects were
    # compiled. A /MT (MultiThreaded static CRT) build -- e.g. the aocl_tbi
    # unified library, whose targets set MSVC_RUNTIME_LIBRARY=MultiThreaded --
    # embeds references to the STATIC CRT (libcmt/libcpmt: std::cout, std::cerr,
    # std::locale, std::ctype, ...). Linking the dynamic CRT (msvcrt/msvcprt)
    # then leaves those symbols undefined. STATIC_CRT=ON selects the static CRT
    # import libs and, like the original unified DLL link, tolerates the
    # duplicate CRT-helper definitions libcmt and libcpmt both provide
    # (/FORCE:MULTIPLE, appended below).
    if(STATIC_CRT)
        set(_crt_libs libcmt.lib libcpmt.lib libvcruntime.lib libucrt.lib)
    else()
        set(_crt_libs msvcrt.lib msvcprt.lib vcruntime.lib ucrt.lib)
    endif()

    # Build linker command
    set(_link_cmd
        "${LINKER_TOOL}"
        /DLL /NOLOGO
        "/OUT:${_abs_dll}"
        "/DEF:${_native_def}"
        "/WHOLEARCHIVE:${_abs_static}"
        ${_crt_libs}
        Advapi32.lib Ole32.lib User32.lib Kernel32.lib Ws2_32.lib Shell32.lib
        Bcrypt.lib
        # Oldnames.lib provides the POSIX-name aliases (open->_open, read->_read,
        # write->_write, close->_close, ...) that zlib (aocl-compression, GA
        # builds only) references without the leading underscore. Without it the
        # renamed DLL re-link fails with "undefined symbol: open/read/write/close".
        Oldnames.lib
    )
    if(STATIC_CRT)
        list(APPEND _link_cmd /FORCE:MULTIPLE)
    endif()

    # FORTRAN_LIB_DIR is only a link *search path*, so the renamed static lib's
    # embedded /DEFAULTLIB:libifcoremt / ifconsol directives resolve. The actual
    # third-party import libs (the dynamic Intel Fortran runtime, OpenSSL, OpenMP,
    # ...) arrive uniformly through SO_LIBS below -- collected once, per component,
    # by aocl_tb_add_external_libs() -- so no library is named here.
    if(DEFINED FORTRAN_LIB_DIR AND NOT FORTRAN_LIB_DIR STREQUAL "")
        list(APPEND _link_cmd "/LIBPATH:${FORTRAN_LIB_DIR}")
    endif()
    if(DEFINED SO_LIBS AND NOT SO_LIBS STREQUAL "")
        # SO_LIBS arrives '|'-separated (see CMakeLists.txt) so it stays a single
        # argument -- free of ';' -- while travelling through the install(CODE)
        # COMMAND. Restore the ';' list separators before iterating.
        string(REPLACE "|" ";" SO_LIBS "${SO_LIBS}")
        # SO_LIBS is a CMake list (semicolon-separated). Each element is one
        # full path / linker arg and must be appended verbatim -- splitting on
        # whitespace via separate_arguments() would break paths like
        # "C:/Program Files (x86)/Intel/.../libiomp5md.lib".
        foreach(_so_lib IN LISTS SO_LIBS)
            if(NOT _so_lib STREQUAL "")
                list(APPEND _link_cmd "${_so_lib}")
            endif()
        endforeach()
    endif()

    message(STATUS "  Linking renamed DLL   : ${_output_dll}")
    set(_link_log "${_renamed_dir}/${_dll_stem}_link.log")
    # Print the full command for diagnostics, one arg per line.
    message(STATUS "  Link command:")
    foreach(_a IN LISTS _link_cmd)
        message(STATUS "    ${_a}")
    endforeach()

    # Write a response file with every linker arg on its own line, then
    # invoke lld-link with '@<file>'. This bypasses Windows command-line
    # quoting (which can mangle paths containing spaces such as
    # "C:/Program Files (x86)/...") and is the linker-recommended way to
    # pass long / space-bearing argument lists.
    set(_link_rsp "${_renamed_dir}/${_dll_stem}_link.rsp")
    file(WRITE "${_link_rsp}" "")
    # Skip element 0 (the linker tool itself) -- only pass arguments via @rsp.
    set(_idx 0)
    foreach(_a IN LISTS _link_cmd)
        if(_idx GREATER 0)
            # Each arg on its own line. lld-link / link.exe accept either
            # bare tokens or double-quoted tokens; for safety, always quote.
            file(APPEND "${_link_rsp}" "\"${_a}\"\n")
        endif()
        math(EXPR _idx "${_idx} + 1")
    endforeach()

    execute_process(
        COMMAND "${LINKER_TOOL}" "@${_link_rsp}"
        OUTPUT_FILE     "${_link_log}"
        ERROR_FILE      "${_link_log}"
        RESULT_VARIABLE _link_ret
    )
    if(NOT _link_ret EQUAL 0)
        if(EXISTS "${_link_log}")
            file(READ "${_link_log}" _link_log_content)
        else()
            set(_link_log_content "(no output captured)")
        endif()
        message(WARNING "  Linker failed (${_link_ret}). Log:\n${_link_log_content}\n  See also: ${_link_log}")
        return()
    endif()
    if(EXISTS "${_output_dll}")
        message(STATUS "  Renamed DLL created   : ${_output_dll}")
    else()
        message(WARNING "  Linker ran but DLL not found: ${_output_dll}")
    endif()
endfunction()


