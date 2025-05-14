# Copyright (C) 2025, Advanced Micro Devices, Inc. All rights reserved.

# Set CMake policy
cmake_policy(SET CMP0010 NEW)

# Define variables for SPARSE path, repository, and build log file
set(SPARSE_PATH "" CACHE STRING "Local path of the AOCL-Sparse source code")
set(SPARSE_GIT_REPOSITORY "https://github.com/amd/aocl-sparse.git" CACHE STRING "AOCL-Sparse git repository path")
set(SPARSE_GIT_TAG "master" CACHE STRING "Tag or Branch name of AOCL-Sparse")
set(SPARSE_DIR ${CMAKE_BINARY_DIR}/aocl-sparse)
set(SPARSE_BUILD_LOG_FILE_PATH "${CMAKE_BINARY_DIR}/aocl_sparse_build.log")

# Initialize build log file
file(WRITE "${SPARSE_BUILD_LOG_FILE_PATH}" "=========================AOCL-Sparse Build Logs=========================.\n")

# Remove existing SPARSE directory if it exists
if(EXISTS ${SPARSE_DIR})
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E remove_directory ${SPARSE_DIR}
    )
endif()

# Use local SPARSE source code if provided, otherwise clone from git repository
if(SPARSE_PATH)
    message(STATUS "Using AOCL-Sparse source code from ${SPARSE_PATH}.")
    file(APPEND "${SPARSE_BUILD_LOG_FILE_PATH}" "Using AOCL-Sparse source code from ${SPARSE_PATH}.\n")
    string(REPLACE "\\" "/" SPARSE_DIR "${SPARSE_PATH}/aocl-sparse")
else()
    file(APPEND "${SPARSE_BUILD_LOG_FILE_PATH}" "CLONE COMMAND: git clone ${SPARSE_GIT_REPOSITORY} -b ${SPARSE_GIT_TAG} aocl-sparse .\n")
    execute_process(
        COMMAND git clone ${SPARSE_GIT_REPOSITORY} -b ${SPARSE_GIT_TAG} aocl-sparse 
        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
        RESULT_VARIABLE result
        OUTPUT_VARIABLE output
        ERROR_VARIABLE error
    )
    if(result EQUAL 0)
        file(APPEND "${SPARSE_BUILD_LOG_FILE_PATH}" "${output}.\n")
    else()
        file(APPEND "${SPARSE_BUILD_LOG_FILE_PATH}" "${error}.\n")
    endif()
endif()

# Log the SPARSE path
message(STATUS "SPARSE_PATH: ${SPARSE_DIR}.")
file(APPEND "${SPARSE_BUILD_LOG_FILE_PATH}" "SPARSE_PATH: ${SPARSE_DIR}.\n")

# Log the start of the configuration and build process
message(STATUS "\"The configuration and build process for the AOCL-Sparse library has started, and logs are being redirected to ${SPARSE_BUILD_LOG_FILE_PATH}\"")

# Determine the compiler toolset based on the generator
string(FIND "${CMAKE_GENERATOR}" "Visual Studio" substring_position)
if(substring_position EQUAL -1)
    set(CompilerToolSet 
        -DCMAKE_C_COMPILER=${CMAKE_C_COMPILER} -DCMAKE_CXX_COMPILER=${CMAKE_CXX_COMPILER}
    )
else()
    set(CompilerToolSet "-T${CMAKE_GENERATOR_TOOLSET}")
endif()

# Set platform-specific options for libraries
if(WIN32)
    file(GLOB AOCL_BLIS_LIB "${CMAKE_BINARY_DIR}/blis/install_package/lib/*.lib")
    file(GLOB AOCL_LIBFLAME "${CMAKE_BINARY_DIR}/libflame/install_package/lib/*.lib")
    file(GLOB AOCL_UTILS_LIB "${CMAKE_BINARY_DIR}/aocl-utils/install_package/lib/${Windows_Utils_Lib_Name}")
elseif(BUILD_SHARED_LIBS)
    file(GLOB AOCL_BLIS_LIB "${CMAKE_BINARY_DIR}/blis/install_package/lib/*.so")
    file(GLOB AOCL_LIBFLAME "${CMAKE_BINARY_DIR}/libflame/install_package/lib/*.so")
    file(GLOB AOCL_UTILS_LIB "${CMAKE_BINARY_DIR}/aocl-utils/install_package/lib/${Linux_Utils_Lib_Name}")
else()
    file(GLOB AOCL_BLIS_LIB "${CMAKE_BINARY_DIR}/blis/install_package/lib/*.a")
    file(GLOB AOCL_LIBFLAME "${CMAKE_BINARY_DIR}/libflame/install_package/lib/*.a")
    file(GLOB AOCL_UTILS_LIB "${CMAKE_BINARY_DIR}/aocl-utils/install_package/lib/${Linux_Utils_Lib_Name}")
endif()

# Enabling additional cmake flags needed to link openmp in Windows
if(WIN32 AND ENABLE_MULTITHREADING)
    set(OMP_OPTIONS 
        -DEXTERNAL_OMP_LIBRARY=${OpenMP_libomp_LIBRARY} 
        -DUSE_EXTERNAL_OMP_LIB=ON
    )
else()
    set(OMP_OPTIONS "")
endif()

# Log the configuration command
file(APPEND "${SPARSE_BUILD_LOG_FILE_PATH}" "CONFIGURATION COMMAND: cmake -G \"${CMAKE_GENERATOR}\" -S ${SPARSE_DIR} -B ${CMAKE_BINARY_DIR}/aocl-sparse/build_dir -DCMAKE_CONFIGURATION_TYPES=${CMAKE_CONFIGURATION_TYPES} -DBUILD_ILP64=${ENABLE_ILP64} -DSUPPORT_OMP=${ENABLE_MULTITHREADING} -DBUILD_SHARED_LIBS=${BUILD_SHARED_LIBS} -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE} -DAOCL_BLIS_LIB=${AOCL_BLIS_LIB} -DAOCL_BLIS_INCLUDE_DIR=${CMAKE_BINARY_DIR}/blis/install_package/include -DAOCL_LIBFLAME=${AOCL_LIBFLAME} -DAOCL_LIBFLAME_INCLUDE_DIR=${CMAKE_BINARY_DIR}/libflame/install_package/include -DAOCL_UTILS_LIB=${AOCL_UTILS_LIB} -DAOCL_UTILS_INCLUDE_DIR=${CMAKE_BINARY_DIR}/aocl-utils/install_package/include/alci -DCMAKE_INSTALL_PREFIX=${CMAKE_BINARY_DIR}/aocl-sparse/install_package ${OMP_OPTIONS} ${CompilerToolSet}.\n")

# Execute the configuration command
execute_process(
    COMMAND cmake -G ${CMAKE_GENERATOR} -S ${SPARSE_DIR} -B ${CMAKE_BINARY_DIR}/aocl-sparse/build_dir -DCMAKE_CONFIGURATION_TYPES=${CMAKE_CONFIGURATION_TYPES} -DBUILD_ILP64=${ENABLE_ILP64} -DSUPPORT_OMP=${ENABLE_MULTITHREADING} -DBUILD_SHARED_LIBS=${BUILD_SHARED_LIBS} -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE} -DAOCL_BLIS_LIB=${AOCL_BLIS_LIB} -DAOCL_BLIS_INCLUDE_DIR=${CMAKE_BINARY_DIR}/blis/install_package/include -DAOCL_LIBFLAME=${AOCL_LIBFLAME} -DAOCL_LIBFLAME_INCLUDE_DIR=${CMAKE_BINARY_DIR}/libflame/install_package/include -DAOCL_UTILS_LIB=${AOCL_UTILS_LIB} -DAOCL_UTILS_INCLUDE_DIR=${CMAKE_BINARY_DIR}/aocl-utils/install_package/include/alci -DCMAKE_INSTALL_PREFIX=${CMAKE_BINARY_DIR}/aocl-sparse/install_package ${OMP_OPTIONS} ${CompilerToolSet}
    WORKING_DIRECTORY ${SPARSE_DIR}
    RESULT_VARIABLE result
    OUTPUT_VARIABLE output
    ERROR_VARIABLE error
)
if(result EQUAL 0)
    file(APPEND "${SPARSE_BUILD_LOG_FILE_PATH}" "${output}.\n")
    message(STATUS "AOCL-Sparse library configuration completed successfully.")
else()
    file(APPEND "${SPARSE_BUILD_LOG_FILE_PATH}" "${error}.\n")
    message(FATAL_ERROR "Error occured while AOCL-Sparse library configuration!!!.\n${error}\n")
endif()

# Execute the build command
execute_process(
    COMMAND cmake --build ${CMAKE_BINARY_DIR}/aocl-sparse/build_dir --config ${CMAKE_BUILD_TYPE} --target install -j
    WORKING_DIRECTORY ${SPARSE_DIR}
    RESULT_VARIABLE result
    OUTPUT_VARIABLE output
    ERROR_VARIABLE error
)

# Check the result of the build process
if(result EQUAL 0)
    file(APPEND "${SPARSE_BUILD_LOG_FILE_PATH}" "${output}.\n")
    message(STATUS "AOCL-Sparse library built successfully.")
else()
    file(APPEND "${SPARSE_BUILD_LOG_FILE_PATH}" "${error}.\n")
    message(FATAL_ERROR "Error occured while AOCL-Sparse library building!!!.\n${error}\n")
endif()

# Remove unnecessary directories based on the generator
if(substring_position EQUAL -1)
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E remove_directory ${CMAKE_BINARY_DIR}/aocl-sparse/build_dir/CMakeFiles/ShowIncludes
    )
else()
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E remove_directory ${CMAKE_BINARY_DIR}/aocl-sparse/build_dir/CMakeFiles
    )
endif()

# Collect object files and append to the list
string(REPLACE "\\" "/" sparse_build_path "${CMAKE_BINARY_DIR}/aocl-sparse/build_dir/library")
if(substring_position EQUAL -1)
    string(REPLACE "\\" "/" sparse_deffile_path "${CMAKE_BINARY_DIR}/aocl-sparse/build_dir/library/CMakeFiles/aoclsparse.dir/exports.def")
else()
    string(REPLACE "\\" "/" sparse_deffile_path "${CMAKE_BINARY_DIR}/aocl-sparse/build_dir/library/aoclsparse.dir/${CMAKE_BUILD_TYPE}/exports.def")
endif()
file(GLOB_RECURSE sparse_obj_files LIST_DIRECTORIES false ${sparse_build_path}/*\.${suff})
list(APPEND DEF_FILES ${sparse_deffile_path})
list(APPEND OBJECT_FILES ${sparse_obj_files})

# Install the SPARSE headers
install(DIRECTORY ${CMAKE_BINARY_DIR}/aocl-sparse/install_package/include/ DESTINATION include)
