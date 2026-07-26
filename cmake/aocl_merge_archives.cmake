# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
#
# Build-time helper: combine several static archives (.a) into one merged
# archive using a GNU `ar -M` MRI script. Invoked via `cmake -P` from
# aocl_unified.cmake so that the per-component archive paths -- which come from
# in-tree targets as $<TARGET_FILE:...> generator expressions and are therefore
# only known at build time -- can be expanded by the generator before this
# script runs.
#
# Invocation:
#   cmake -DAR=<ar> -DRANLIB=<ranlib> -DOUT=<merged.a>
#         [-DMANIFEST_OBJ=<obj>]
#         -P aocl_merge_archives.cmake  <archive1> <archive2> ...
#
# The archive paths are passed positionally (after the script) so a ;-list of
# generator expressions can be splat with COMMAND_EXPAND_LISTS.

# Collect the positional archive arguments (everything after the script path:
# CMAKE_ARGV0=cmake, ARGV1=-P, ARGV2=this script, ARGV3.. = archives).
set(_archives "")
math(EXPR _last "${CMAKE_ARGC} - 1")
foreach(_i RANGE 3 ${_last})
    if(DEFINED CMAKE_ARGV${_i})
        list(APPEND _archives "${CMAKE_ARGV${_i}}")
    endif()
endforeach()

if(NOT _archives)
    message(FATAL_ERROR "[aocl-merge] no input archives supplied")
endif()

# Build the MRI script.
set(_mri "${OUT}.mri")
set(_content "create ${OUT}\n")
foreach(_a IN LISTS _archives)
    string(APPEND _content "addlib ${_a}\n")
endforeach()
string(APPEND _content "save\nend\n")
file(WRITE "${_mri}" "${_content}")

# Run `ar -M < script`.
execute_process(
    COMMAND "${AR}" -M
    INPUT_FILE "${_mri}"
    RESULT_VARIABLE _rc)
if(NOT _rc EQUAL 0)
    message(FATAL_ERROR "[aocl-merge] ar -M failed (${_rc}) merging into ${OUT}")
endif()

# Append the manifest object (a single ELF object, not an archive) if provided.
if(MANIFEST_OBJ)
    execute_process(
        COMMAND "${AR}" q "${OUT}" "${MANIFEST_OBJ}"
        RESULT_VARIABLE _rc2)
    if(NOT _rc2 EQUAL 0)
        message(FATAL_ERROR "[aocl-merge] ar q (manifest) failed (${_rc2})")
    endif()
endif()

# Regenerate the archive symbol index.
if(RANLIB)
    execute_process(COMMAND "${RANLIB}" "${OUT}")
endif()
