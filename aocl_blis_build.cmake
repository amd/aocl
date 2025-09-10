# Copyright (C) 2025, Advanced Micro Devices, Inc. All rights reserved.

# Set CMake policy
cmake_policy(SET CMP0010 NEW)

# Define variables for AOCL-BLAS path, repository, and build log file
set(BLAS_PATH "" CACHE STRING "Local path of the AOCL-BLAS source code")
set(BLAS_GIT_REPOSITORY "https://github.com/amd/blis.git" CACHE STRING "AOCL-BLAS git repository path")
set(BLAS_GIT_TAG "master" CACHE STRING "Tag or Branch name of AOCL-BLAS")
set(BLAS_DIR ${CMAKE_BINARY_DIR}/blis)
set(BLAS_BUILD_LOG_FILE_PATH "${CMAKE_BINARY_DIR}/aocl_blis_build.log")

# Initialize build log file
file(WRITE "${BLAS_BUILD_LOG_FILE_PATH}" "=========================AOCL-BLAS Build Logs=========================.\n")

# Remove existing AOCL-BLAS directory if it exists
if(EXISTS ${BLAS_DIR})
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E remove_directory ${BLAS_DIR}
    )
endif()

# Use local AOCL-BLAS source code if provided, otherwise clone from git repository
if(BLAS_PATH)
    message(STATUS "Using AOCL-BLAS source code from ${BLAS_PATH}.")
    file(APPEND "${BLAS_BUILD_LOG_FILE_PATH}" "Using AOCL-BLAS source code from ${BLAS_PATH}.\n")
    string(REPLACE "\\" "/" BLAS_DIR "${BLAS_PATH}/blis")
else()
    execute_process(
        COMMAND git clone ${BLAS_GIT_REPOSITORY} -b ${BLAS_GIT_TAG} blis 
        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
        RESULT_VARIABLE result
        OUTPUT_VARIABLE output
        ERROR_VARIABLE error
    )
    if(result EQUAL 0)
        file(APPEND "${BLAS_BUILD_LOG_FILE_PATH}" "${output}.\n")
    else()
        file(APPEND "${BLAS_BUILD_LOG_FILE_PATH}" "${error}.\n")
    endif()
endif()

# Log the AOCL-BLAS path
message(STATUS "BLAS_PATH: ${BLAS_DIR}.")
file(APPEND "${BLAS_BUILD_LOG_FILE_PATH}" "BLAS_PATH: ${BLAS_DIR}.\n")

# Log the start of the configuration and build process
message(STATUS "\"The configuration and build process for the AOCL-BLAS library has started, and logs are being redirected to ${BLAS_BUILD_LOG_FILE_PATH}\"")

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
file(APPEND "${BLAS_BUILD_LOG_FILE_PATH}" "CONFIGURATION COMMAND: cmake -G \"${CMAKE_GENERATOR}\" -S ${BLAS_DIR} -B ${CMAKE_BINARY_DIR}/blis/build_dir -DCMAKE_CONFIGURATION_TYPES=${CMAKE_CONFIGURATION_TYPES} -DBLIS_CONFIG_FAMILY=${BLIS_CONFIG_FAMILY} -DENABLE_CBLAS=${ENABLE_CBLAS} -DENABLE_ADDON=${ENABLE_ADDON} -DENABLE_THREADING=${ENABLE_THREADING} -DOpenMP_libomp_LIBRARY=${OpenMP_libomp_LIBRARY} -DBLAS_INT_SIZE=${BLAS_INT_SIZE} -DCOMPLEX_RETURN=${COMPLEX_RETURN} -DBUILD_SHARED_LIBS=${BUILD_SHARED_LIBS} -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE} -DENABLE_TRSM_PREINVERSION=${ENABLE_TRSM_PREINVERSION} -DCMAKE_INSTALL_PREFIX=${CMAKE_BINARY_DIR}/blis/install_package ${CompilerToolSet}.\n")

# Execute the configuration command
execute_process(
    COMMAND cmake -G ${CMAKE_GENERATOR} -S ${BLAS_DIR} -B ${CMAKE_BINARY_DIR}/blis/build_dir -DCMAKE_CONFIGURATION_TYPES=${CMAKE_CONFIGURATION_TYPES} -DBLIS_CONFIG_FAMILY=${BLIS_CONFIG_FAMILY} -DENABLE_CBLAS=${ENABLE_CBLAS} -DENABLE_ADDON=${ENABLE_ADDON} -DENABLE_THREADING=${ENABLE_THREADING} -DOpenMP_libomp_LIBRARY=${OpenMP_libomp_LIBRARY} -DBLAS_INT_SIZE=${BLAS_INT_SIZE} -DCOMPLEX_RETURN=${COMPLEX_RETURN} -DBUILD_SHARED_LIBS=${BUILD_SHARED_LIBS} -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE} -DENABLE_TRSM_PREINVERSION=${ENABLE_TRSM_PREINVERSION} -DCMAKE_INSTALL_PREFIX=${CMAKE_BINARY_DIR}/blis/install_package ${CompilerToolSet}
    WORKING_DIRECTORY ${BLAS_DIR}
    RESULT_VARIABLE result
    OUTPUT_VARIABLE output
    ERROR_VARIABLE error
)
if(result EQUAL 0)
    file(APPEND "${BLAS_BUILD_LOG_FILE_PATH}" "${output}.\n")
    message(STATUS "AOCL-BLAS library configuration completed successfully.")
else()
    file(APPEND "${BLAS_BUILD_LOG_FILE_PATH}" "${error}.\n")
    message(FATAL_ERROR "Error occured while AOCL-BLAS library configuration!!!.\n${error}\n")
endif()

# Execute the build command
execute_process(
    COMMAND cmake --build ${CMAKE_BINARY_DIR}/blis/build_dir --config ${CMAKE_BUILD_TYPE} --target install ${parallel}
    WORKING_DIRECTORY ${BLAS_DIR}
    RESULT_VARIABLE result
    OUTPUT_VARIABLE output
    ERROR_VARIABLE error
)

# Check the result of the build process
if(result EQUAL 0)
    file(APPEND "${BLAS_BUILD_LOG_FILE_PATH}" "${output}.\n")
    message(STATUS "AOCL-BLAS library built successfully.")
else()
    file(APPEND "${BLAS_BUILD_LOG_FILE_PATH}" "${error}.\n")
    message(FATAL_ERROR "Error occured while AOCL-BLAS library building!!!.\n${error}\n")
endif()

# Remove unnecessary directories based on the generator
if(substring_position EQUAL -1)
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E remove_directory ${CMAKE_BINARY_DIR}/blis/build_dir/CMakeFiles/ShowIncludes
    )
else()
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E remove_directory ${CMAKE_BINARY_DIR}/blis/build_dir/CMakeFiles
    )
endif()

# Collect object files and append to the list
string(REPLACE "\\" "/" aocl_blas_build_path "${CMAKE_BINARY_DIR}/blis/build_dir")
file(GLOB_RECURSE aocl_blas_obj_files LIST_DIRECTORIES false ${aocl_blas_build_path}/*\.${suff})
list(APPEND OBJECT_FILES ${aocl_blas_obj_files})

# Install the AOCL-BLAS headers
install(DIRECTORY ${CMAKE_BINARY_DIR}/blis/install_package/include/ DESTINATION include)
