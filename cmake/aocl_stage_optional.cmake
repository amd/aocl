# Copy AOCL_SRC -> AOCL_DST only when AOCL_SRC exists.
#
# Used by the per-component staging step so that components shipping no headers
# (e.g. AOCL-LibMem installs only lib/) do not abort the build when the include
# directory is absent. Mirrors `cmake -E copy_directory` semantics otherwise.

if(EXISTS "${AOCL_SRC}")
    execute_process(
        COMMAND "${CMAKE_COMMAND}" -E copy_directory "${AOCL_SRC}" "${AOCL_DST}"
        RESULT_VARIABLE _copy_result)
    if(NOT _copy_result EQUAL 0)
        message(FATAL_ERROR "[aocl] staging copy failed: ${AOCL_SRC} -> ${AOCL_DST}")
    endif()
endif()
