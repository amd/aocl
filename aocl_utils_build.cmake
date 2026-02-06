# Copyright (C) 2025-2026, Advanced Micro Devices, Inc. All rights reserved.

# Set CMake policy
cmake_policy(SET CMP0010 NEW)

# Define variables for Utils path, repository, and build log file
set(UTILS_PATH "" CACHE STRING "Local path of the AOCL-Utils source code")
set(UTILS_GIT_REPOSITORY "https://github.com/amd/aocl-utils.git" CACHE STRING "AOCL-Utils git repository path")
set(UTILS_GIT_TAG "main" CACHE STRING "Tag or Branch name of AOCL-Utils")
set(UTILS_DIR ${CMAKE_BINARY_DIR}/aocl-utils)
set(UTILS_BUILD_LOG_FILE_PATH "${CMAKE_BINARY_DIR}/aocl_utils_build.log")

# Initialize build log file
file(WRITE "${UTILS_BUILD_LOG_FILE_PATH}" "=========================AOCL-Utils Build Logs=========================.\n")

# Remove existing Utils directory if it exists
if(EXISTS ${UTILS_DIR})
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E remove_directory ${UTILS_DIR}
    )
endif()

# Use local Utils source code if provided, otherwise clone from git repository
if(UTILS_PATH)
    message(STATUS "Using AOCL-Utils source code from ${UTILS_PATH}.")
    file(APPEND "${UTILS_BUILD_LOG_FILE_PATH}" "Using AOCL-Utils source code from ${UTILS_PATH}.\n")
    string(REPLACE "\\" "/" UTILS_DIR "${UTILS_PATH}/aocl-utils")
else()
    execute_process(
        COMMAND git clone ${UTILS_GIT_REPOSITORY} -b ${UTILS_GIT_TAG} aocl-utils
        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
        RESULT_VARIABLE result
        OUTPUT_VARIABLE output
        ERROR_VARIABLE error
    )
    if(result EQUAL 0)
        file(APPEND "${UTILS_BUILD_LOG_FILE_PATH}" "${output}.\n")
    else()
        file(APPEND "${UTILS_BUILD_LOG_FILE_PATH}" "${error}.\n")
    endif()
endif()

# Log the Utils path
message(STATUS "Utils_PATH: ${UTILS_DIR}.")
file(APPEND "${UTILS_BUILD_LOG_FILE_PATH}" "Utils_PATH: ${UTILS_DIR}.\n")

# Log the start of the configuration and build process
message(STATUS "\"The configuration and build process for the AOCL-Utils library has started, and logs are being redirected to ${UTILS_BUILD_LOG_FILE_PATH}\"")

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
file(APPEND "${UTILS_BUILD_LOG_FILE_PATH}" "CONFIGURATION COMMAND: cmake -G \"${CMAKE_GENERATOR}\" -S ${UTILS_DIR} -B ${CMAKE_BINARY_DIR}/aocl-utils/build_dir -DALCI_EXAMPLES=OFF -DCMAKE_CONFIGURATION_TYPES=${CMAKE_CONFIGURATION_TYPES} -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE} -DBUILD_SHARED_LIBS=${BUILD_SHARED_LIBS} -DCMAKE_INSTALL_PREFIX=${CMAKE_BINARY_DIR}/aocl-utils/install_package ${CompilerToolSet}.\n")

# Execute the configuration command
execute_process(
    COMMAND cmake -G ${CMAKE_GENERATOR} -S ${UTILS_DIR} -B ${CMAKE_BINARY_DIR}/aocl-utils/build_dir -DALCI_EXAMPLES=OFF -DCMAKE_CONFIGURATION_TYPES=${CMAKE_CONFIGURATION_TYPES} -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE} -DBUILD_SHARED_LIBS=${BUILD_SHARED_LIBS} -DCMAKE_INSTALL_PREFIX=${CMAKE_BINARY_DIR}/aocl-utils/install_package ${CompilerToolSet}
    WORKING_DIRECTORY ${UTILS_DIR} 
    RESULT_VARIABLE result
    OUTPUT_VARIABLE output
    ERROR_VARIABLE error
)
if(result EQUAL 0)
    file(APPEND "${UTILS_BUILD_LOG_FILE_PATH}" "${output}.\n")
    message(STATUS "AOCL-Utils library configuration completed successfully.")
else()
    file(APPEND "${UTILS_BUILD_LOG_FILE_PATH}" "${error}.\n")
    message(FATAL_ERROR "Error occured while AOCL-Utils library configuration!!!.\n${error}\n")
endif()

# Log the build command
file(APPEND "${UTILS_BUILD_LOG_FILE_PATH}" "BUILD COMMAND: cmake --build ${CMAKE_BINARY_DIR}/aocl-utils/build_dir --config ${CMAKE_BUILD_TYPE} --target install.\n")

# Execute the build command
execute_process(
    COMMAND cmake --build ${CMAKE_BINARY_DIR}/aocl-utils/build_dir --config ${CMAKE_BUILD_TYPE} --target install
    WORKING_DIRECTORY ${UTILS_DIR}
    RESULT_VARIABLE result
    OUTPUT_VARIABLE output
    ERROR_VARIABLE error
)

# Check the result of the build process
if(result EQUAL 0)
    file(APPEND "${UTILS_BUILD_LOG_FILE_PATH}" "${output}.\n")
    message(STATUS "AOCL-Utils library built successfully.")
else()
    file(APPEND "${UTILS_BUILD_LOG_FILE_PATH}" "${error}.\n")
    message(FATAL_ERROR "Error occured while AOCL-Utils library building!!!.\n${error}\n")
endif()

# Remove unnecessary directories based on the generator
if(substring_position EQUAL -1)
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E remove_directory ${CMAKE_BINARY_DIR}/aocl-utils/build_dir/CMakeFiles/ShowIncludes
    )
else()
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E remove_directory ${CMAKE_BINARY_DIR}/aocl-utils/build_dir/CMakeFiles/
    )
endif()

# Set the utils folder name based on the platform
if(WIN32)
    set(utils_folder_name libaoclutils_shared.dir)
else()
    set(utils_folder_name aoclutils_shared.dir)
endif()

# Collect object files and append to the list
if(substring_position EQUAL -1)
    string(REPLACE "\\" "/" utils_build_path "${CMAKE_BINARY_DIR}/aocl-utils/build_dir/Library/CMakeFiles/${utils_folder_name}")
else()
    string(REPLACE "\\" "/" utils_build_path "${CMAKE_BINARY_DIR}/aocl-utils/build_dir/Library/${utils_folder_name}/${CMAKE_BUILD_TYPE}")
endif()
file(GLOB_RECURSE utils_obj_files LIST_DIRECTORIES false ${utils_build_path}/*\.${suff})
list(APPEND OBJECT_FILES ${utils_obj_files})

# Install the Utils headers
install(DIRECTORY ${CMAKE_BINARY_DIR}/aocl-utils/install_package/include/ DESTINATION include)
