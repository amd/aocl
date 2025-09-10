# Copyright (C) 2025, Advanced Micro Devices, Inc. All rights reserved.

# Set CMake policy
cmake_policy(SET CMP0010 NEW)

# Define variables for COMPRESSION path, repository, and build log file
set(COMPRESSION_PATH "" CACHE STRING "Local path of the AOCL-COMPRESSION source code")
set(COMPRESSION_GIT_REPOSITORY "https://github.com/amd/aocl-compression.git" CACHE STRING "AOCL-COMPRESSION git repository path")
set(COMPRESSION_GIT_TAG "amd-main" CACHE STRING "Tag or Branch name of AOCL-Compression")
set(COMPRESSION_DIR ${CMAKE_BINARY_DIR}/aocl-compression CACHE STRING "AOCL-COMPRESSION source code directory")
set(COMPRESSION_BUILD_LOG_FILE_PATH "${CMAKE_BINARY_DIR}/aocl_compression_build.log")

# Initialize build log file
file(WRITE "${COMPRESSION_BUILD_LOG_FILE_PATH}" "=========================AOCL-COMPRESSION Build Logs=========================.\n")

# Remove existing COMPRESSION directory if it exists
if(EXISTS ${COMPRESSION_DIR})
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E remove_directory ${COMPRESSION_DIR}
    )
endif()

# Use local COMPRESSION source code if provided, otherwise clone from git repository
if(COMPRESSION_PATH)
    message(STATUS "Using AOCL-COMPRESSION source code from ${COMPRESSION_PATH}.")
    file(APPEND "${COMPRESSION_BUILD_LOG_FILE_PATH}" "Using AOCL-COMPRESSION source code from ${COMPRESSION_PATH}.\n")
    string(REPLACE "\\" "/" COMPRESSION_DIR "${COMPRESSION_PATH}/aocl-compression")
else()
    execute_process(
        COMMAND git clone ${COMPRESSION_GIT_REPOSITORY} -b ${COMPRESSION_GIT_TAG} aocl-compression 
        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
        RESULT_VARIABLE result
        OUTPUT_VARIABLE output
        ERROR_VARIABLE error
    )
    if(result EQUAL 0)
        file(APPEND "${COMPRESSION_BUILD_LOG_FILE_PATH}" "${output}.\n")
    else()
        file(APPEND "${COMPRESSION_BUILD_LOG_FILE_PATH}" "${error}.\n")
    endif()
endif()

# Log the COMPRESSION path
message(STATUS "COMPRESSION_PATH: ${COMPRESSION_DIR}.")
file(APPEND "${COMPRESSION_BUILD_LOG_FILE_PATH}" "COMPRESSION_PATH: ${COMPRESSION_DIR}.\n")

# Log the start of the configuration and build process
message(STATUS "\"The configuration and build process for the AOCL-COMPRESSION library has started, and logs are being redirected to ${COMPRESSION_BUILD_LOG_FILE_PATH}\"")

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
file(APPEND "${COMPRESSION_BUILD_LOG_FILE_PATH}" "CONFIGURATION COMMAND: cmake -G \"${CMAKE_GENERATOR}\" -S ${COMPRESSION_DIR} -B ${CMAKE_BINARY_DIR}/aocl-compression/build_dir -DCMAKE_CONFIGURATION_TYPES=${CMAKE_CONFIGURATION_TYPES} -DBUILD_STATIC_LIBS=${BUILD_STATIC_LIBS} -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE} -DAOCL_ENABLE_THREADS=${AOCL_ENABLE_THREADS} -DOpenMP_libomp_LIBRARY=${OpenMP_libomp_LIBRARY} -DCMAKE_INSTALL_PREFIX=${CMAKE_BINARY_DIR}/aocl-compression/install_package ${CompilerToolSet}.\n")

# Execute the configuration command
execute_process(
    COMMAND cmake -G ${CMAKE_GENERATOR} -S ${COMPRESSION_DIR} -B ${CMAKE_BINARY_DIR}/aocl-compression/build_dir -DCMAKE_CONFIGURATION_TYPES=${CMAKE_CONFIGURATION_TYPES} -DBUILD_STATIC_LIBS=${BUILD_STATIC_LIBS} -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE} -DAOCL_ENABLE_THREADS=${AOCL_ENABLE_THREADS} -DOpenMP_libomp_LIBRARY=${OpenMP_libomp_LIBRARY} -DCMAKE_INSTALL_PREFIX=${CMAKE_BINARY_DIR}/aocl-compression/install_package ${CompilerToolSet}
    WORKING_DIRECTORY ${COMPRESSION_DIR}
    RESULT_VARIABLE result
    OUTPUT_VARIABLE output
    ERROR_VARIABLE error
)
if(result EQUAL 0)
    file(APPEND "${COMPRESSION_BUILD_LOG_FILE_PATH}" "${output}.\n")
    message(STATUS "AOCL-COMPRESSION library configuration completed successfully.")
else()
    file(APPEND "${COMPRESSION_BUILD_LOG_FILE_PATH}" "${error}.\n")
    message(FATAL_ERROR "Error occured while AOCL-COMPRESSION library configuration!!!.\n${error}\n")
endif()

# Execute the build command
execute_process(
    COMMAND cmake --build ${CMAKE_BINARY_DIR}/aocl-compression/build_dir --config ${CMAKE_BUILD_TYPE} --target install ${parallel}
    WORKING_DIRECTORY ${COMPRESSION_DIR}
    RESULT_VARIABLE result
    OUTPUT_VARIABLE output
    ERROR_VARIABLE error
)

# Check the result of the build process
if(result EQUAL 0)
    file(APPEND "${COMPRESSION_BUILD_LOG_FILE_PATH}" "${output}.\n")
    message(STATUS "AOCL-COMPRESSION library built successfully.")
else()
    file(APPEND "${COMPRESSION_BUILD_LOG_FILE_PATH}" "${error}.\n")
    message(FATAL_ERROR "Error occured while AOCL-COMPRESSION library building!!!.\n${error}\n")
endif()

# Remove unnecessary directories based on the generator
if(substring_position EQUAL -1)
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E remove_directory ${CMAKE_BINARY_DIR}/aocl-compression/build_dir/CMakeFiles/ShowIncludes
    )
else()
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E remove_directory ${CMAKE_BINARY_DIR}/aocl-compression/build_dir/CMakeFiles
    )
endif()

# Collect object files and append to the list
if(substring_position EQUAL -1)
    string(REPLACE "\\" "/" compression_build_path "${CMAKE_BINARY_DIR}/aocl-compression/build_dir/CMakeFiles/aocl_compression.dir")
else()
    string(REPLACE "\\" "/" compression_build_path "${CMAKE_BINARY_DIR}/aocl-compression/build_dir/aocl_compression.dir")
endif()
file(GLOB_RECURSE compression_obj_files LIST_DIRECTORIES false ${compression_build_path}/*\.${suff})
list(APPEND OBJECT_FILES ${compression_obj_files})

# Install the COMPRESSION headers
install(DIRECTORY ${CMAKE_BINARY_DIR}/aocl-compression/install_package/include/ DESTINATION include)
