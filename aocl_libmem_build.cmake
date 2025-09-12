# Copyright (C) 2025, Advanced Micro Devices, Inc. All rights reserved.

# Set CMake policy
cmake_policy(SET CMP0010 NEW)

# Define variables for AOCL-LibMem path, repository, and build log file
set(LIBMEM_PATH "" CACHE STRING "Local path of the AOCL-LibMem source code")
set(LIBMEM_GIT_REPOSITORY "https://github.com/amd/aocl-libmem.git" CACHE STRING "AOCL-LibMem git repository path")
set(LIBMEM_GIT_TAG "main" CACHE STRING "Tag or Branch name of AOCL-LibMem")
set(LIBMEM_DIR ${CMAKE_BINARY_DIR}/aocl-libmem)
set(LIBMEM_BUILD_LOG_FILE_PATH "${CMAKE_BINARY_DIR}/aocl_libmem_build.log")

# Initialize build log file
file(WRITE "${LIBMEM_BUILD_LOG_FILE_PATH}" "=========================AOCL-LibMem Build Logs=========================.\n")

# Remove existing AOCL-LibMem directory if it exists
if(EXISTS ${LIBMEM_DIR})
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E remove_directory ${LIBMEM_DIR}
    )
endif()

# Use local AOCL-LibMem source code if provided, otherwise clone from git repository
if(LIBMEM_PATH)
    message(STATUS "Using AOCL-LibMem source code from ${LIBMEM_PATH}.")
    file(APPEND "${LIBMEM_BUILD_LOG_FILE_PATH}" "Using AOCL-LibMem source code from ${LIBMEM_PATH}.\n")
    string(REPLACE "\\" "/" LIBMEM_DIR "${LIBMEM_PATH}/aocl-libmem")
else()
    execute_process(
        COMMAND git clone ${LIBMEM_GIT_REPOSITORY} -b ${LIBMEM_GIT_TAG} aocl-libmem 
        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
        RESULT_VARIABLE result
        OUTPUT_VARIABLE output
        ERROR_VARIABLE error
    )
    if(result EQUAL 0)
        file(APPEND "${LIBMEM_BUILD_LOG_FILE_PATH}" "${output}.\n")
    else()
        file(APPEND "${LIBMEM_BUILD_LOG_FILE_PATH}" "${error}.\n")
    endif()
endif()

# Log the AOCL-LibMem path
message(STATUS "LIBMEM_PATH: ${LIBMEM_DIR}.")
file(APPEND "${LIBMEM_BUILD_LOG_FILE_PATH}" "LIBMEM_PATH: ${LIBMEM_DIR}.\n")

# Log the start of the configuration and build process
message(STATUS "\"The configuration and build process for the AOCL-LibMem library has started, and logs are being redirected to ${LIBMEM_BUILD_LOG_FILE_PATH}\"")

# Determine the compiler toolset based on the generator
string(FIND "${CMAKE_GENERATOR}" "Visual Studio" substring_position)
if(substring_position EQUAL -1)
    set(CompilerToolSet 
        -DCMAKE_C_COMPILER=${CMAKE_C_COMPILER} -DCMAKE_CXX_COMPILER=${CMAKE_CXX_COMPILER}
    )
else()
    set(CompilerToolSet "-T${CMAKE_GENERATOR_TOOLSET}")
endif()

# Log the configuration command
file(APPEND "${LIBMEM_BUILD_LOG_FILE_PATH}" "CONFIGURATION COMMAND: cmake -G \"${CMAKE_GENERATOR}\" -S ${LIBMEM_DIR} -B ${CMAKE_BINARY_DIR}/aocl-libmem/build_dir -DCMAKE_CONFIGURATION_TYPES=${CMAKE_CONFIGURATION_TYPES} -DALMEM_DYN_DISPATCH=Y -DBUILD_SHARED_LIBS=${BUILD_SHARED_LIBS} -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE} -DCMAKE_INSTALL_PREFIX=${CMAKE_BINARY_DIR}/aocl-libmem/install_package ${CompilerToolSet}.\n")

# Execute the configuration command
execute_process(
    COMMAND cmake -G ${CMAKE_GENERATOR} -S ${LIBMEM_DIR} -B ${CMAKE_BINARY_DIR}/aocl-libmem/build_dir -DCMAKE_CONFIGURATION_TYPES=${CMAKE_CONFIGURATION_TYPES} -DCMAKE_CONFIGURATION_TYPES=${CMAKE_CONFIGURATION_TYPES} -DALMEM_DYN_DISPATCH=ON -DBUILD_SHARED_LIBS=${BUILD_SHARED_LIBS} -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE} -DCMAKE_INSTALL_PREFIX=${CMAKE_BINARY_DIR}/aocl-libmem/install_package ${CompilerToolSet}
    WORKING_DIRECTORY ${LIBMEM_DIR}
    RESULT_VARIABLE result
    OUTPUT_VARIABLE output
    ERROR_VARIABLE error
)
if(result EQUAL 0)
    file(APPEND "${LIBMEM_BUILD_LOG_FILE_PATH}" "${output}.\n")
    message(STATUS "AOCL-LibMem library configuration completed successfully.")
else()
    file(APPEND "${LIBMEM_BUILD_LOG_FILE_PATH}" "${error}.\n")
    message(FATAL_ERROR "Error occured while AOCL-LibMem library configuration!!!.\n${error}\n")
endif()

# Execute the build command
execute_process(
    COMMAND cmake --build ${CMAKE_BINARY_DIR}/aocl-libmem/build_dir --config ${CMAKE_BUILD_TYPE} --target install ${parallel}
    WORKING_DIRECTORY ${LIBMEM_DIR}
    RESULT_VARIABLE result
    OUTPUT_VARIABLE output
    ERROR_VARIABLE error
)

# Check the result of the build process
if(result EQUAL 0)
    file(APPEND "${LIBMEM_BUILD_LOG_FILE_PATH}" "${output}.\n")
    message(STATUS "AOCL-LibMem library built successfully.")
else()
    file(APPEND "${LIBMEM_BUILD_LOG_FILE_PATH}" "${error}.\n")
    message(FATAL_ERROR "Error occured while AOCL-LibMem library building!!!.\n${error}\n")
endif()

# Remove unnecessary directories based on the generator
if(substring_position EQUAL -1)
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E remove_directory ${CMAKE_BINARY_DIR}/aocl-libmem/build_dir/CMakeFiles/ShowIncludes
    )
else()
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E remove_directory ${CMAKE_BINARY_DIR}/aocl-libmem/build_dir/CMakeFiles
    )
endif()

# Collect object files and append to the list
string(REPLACE "\\" "/" aocl_libmem_build_path "${CMAKE_BINARY_DIR}/aocl-libmem/build_dir")
file(GLOB_RECURSE aocl_libmem_obj_files LIST_DIRECTORIES false ${aocl_libmem_build_path}/src/*\.${suff})
list(APPEND OBJECT_FILES ${aocl_libmem_obj_files})

# Install the AOCL-LibMem headers
# install(DIRECTORY ${CMAKE_BINARY_DIR}/aocl-libmem/install_package/include/ DESTINATION include)
