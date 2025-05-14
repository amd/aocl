# Copyright (C) 2025, Advanced Micro Devices, Inc. All rights reserved.

# Set CMake policy
cmake_policy(SET CMP0010 NEW)

# Define variables for LAPACK path, repository, and build log file
set(LAPACK_PATH "" CACHE STRING "Local path of the AOCL-LAPACK source code")
set(LAPACK_GIT_REPOSITORY "https://github.com/amd/libflame.git" CACHE STRING "AOCL-LAPACK git repository path")
set(LAPACK_GIT_TAG "master" CACHE STRING "Tag or Branch name of AOCL-LAPACK")
set(LAPACK_DIR ${CMAKE_BINARY_DIR}/libflame)
set(LAPACK_BUILD_LOG_FILE_PATH "${CMAKE_BINARY_DIR}/aocl_libflame_build.log")

# Initialize build log file
file(WRITE "${LAPACK_BUILD_LOG_FILE_PATH}" "=========================AOCL-LAPACK Build Logs=========================.\n")

# Remove existing AOCL-LAPACK directory if it exists
if(EXISTS ${LAPACK_DIR})
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E remove_directory ${LAPACK_DIR}
    )
endif()

# Use local AOCL-LAPACK source code if provided, otherwise clone from git repository
if(LAPACK_PATH)
    message(STATUS "Using AOCL-LAPACK source code from ${LAPACK_PATH}.")
    file(APPEND "${LAPACK_BUILD_LOG_FILE_PATH}" "Using AOCL-LAPACK source code from ${LAPACK_PATH}.\n")
    string(REPLACE "\\" "/" LAPACK_DIR "${LAPACK_PATH}/libflame")
else()
    execute_process(
        COMMAND git clone ${LAPACK_GIT_REPOSITORY} -b ${LAPACK_GIT_TAG} libflame 
        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
        RESULT_VARIABLE result
        OUTPUT_VARIABLE output
        ERROR_VARIABLE error
    )
    if(result EQUAL 0)
        file(APPEND "${LAPACK_BUILD_LOG_FILE_PATH}" "${output}.\n")
    else()
        file(APPEND "${LAPACK_BUILD_LOG_FILE_PATH}" "${error}.\n")
    endif()
endif()

# Log the AOCL-LAPACK path
message(STATUS "LAPACK_PATH: ${LAPACK_DIR}.")
file(APPEND "${LAPACK_BUILD_LOG_FILE_PATH}" "LAPACK_PATH: ${LAPACK_DIR}.\n")

# Log the start of the configuration and build process
message(STATUS "\"The configuration and build process for the AOCL-LAPACK library has started, and logs are being redirected to ${LAPACK_BUILD_LOG_FILE_PATH}.\"")

# Determine the OpenMP compiler flag based on the compiler
string(FIND "${CMAKE_C_COMPILER}" "gcc" compiler_position)
if(compiler_position EQUAL -1)
    set(OMP_C_FLAG "-fopenmp=libiomp5")
else()
    set(OMP_C_FLAG "-fopenmp")
endif()

# Set AOCL_ROOT and ENABLE_AOCL_BLAS options
if(ENABLE_AOCL_BLAS)
    set(AOCL_BLAS_OPTIONS 
        -DENABLE_AOCL_BLAS=${ENABLE_AOCL_BLAS} 
        -DAOCL_ROOT=${CMAKE_BINARY_DIR}/blis/install_package
    )
endif()

# Set platform-specific options
if(WIN32)
    file(GLOB FILE "${CMAKE_BINARY_DIR}/blis/install_package/lib/*.lib")
    get_filename_component(EXT_BLAS_LIBNAME ${FILE} NAME)
    set(PLATFORM_SPECIFIC_OPTIONS 
        -DEXT_BLAS_LIBNAME=${EXT_BLAS_LIBNAME}
        -DCMAKE_EXT_BLAS_LIBRARY_DEPENDENCY_PATH=${CMAKE_BINARY_DIR}/blis/install_package/lib 
        -DENABLE_AMD_FLAGS=${ENABLE_AMD_FLAGS} 
        -DOpenMP_libomp_LIBRARY=${OpenMP_libomp_LIBRARY} 
        -DLIBAOCLUTILS_LIBRARY_PATH=${CMAKE_BINARY_DIR}/aocl-utils/install_package/lib/${Windows_Utils_Lib_Name}
    )
else()
    set(PLATFORM_SPECIFIC_OPTIONS 
        -DENABLE_AMD_FLAGS=${ENABLE_AMD_FLAGS} 
        -DENABLE_AMD_AOCC_FLAGS=${ENABLE_AMD_AOCC_FLAGS}
        -DCMAKE_C_FLAG="${OMP_C_FLAG}" 
        -DEXT_OPENMP_PATH=${EXT_OPENMP_PATH} 
        -DEXT_OPENMP_LIB=${EXT_OPENMP_LIB} 
        -DLIBAOCLUTILS_LIBRARY_PATH=${CMAKE_BINARY_DIR}/aocl-utils/install_package/lib/${Linux_Utils_Lib_Name}
    )
endif()

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
file(APPEND "${LAPACK_BUILD_LOG_FILE_PATH}" "CONFIGURATION COMMAND: cmake -G \"${CMAKE_GENERATOR}\" -S ${LAPACK_DIR} -B ${CMAKE_BINARY_DIR}/libflame/build_dir -DCMAKE_CONFIGURATION_TYPES=${CMAKE_CONFIGURATION_TYPES} -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE} -DBUILD_SHARED_LIBS=${BUILD_SHARED_LIBS} -DENABLE_ILP64=${ENABLE_ILP64} -DENABLE_BLAS_EXT_GEMMT=${ENABLE_BLAS_EXT_GEMMT} -DLIBAOCLUTILS_INCLUDE_PATH=${CMAKE_BINARY_DIR}/aocl-utils/install_package/include -DENABLE_MULTITHREADING=${ENABLE_MULTITHREADING} -DCMAKE_INSTALL_PREFIX=${CMAKE_BINARY_DIR}/libflame/install_package ${CompilerToolSet} ${PLATFORM_SPECIFIC_OPTIONS} ${AOCL_BLAS_OPTIONS}.\n")

# Execute the configuration command
execute_process(
    COMMAND cmake -G ${CMAKE_GENERATOR} -S ${LAPACK_DIR} -B ${CMAKE_BINARY_DIR}/libflame/build_dir 
    -DCMAKE_CONFIGURATION_TYPES=${CMAKE_CONFIGURATION_TYPES} 
    -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE} 
    -DBUILD_SHARED_LIBS=${BUILD_SHARED_LIBS} 
    -DENABLE_ILP64=${ENABLE_ILP64} 
    -DENABLE_BLAS_EXT_GEMMT=${ENABLE_BLAS_EXT_GEMMT} 
    -DLIBAOCLUTILS_INCLUDE_PATH=${CMAKE_BINARY_DIR}/aocl-utils/install_package/include  
    -DENABLE_MULTITHREADING=${ENABLE_MULTITHREADING} 
    -DCMAKE_INSTALL_PREFIX=${CMAKE_BINARY_DIR}/libflame/install_package 
    ${CompilerToolSet} ${AOCL_BLAS_OPTIONS} 
    ${PLATFORM_SPECIFIC_OPTIONS}
    WORKING_DIRECTORY ${LAPACK_DIR} 
    RESULT_VARIABLE result
    OUTPUT_VARIABLE output
    ERROR_VARIABLE error
)
if(result EQUAL 0)
    file(APPEND "${LAPACK_BUILD_LOG_FILE_PATH}" "${output}.\n")
    message(STATUS "AOCL-LAPACK library configuration completed successfully.")
else()
    file(APPEND "${LAPACK_BUILD_LOG_FILE_PATH}" "${error}.\n")
    message(FATAL_ERROR "Error occured while AOCL-LAPACK library configuration!!!.\n${error}\n")
endif()

# Execute the build command
execute_process(
    COMMAND cmake --build ${CMAKE_BINARY_DIR}/libflame/build_dir --config ${CMAKE_BUILD_TYPE} -j
    WORKING_DIRECTORY ${CMAKE_BINARY_DIR}/libflame/build_dir 
    RESULT_VARIABLE result
    OUTPUT_VARIABLE output
    ERROR_VARIABLE error
)

# Check the result of the build process
if(result EQUAL 0)
    file(APPEND "${LAPACK_BUILD_LOG_FILE_PATH}" "${output}.\n")
    message(STATUS "AOCL-LAPACK library built successfully.")
else()
    file(APPEND "${LAPACK_BUILD_LOG_FILE_PATH}" "${error}.\n")
    message(FATAL_ERROR "Error occured while AOCL-LAPACK library building!!!.\n${error}\n")
endif()

# Execute the install command
execute_process(
    COMMAND cmake --install ${CMAKE_BINARY_DIR}/libflame/build_dir
    WORKING_DIRECTORY ${CMAKE_BINARY_DIR}/libflame/build_dir 
    RESULT_VARIABLE result
    OUTPUT_VARIABLE output
    ERROR_VARIABLE error
)
if(result EQUAL 0)
    file(APPEND "${LAPACK_BUILD_LOG_FILE_PATH}" "${output}.\n")
    message(STATUS "AOCL-LAPACK library installed successfully.")
else()
    file(APPEND "${LAPACK_BUILD_LOG_FILE_PATH}" "${error}.\n")
    message(FATAL_ERROR "Error occured while AOCL-LAPACK library installing!!!.\n${error}\n")
endif()

# Remove unnecessary directories based on the generator
if(substring_position EQUAL -1)
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E remove_directory ${CMAKE_BINARY_DIR}/libflame/build_dir/CMakeFiles/ShowIncludes
    )
else()
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E remove_directory ${CMAKE_BINARY_DIR}/libflame/build_dir/CMakeFiles
    )
endif()

# Collect object files and append to the list
string(REPLACE "\\" "/" aocl_lapack_build_path "${CMAKE_BINARY_DIR}/libflame/build_dir")
file(GLOB_RECURSE aocl_lapack_obj_files LIST_DIRECTORIES false ${aocl_lapack_build_path}/*\.${suff})
if(substring_position EQUAL -1)
    string(REPLACE "\\" "/" aocl_lapack_deffile_path "${CMAKE_BINARY_DIR}/libflame/build_dir/CMakeFiles/AOCL-LibFLAME-Win.dir/exports.def")
else()
    string(REPLACE "\\" "/" aocl_lapack_deffile_path "${CMAKE_BINARY_DIR}/libflame/build_dir/AOCL-LibFLAME-Win.dir/${CMAKE_BUILD_TYPE}/exports.def")
endif()
list(APPEND DEF_FILES ${aocl_lapack_deffile_path})
list(APPEND OBJECT_FILES ${aocl_lapack_obj_files})

# Install the AOCL-LAPACK headers
install(DIRECTORY ${CMAKE_BINARY_DIR}/libflame/install_package/include/ DESTINATION include)
