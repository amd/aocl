# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
#
# Build-time generator of a Windows module-definition (.def) file that re-exports
# every externally-visible symbol contained in the merged unified static archive
# (aocl.lib). It is the Windows counterpart of Linux's default ELF symbol
# visibility: a DLL built with /WHOLEARCHIVE over the component archives includes
# all their objects, but MSVC/clang-cl exports nothing unless a symbol is
# __declspec(dllexport) or named in a .def -- so we synthesise the export list by
# scanning the merged archive with llvm-nm (mirroring CMake's own
# WINDOWS_EXPORT_ALL_SYMBOLS / bindexplib behaviour, which does not follow
# external archive files).
#
# Run via `cmake -P`. Expected -D inputs:
#   NM       full path to llvm-nm (or compatible nm) executable
#   OUT      path of the .def file to write
#   LIBNAME  DLL name for the LIBRARY statement (e.g. aocl)
#   Exactly ONE symbol source:
#     OBJLIST  path to a file listing (one per line) the component object files
#              the DLL is composed of -- scanned directly so the shared library
#              needs NO static archive as an intermediate. (Preferred.)
#     LIB      path to a merged static archive to scan (legacy/fallback).

if(NOT NM OR NOT EXISTS "${NM}")
    message(FATAL_ERROR "[aocl] aocl_gen_def: NM (llvm-nm) not found: '${NM}'")
endif()

if(DEFINED OBJLIST AND NOT OBJLIST STREQUAL "")
    # Scan the loose component object files directly (no static archive needed).
    if(NOT EXISTS "${OBJLIST}")
        message(FATAL_ERROR "[aocl] aocl_gen_def: OBJLIST not found: '${OBJLIST}'")
    endif()
    file(STRINGS "${OBJLIST}" _objs)
    list(REMOVE_ITEM _objs "")
    list(LENGTH _objs _n_objs)
    if(_n_objs EQUAL 0)
        message(FATAL_ERROR "[aocl] aocl_gen_def: OBJLIST '${OBJLIST}' is empty")
    endif()
    # llvm-nm accepts many inputs at once, but the full 12k-object list blows the
    # ~32 KB Windows command-line limit, so scan in bounded batches and
    # accumulate. Batch size kept small so even deep _deps/ paths stay under the
    # limit.
    set(_nm_out "")
    set(_batch "")
    set(_batch_n 0)
    foreach(_o IN LISTS _objs)
        list(APPEND _batch "${_o}")
        math(EXPR _batch_n "${_batch_n} + 1")
        if(_batch_n GREATER_EQUAL 80)
            execute_process(COMMAND "${NM}" ${_batch}
                OUTPUT_VARIABLE _bo RESULT_VARIABLE _brc ERROR_VARIABLE _be)
            string(APPEND _nm_out "${_bo}")
            set(_batch "")
            set(_batch_n 0)
        endif()
    endforeach()
    if(_batch_n GREATER 0)
        execute_process(COMMAND "${NM}" ${_batch}
            OUTPUT_VARIABLE _bo RESULT_VARIABLE _brc ERROR_VARIABLE _be)
        string(APPEND _nm_out "${_bo}")
    endif()
    if(_nm_out STREQUAL "")
        message(FATAL_ERROR "[aocl] aocl_gen_def: llvm-nm produced no output over ${_n_objs} objects: ${_be}")
    endif()
else()
    if(NOT EXISTS "${LIB}")
        message(FATAL_ERROR "[aocl] aocl_gen_def: neither OBJLIST nor a valid LIB was provided")
    endif()
    execute_process(
        COMMAND "${NM}" "${LIB}"
        OUTPUT_VARIABLE _nm_out
        RESULT_VARIABLE _nm_rc
        ERROR_VARIABLE  _nm_err)
    # llvm-nm returns non-zero when individual members have no symbols; the symbol
    # lines we need are still emitted, so only fail on empty output.
    if(_nm_out STREQUAL "")
        message(FATAL_ERROR "[aocl] aocl_gen_def: llvm-nm produced no output (rc=${_nm_rc}): ${_nm_err}")
    endif()
endif()

string(REPLACE "\r\n" "\n" _nm_out "${_nm_out}")
string(REPLACE "\n" ";" _lines "${_nm_out}")

set(_funcs "")
set(_datas "")

foreach(_l IN LISTS _lines)
    # Match "<hex-addr> <type> <name>". Lines without an address (undefined "U",
    # member/file headers, blank lines) are skipped by the regex.
    if(NOT _l MATCHES "^[0-9A-Fa-f]+ ([A-Za-z]) (.+)$")
        continue()
    endif()
    set(_type "${CMAKE_MATCH_1}")
    set(_name "${CMAKE_MATCH_2}")

    # Only external/global symbols (uppercase type) are candidates; lowercase
    # types are file-local (static) and must not be exported.
    if(_type MATCHES "[a-z]")
        continue()
    endif()

    # Drop compiler-/linker-generated artefacts that are not real API symbols:
    #   ??_C@...      string-literal constants
    #   __real@ __xmm@ __ymm@   floating/vector immediate pools
    #   @feat.00 / @...         COFF feature flags
    #   __imp_...               import thunks
    #   .  / $                  section / mangled-helper noise
    if(_name MATCHES "^\\?\\?_C@"      OR
       _name MATCHES "^__real@"        OR
       _name MATCHES "^__xmm@"         OR
       _name MATCHES "^__ymm@"         OR
       _name MATCHES "^@"              OR
       _name MATCHES "^__imp_"         OR
       _name MATCHES "^\\."            OR
       _name STREQUAL "__NULL_IMPORT_DESCRIPTOR")
        continue()
    endif()

    if(_type STREQUAL "T")
        list(APPEND _funcs "${_name}")
    else()
        # Any other defined, external symbol (D/R/B/G/S/...) is data.
        list(APPEND _datas "${_name}")
    endif()
endforeach()

if(_funcs)
    list(REMOVE_DUPLICATES _funcs)
    list(SORT _funcs)
endif()
if(_datas)
    list(REMOVE_DUPLICATES _datas)
    list(SORT _datas)
endif()

set(_body "LIBRARY ${LIBNAME}\nEXPORTS\n")
foreach(_s IN LISTS _funcs)
    string(APPEND _body "    ${_s}\n")
endforeach()
foreach(_s IN LISTS _datas)
    string(APPEND _body "    ${_s} DATA\n")
endforeach()

file(WRITE "${OUT}" "${_body}")

list(LENGTH _funcs _nf)
list(LENGTH _datas _nd)
message(STATUS "[aocl] Wrote ${OUT}: ${_nf} function + ${_nd} data exports")
