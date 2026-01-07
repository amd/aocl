# Copyright (C) 2025, Advanced Micro Devices, Inc. All rights reserved.

# Set CMake policy
cmake_policy(SET CMP0010 NEW)

# Define variables for AOCL-DA path, repository, and build log file
set(DA_PATH "" CACHE STRING "Local path of the AOCL-DA source code")
set(DA_GIT_REPOSITORY "https://github.com/amd/aocl-data-analytics.git" CACHE STRING "AOCL-DA git repository path")
set(DA_GIT_TAG "main" CACHE STRING "Tag or Branch name of AOCL-DA")
set(DA_DIR ${CMAKE_BINARY_DIR}/aocl-data-analytics)
set(DA_BUILD_LOG_FILE_PATH "${CMAKE_BINARY_DIR}/aocl_da_build.log")

# Initialize build log file
file(WRITE "${DA_BUILD_LOG_FILE_PATH}" "=========================AOCL-DA Build Logs=========================.\n")

# Remove existing AOCL-DA directory if it exists
if(EXISTS ${DA_DIR})
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E remove_directory ${DA_DIR}
    )
endif()

# Use local AOCL-DA source code if provided, otherwise clone from git repository
if(DA_PATH)
    message(STATUS "Using AOCL-DA source code from ${DA_PATH}.")
    file(APPEND "${DA_BUILD_LOG_FILE_PATH}" "Using AOCL-DA source code from ${DA_PATH}.\n")
    string(REPLACE "\\" "/" DA_DIR "${DA_PATH}/aocl-data-analytics")
else()
    execute_process(
        COMMAND git clone ${DA_GIT_REPOSITORY} -b ${DA_GIT_TAG} aocl-data-analytics 
        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
        RESULT_VARIABLE result
        OUTPUT_VARIABLE output
        ERROR_VARIABLE error
    )
    if(result EQUAL 0)
        file(APPEND "${DA_BUILD_LOG_FILE_PATH}" "${output}.\n")
    else()
        file(APPEND "${DA_BUILD_LOG_FILE_PATH}" "${error}.\n")
    endif()
endif()

# Log the AOCL-DA path
message(STATUS "DA_PATH: ${DA_DIR}.")
file(APPEND "${DA_BUILD_LOG_FILE_PATH}" "DA_PATH: ${DA_DIR}.\n")

# Log the start of the configuration and build process
message(STATUS "\"The configuration and build process for the AOCL-DA library has started, and logs are being redirected to ${DA_BUILD_LOG_FILE_PATH}\"")

# Determine the compiler toolset based on the generator
string(FIND "${CMAKE_GENERATOR}" "Visual Studio" substring_position)
if(substring_position EQUAL -1)
    # set(core_count -j1)
    set(CompilerToolSet 
        -DCMAKE_C_COMPILER=${CMAKE_C_COMPILER} -DCMAKE_CXX_COMPILER=${CMAKE_CXX_COMPILER} -DCMAKE_Fortran_COMPILER=${CMAKE_Fortran_COMPILER}
    )
else()
    set(CompilerToolSet "-T${CMAKE_GENERATOR_TOOLSET}")
endif()

# Set platform-specific options for libraries
if(WIN32)
    file(GLOB AOCL_BLIS_LIB "${CMAKE_BINARY_DIR}/blis/install_package/lib/*.lib")
    file(GLOB AOCL_LIBFLAME "${CMAKE_BINARY_DIR}/libflame/install_package/lib/*.lib")
    file(GLOB AOCL_UTILS_LIB "${CMAKE_BINARY_DIR}/aocl-utils/install_package/lib/${Windows_Utils_Lib_Name}")
    file(GLOB AOCL_SPARSE_LIB "${CMAKE_BINARY_DIR}/aocl-sparse/install_package/lib/*.lib")
elseif(BUILD_SHARED_LIBS)
    file(GLOB AOCL_BLIS_LIB "${CMAKE_BINARY_DIR}/blis/install_package/lib/*.so")
    file(GLOB AOCL_LIBFLAME "${CMAKE_BINARY_DIR}/libflame/install_package/lib/*.so")
    file(GLOB AOCL_UTILS_LIB "${CMAKE_BINARY_DIR}/aocl-utils/install_package/lib/${Linux_Utils_Lib_Name}")
    file(GLOB AOCL_SPARSE_LIB "${CMAKE_BINARY_DIR}/aocl-sparse/install_package/lib/*.so")
else()
    file(GLOB AOCL_BLIS_LIB "${CMAKE_BINARY_DIR}/blis/install_package/lib/*.a")
    file(GLOB AOCL_LIBFLAME "${CMAKE_BINARY_DIR}/libflame/install_package/lib/*.a")
    file(GLOB AOCL_UTILS_LIB "${CMAKE_BINARY_DIR}/aocl-utils/install_package/lib/${Linux_Utils_Lib_Name}")
    file(GLOB AOCL_SPARSE_LIB "${CMAKE_BINARY_DIR}/aocl-sparse/install_package/lib/*.a")
endif()

# Log the configuration command
file(APPEND "${DA_BUILD_LOG_FILE_PATH}" "CONFIGURATION COMMAND: cmake -G \"${CMAKE_GENERATOR}\" -S ${DA_DIR} -B ${CMAKE_BINARY_DIR}/aocl-data-analytics/build_dir -DCMAKE_CONFIGURATION_TYPES=${CMAKE_CONFIGURATION_TYPES} -DBUILD_ILP64=${ENABLE_ILP64} -DBUILD_GTEST=OFF -DARCH=dynamic -DLAPACK_LIB=${AOCL_LIBFLAME} -DBLAS_LIB=${AOCL_BLIS_LIB} -DSPARSE_LIB=${AOCL_SPARSE_LIB} -DUTILS_LIB=${AOCL_UTILS_LIB} -DUTILS_CPUID_LIB=${AOCL_UTILS_LIB} -DLAPACK_INCLUDE_DIR=${CMAKE_BINARY_DIR}/libflame/install_package/include -DBLAS_INCLUDE_DIR=${CMAKE_BINARY_DIR}/blis/install_package/include -DSPARSE_INCLUDE_DIR=${CMAKE_BINARY_DIR}/aocl-sparse/install_package/include -DUTILS_INCLUDE_DIR=${CMAKE_BINARY_DIR}/aocl-utils/install_package/include -DBUILD_SMP=${ENABLE_THREADING} -DOpenMP_libomp_LIBRARY=${OpenMP_libomp_LIBRARY} -DBUILD_SHARED_LIBS=${BUILD_SHARED_LIBS} -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE} -DCMAKE_INSTALL_PREFIX=${CMAKE_BINARY_DIR}/aocl-data-analytics/install_package ${CompilerToolSet}.\n")

# Execute the configuration command
execute_process(
    COMMAND cmake -G ${CMAKE_GENERATOR} -S ${DA_DIR} -B ${CMAKE_BINARY_DIR}/aocl-data-analytics/build_dir -DCMAKE_CONFIGURATION_TYPES=${CMAKE_CONFIGURATION_TYPES} -DBUILD_ILP64=${ENABLE_ILP64} -DBUILD_GTEST=OFF -DARCH=dynamic -DLAPACK_LIB=${AOCL_LIBFLAME} -DBLAS_LIB=${AOCL_BLIS_LIB} -DSPARSE_LIB=${AOCL_SPARSE_LIB} -DUTILS_LIB=${AOCL_UTILS_LIB} -DUTILS_CPUID_LIB=${AOCL_UTILS_LIB} -DLAPACK_INCLUDE_DIR=${CMAKE_BINARY_DIR}/libflame/install_package/include -DBLAS_INCLUDE_DIR=${CMAKE_BINARY_DIR}/blis/install_package/include -DSPARSE_INCLUDE_DIR=${CMAKE_BINARY_DIR}/aocl-sparse/install_package/include -DUTILS_INCLUDE_DIR=${CMAKE_BINARY_DIR}/aocl-utils/install_package/include -DBUILD_SMP=${ENABLE_THREADING} -DOpenMP_libomp_LIBRARY=${OpenMP_libomp_LIBRARY} -DBUILD_SHARED_LIBS=${BUILD_SHARED_LIBS} -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE} -DCMAKE_INSTALL_PREFIX=${CMAKE_BINARY_DIR}/aocl-data-analytics/install_package ${CompilerToolSet} 
    WORKING_DIRECTORY ${DA_DIR}
    RESULT_VARIABLE result
    OUTPUT_VARIABLE output
    ERROR_VARIABLE error
)
if(result EQUAL 0)
    file(APPEND "${DA_BUILD_LOG_FILE_PATH}" "${output}.\n")
    message(STATUS "AOCL-DA library configuration completed successfully.")
else()
    file(APPEND "${DA_BUILD_LOG_FILE_PATH}" "${error}.\n")
    message(FATAL_ERROR "Error occured while AOCL-DA library configuration!!!.\n${error}\n")
endif()

# Execute the build command
execute_process(
    COMMAND cmake --build ${CMAKE_BINARY_DIR}/aocl-data-analytics/build_dir --config ${CMAKE_BUILD_TYPE} --target install ${parallel}
    WORKING_DIRECTORY ${DA_DIR}
    RESULT_VARIABLE result
    OUTPUT_VARIABLE output
    ERROR_VARIABLE error
)

# Check the result of the build process
if(result EQUAL 0)
    file(APPEND "${DA_BUILD_LOG_FILE_PATH}" "${output}.\n")
    message(STATUS "AOCL-DA library built successfully.")
else()
    file(APPEND "${DA_BUILD_LOG_FILE_PATH}" "${error}.\n")
    message(FATAL_ERROR "Error occured while AOCL-DA library building!!!.\n${error}\n")
endif()

# Remove unnecessary directories based on the generator
if(substring_position EQUAL -1)
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E remove_directory ${CMAKE_BINARY_DIR}/aocl-data-analytics/build_dir/CMakeFiles/ShowIncludes
    )
else()
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E remove_directory ${CMAKE_BINARY_DIR}/aocl-data-analytics/build_dir/CMakeFiles
    )
endif()

# Collect object files and append to the list
if(substring_position EQUAL -1)
    string(REPLACE "\\" "/" aocl_da_build_path "${CMAKE_BINARY_DIR}/aocl-data-analytics/build_dir/source")
    file(GLOB_RECURSE aocl_da_obj_files LIST_DIRECTORIES false ${aocl_da_build_path}/*\.${suff})
    list(APPEND OBJECT_FILES ${aocl_da_obj_files})
    string(REPLACE "\\" "/" aocl_da_build_path "${CMAKE_BINARY_DIR}/aocl-data-analytics/build_dir/external")
    file(GLOB_RECURSE aocl_da_obj_files LIST_DIRECTORIES false ${aocl_da_build_path}/*\.${suff})
    string(REPLACE "\\" "/" aocl_da_deffile_path "${CMAKE_BINARY_DIR}/aocl-data-analytics/build_dir/source/CMakeFiles/aocl-da.dir")
    file(GLOB_RECURSE aocl_da_deffile_path LIST_DIRECTORIES false ${aocl_da_deffile_path}/*\.def)
else()
    string(REPLACE "\\" "/" aocl_da_build_path "${CMAKE_BINARY_DIR}/aocl-data-analytics/build_dir/source")
    file(GLOB_RECURSE aocl_da_obj_files LIST_DIRECTORIES false ${aocl_da_build_path}/*\.${suff})
    list(APPEND OBJECT_FILES ${aocl_da_obj_files})
    string(REPLACE "\\" "/" aocl_da_build_path "${CMAKE_BINARY_DIR}/aocl-data-analytics/build_dir/external")
    file(GLOB_RECURSE aocl_da_obj_files LIST_DIRECTORIES false ${aocl_da_build_path}/*\.${suff})
    string(REPLACE "\\" "/" aocl_da_deffile_path "${CMAKE_BINARY_DIR}/aocl-data-analytics/build_dir/source/aocl-da.dir/${CMAKE_BUILD_TYPE}")
    file(GLOB_RECURSE aocl_da_deffile_path LIST_DIRECTORIES false ${aocl_da_deffile_path}/*\.def)
endif()
list(APPEND OBJECT_FILES ${aocl_da_obj_files})
list(APPEND DEF_FILES ${aocl_da_deffile_path})

# Install the AOCL-DA headers
if(ENABLE_ILP64)
    install(DIRECTORY ${CMAKE_BINARY_DIR}/aocl-data-analytics/install_package/include/ILP64/ DESTINATION include)
else()
    install(DIRECTORY ${CMAKE_BINARY_DIR}/aocl-data-analytics/install_package/include/LP64/ DESTINATION include)
endif()
