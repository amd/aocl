# Copyright (C) 2025, Advanced Micro Devices, Inc. All rights reserved.

# Set CMake policy
cmake_policy(SET CMP0010 NEW)

# Check if the generator is Visual Studio and skip if true
string(FIND "${CMAKE_GENERATOR}" "Visual Studio" substring_position)
if(NOT substring_position EQUAL -1)
    message(WARNING "AOCL-LIBM is not supported by the \"${CMAKE_GENERATOR}\" generator. Hence, skipping!")
    return()
endif()

# Define variables for LIBM path, repository, and build log file
set(LIBM_PATH "" CACHE STRING "Local path of the AOCL-LIBM source code")
set(LIBM_GIT_REPOSITORY "https://github.com/amd/aocl-libm-ose.git" CACHE STRING "AOCL-LIBM git repository path")
set(LIBM_GIT_TAG "master" CACHE STRING "Tag or Branch name of AOCL-LIBM")

set(LIBM_DIR ${CMAKE_BINARY_DIR}/aocl-libm)
set(LIBM_BUILD_LOG_FILE_PATH "${CMAKE_BINARY_DIR}/aocl_libm_build.log")

# Initialize build log file
file(WRITE "${LIBM_BUILD_LOG_FILE_PATH}" "=========================AOCL-LIBM Build Logs=========================.\n")

# Remove existing LIBM directory if it exists
if(EXISTS ${LIBM_DIR})
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E remove_directory ${LIBM_DIR}
    )
endif()

# Use local LIBM source code if provided, otherwise clone from git repository
if(LIBM_PATH)
    message(STATUS "Using AOCL-LIBM source code from ${LIBM_PATH}.")
    file(APPEND "${LIBM_BUILD_LOG_FILE_PATH}" "Using AOCL-LIBM source code from ${LIBM_PATH}.\n")
    string(REPLACE "\\" "/" LIBM_DIR "${LIBM_PATH}/aocl-libm")
else()
    execute_process(
        COMMAND git clone ${LIBM_GIT_REPOSITORY} -b ${LIBM_GIT_TAG} aocl-libm
        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
        RESULT_VARIABLE result
        OUTPUT_VARIABLE output
        ERROR_VARIABLE error
    )
    if(result EQUAL 0)
        file(APPEND "${LIBM_BUILD_LOG_FILE_PATH}" "${output}.\n")
    else()
        file(APPEND "${LIBM_BUILD_LOG_FILE_PATH}" "${error}.\n")
    endif()
endif()

# Log the LIBM path
message(STATUS "LIBM_PATH: ${LIBM_DIR}.")
file(APPEND "${LIBM_BUILD_LOG_FILE_PATH}" "LIBM_PATH: ${LIBM_DIR}.\n")

# Log the start of the configuration and build process
message(STATUS "\"The configuration and build process for the AOCL-LIBM library has started, and logs are being redirected to ${LIBM_BUILD_LOG_FILE_PATH}\"")

# Determine the compiler toolset based on the generator
if(substring_position EQUAL -1)
    set(CompilerToolSet
        -DCMAKE_C_COMPILER=${CMAKE_C_COMPILER} -DCMAKE_CXX_COMPILER=${CMAKE_CXX_COMPILER}
    )
else()
    set(CompilerToolSet "-T${CMAKE_GENERATOR_TOOLSET}")
endif()

# Set the utils library path based on the platform
if(WIN32)
    set(UTILS_LIB "${CMAKE_BINARY_DIR}/aocl-utils/install_package/lib/${Windows_Utils_Lib_Name}")
else()
    set(UTILS_LIB "${CMAKE_BINARY_DIR}/aocl-utils/install_package/lib/${Linux_Utils_Lib_Name}")
endif()

# Log the configuration command
file(APPEND "${LIBM_BUILD_LOG_FILE_PATH}" "CONFIGURATION COMMAND: cmake -G \"${CMAKE_GENERATOR}\" -S ${LIBM_DIR} -B ${CMAKE_BINARY_DIR}/aocl-libm/build_dir -DCMAKE_CONFIGURATION_TYPES=${CMAKE_CONFIGURATION_TYPES} -DBUILD_SHARED_LIBS=${BUILD_SHARED_LIBS} -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE} -DAOCL_UTILS_INCLUDE_DIR=${CMAKE_BINARY_DIR}/aocl-utils/install_package/include -DAOCL_UTILS_LIB=${UTILS_LIB} -DCMAKE_INSTALL_PREFIX=${CMAKE_BINARY_DIR}/aocl-libm/install_package ${CompilerToolSet}.\n")

# Execute the configuration command
execute_process(
    COMMAND cmake -G ${CMAKE_GENERATOR} -S ${LIBM_DIR} -B ${CMAKE_BINARY_DIR}/aocl-libm/build_dir -DCMAKE_CONFIGURATION_TYPES=${CMAKE_CONFIGURATION_TYPES} -DBUILD_SHARED_LIBS=${BUILD_SHARED_LIBS} -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE} -DAOCL_UTILS_INCLUDE_DIR=${CMAKE_BINARY_DIR}/aocl-utils/install_package/include -DAOCL_UTILS_LIB=${UTILS_LIB} -DCMAKE_INSTALL_PREFIX=${CMAKE_BINARY_DIR}/aocl-libm/install_package ${CompilerToolSet}
    WORKING_DIRECTORY ${LIBM_DIR}
    RESULT_VARIABLE result
    OUTPUT_VARIABLE output
    ERROR_VARIABLE error
)
if(result EQUAL 0)
    file(APPEND "${LIBM_BUILD_LOG_FILE_PATH}" "${output}.\n")
    message(STATUS "AOCL-LIBM library configuration completed successfully.")
else()
    file(APPEND "${LIBM_BUILD_LOG_FILE_PATH}" "${error}.\n")
    message(FATAL_ERROR "Error occurred while AOCL-LIBM library configuration!!!.\n${error}\n")
endif()

# Execute the build command
execute_process(
    COMMAND cmake --build ${CMAKE_BINARY_DIR}/aocl-libm/build_dir --config ${CMAKE_BUILD_TYPE} --target install ${parallel}
    WORKING_DIRECTORY ${LIBM_DIR}
    RESULT_VARIABLE result
    OUTPUT_VARIABLE output
    ERROR_VARIABLE error
)

# Check the result of the build process
if(result EQUAL 0)
    file(APPEND "${LIBM_BUILD_LOG_FILE_PATH}" "${output}.\n")
    message(STATUS "AOCL-LIBM library built successfully.")
else()
    file(APPEND "${LIBM_BUILD_LOG_FILE_PATH}" "${error}.\n")
    message(FATAL_ERROR "Error occurred while AOCL-LIBM library building!!!.\n${error}\n")
endif()

# Remove unnecessary directories based on the generator
if(substring_position EQUAL -1)
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E remove_directory ${CMAKE_BINARY_DIR}/aocl-libm/build_dir/CMakeFiles/ShowIncludes
    )
else()
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E remove_directory ${CMAKE_BINARY_DIR}/aocl-libm/build_dir/CMakeFiles
    )
endif()

# Collect object files and append to the list
if(substring_position EQUAL -1)
    string(REPLACE "\\" "/" libm_build_path "${CMAKE_BINARY_DIR}/aocl-libm/build_dir/src")
    string(REPLACE "\\" "/" libm_deffile_path "${CMAKE_BINARY_DIR}/aocl-libm/build_dir/src/CMakeFiles")
    file(GLOB_RECURSE libm_deffile_path LIST_DIRECTORIES false ${libm_deffile_path}/*\.def)
else()
    string(REPLACE "\\" "/" libm_build_path "${CMAKE_BINARY_DIR}/aocl-libm/build_dir/src/alm.dir")
    string(REPLACE "\\" "/" libm_deffile_path "${CMAKE_BINARY_DIR}/aocl-libm/build_dir/src/alm.dir/${CMAKE_BUILD_TYPE}")
    file(GLOB_RECURSE libm_deffile_path LIST_DIRECTORIES false ${libm_deffile_path}/*\.def)
endif()
file(GLOB_RECURSE libm_obj_files LIST_DIRECTORIES false ${libm_build_path}/*\.${suff})
list(FILTER libm_obj_files EXCLUDE REGEX "${libm_build_path}/fast/.*")
list(APPEND DEF_FILES ${libm_deffile_path})
list(APPEND OBJECT_FILES ${libm_obj_files})

# Install the LIBM headers
install(DIRECTORY ${CMAKE_BINARY_DIR}/aocl-libm/install_package/include/ DESTINATION include)
