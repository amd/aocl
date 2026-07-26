# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
#
# AOCL-DA (Data Analytics) component -- target-based build (FetchContent +
# add_subdirectory).
#
# PURPOSE
#   Builds AOCL-DA in-tree so its compiled OBJECT files go straight into the
#   unified libaocl (via `$<TARGET_OBJECTS>`, not archive merging). DA sits at the
#   TOP of the AOCL dependency graph: it consumes AOCL-BLAS, AOCL-LAPACK,
#   AOCL-Sparse and AOCL-Utils (all brought in-tree before this file).
#
# HOW IT WORKS (step by step)
#   1. Guarded by ENABLE_AOCL_DA so the component is opt-in.
#   2. DA_PATH points at the patched sources under
#      submodules/aocl-data-analytics.
#   3. Boost (header-only, Boost.Sort, >=1.66) is located: honour BOOST_ROOT (var
#      or env), else fall back to the in-repo local copy.
#   4. Optional newer AOCL-Utils CPUID enums (avx512_fp16, Zen6) are forwarded as
#      extra C++ defines only when the in-tree utils headers actually define them.
#   5. aocl_resolve_component(DA) resolves the per-component threading
#      (`_da_smp` = openmp/no).
#   6. DA enables Fortran in its sub-build (the top-level project is C/CXX only),
#      so a Fortran compiler is supplied: gfortran on Unix, Intel ifx/ifort on
#      Windows, with the Fortran objects forced onto the static MT runtime (/MT)
#      and the matching Intel Fortran runtime import libs added to the link.
#   7. A block() isolates the forced cache settings and points DA's dependency
#      overrides (BLAS_LIB / LAPACK_LIB / SPARSE_LIB / UTILS_LIB) at the in-tree
#      target names (a non-empty value bypasses DA's find_library), feeding the
#      matching exported include dirs. FetchContent then add_subdirectory()s the
#      tree; dirs cached as AOCL_TB_DA_SRC / AOCL_TB_DA_BIN.
#   8. The generated BLIS headers are forced to build first via
#      aocl_tb_force_target_deps_recursive (same internal-OBJECT-library race fix
#      as LAPACK).
#   9. aocl_tb_add_whole_lib() merges the (self-contained, Fortran externals
#      lbfgsb + RALFit embedded as OBJECT files) archive into libaocl;
#      aocl_tb_install_component / emit_shared / register_manifest stage the lib +
#      headers, emit the shared lib (shared builds), and record the manifest.

if(ENABLE_AOCL_DA)
    message(STATUS "[aocl] Configuring AOCL-DA (FetchContent + add_subdirectory)")

    # Source selection (precedence: local path > submodules > git clone).
    set(DA_PATH "" CACHE STRING "Local path of AOCL-DA source (parent dir containing 'aocl-data-analytics'); overrides submodules/git")
    set(DA_GIT_REPOSITORY "https://github.com/amd/aocl-data-analytics.git" CACHE STRING "AOCL-DA git repository (used when submodules are off and DA_PATH is empty)")
    set(DA_GIT_TAG "main" CACHE STRING "AOCL-DA git branch/tag")

    # Boost (header-only, >=1.66). Honour an existing BOOST_ROOT, otherwise fall
    # back to the in-repo local copy.
    set(_da_boost "")
    if(BOOST_ROOT)
        set(_da_boost "${BOOST_ROOT}")
    elseif(DEFINED ENV{BOOST_ROOT})
        set(_da_boost "$ENV{BOOST_ROOT}")
    else()
        set(_da_boost_local "${CMAKE_SOURCE_DIR}/../boost_local/usr")
        if(EXISTS "${_da_boost_local}/include/boost/version.hpp")
            set(_da_boost "${_da_boost_local}")
        endif()
    endif()

    # Use the newer AOCL-Utils CPUID enums (avx512_fp16, Zen6) only when the
    # in-tree utils headers actually define them (the source falls back
    # gracefully otherwise). Forwarded as extra C++ defines to DA's build.
    set(_da_cxx_flags "")
    set(_au_enum "${AOCL_LIB_SRC}/aocl-utils/SDK/Include/Au/Cpuid/Enum.hh")
    if(EXISTS "${_au_enum}")
        file(READ "${_au_enum}" _au_enum_txt)
        if(_au_enum_txt MATCHES "avx512_fp16")
            string(APPEND _da_cxx_flags " -DAU_HAS_AVX512_FP16")
        endif()
        if(_au_enum_txt MATCHES "Zen6")
            string(APPEND _da_cxx_flags " -DAU_HAS_ZEN6")
        endif()
    endif()

    # Per-component threading (inherit => identical to the global value).
    aocl_resolve_component(DA)
    if(AOCL_DA_THREADS_ON)
        set(_da_smp "openmp")
    else()
        set(_da_smp "no")
    endif()

    # DA enables Fortran in its sub-build. The top-level project is C/CXX only,
    # so we must point it at a Fortran compiler. On Windows there is no gfortran;
    # use Intel ifx (oneAPI) when available. The Fortran objects are forced onto
    # the static multithreaded runtime (/MT) so they agree with the rest of the
    # stack at the final unified link.
    set(_da_fc "")
    set(_da_fc_flags "")
    set(_da_external_libs gfortran quadmath)
    if(WIN32)
        find_program(AOCL_DA_FC NAMES ifx ifort
            HINTS "$ENV{ONEAPI_ROOT}/compiler/latest/bin"
                  "C:/Program Files (x86)/Intel/oneAPI/compiler/latest/bin")
        if(AOCL_DA_FC)
            set(_da_fc "${AOCL_DA_FC}")
            set(_da_fc_flags "/MT")
        else()
            message(WARNING "[aocl] AOCL-DA needs a Fortran compiler on Windows "
                "(ifx/ifort) but none was found; the DA build will fail.")
        endif()

        # The unified aocl.dll (and per-component aocl-da.dll) whole-archive DA's
        # static lib, pulling in Intel Fortran runtime symbols; supply the Intel
        # static multithreaded (_mt) Fortran runtime import libraries (the GNU
        # gfortran/quadmath used on Linux do not exist here).
        set(_da_fc_libs "")
        if(AOCL_DA_FC)
            get_filename_component(_da_fc_bin "${AOCL_DA_FC}" DIRECTORY)
            get_filename_component(_da_fc_root "${_da_fc_bin}" DIRECTORY)
            set(_da_fc_libdir "${_da_fc_root}/lib")
            foreach(_fl IN ITEMS
                    libifcoremt libifport libirc libircmt
                    svml_dispmt libdecimal libmmt libmatmul)
                if(EXISTS "${_da_fc_libdir}/${_fl}.lib")
                    list(APPEND _da_fc_libs "${_da_fc_libdir}/${_fl}.lib")
                endif()
            endforeach()
        endif()
        set(_da_external_libs ${_da_fc_libs})
    endif()

    block()
        # Static PIC archive only -- its objects feed libaocl (and /MT on Windows).
        set(BUILD_SHARED_LIBS OFF)
        if(_da_fc)
            set(CMAKE_Fortran_COMPILER "${_da_fc}" CACHE FILEPATH "" FORCE)
        endif()
        if(_da_fc_flags)
            set(CMAKE_Fortran_FLAGS "${_da_fc_flags}" CACHE STRING "" FORCE)
        endif()

        # In-tree dependency targets (non-empty -> DA bypasses find_library).
        set(BLAS_LIB        blis_static CACHE STRING "" FORCE)
        set(LAPACK_LIB      flame       CACHE STRING "" FORCE)
        set(SPARSE_LIB      aoclsparse  CACHE STRING "" FORCE)
        set(UTILS_LIB       aoclutils   CACHE STRING "" FORCE)
        set(UTILS_CPUID_LIB aoclutils   CACHE STRING "" FORCE)
        set(BLAS_INCLUDE_DIR   "${AOCL_TB_BLAS_INCLUDE_DIR}"   CACHE STRING "" FORCE)
        set(LAPACK_INCLUDE_DIR "${AOCL_TB_LAPACK_INCLUDE_DIR}" CACHE STRING "" FORCE)
        set(SPARSE_INCLUDE_DIR "${AOCL_TB_SPARSE_INCLUDE_DIR}" CACHE STRING "" FORCE)
        set(UTILS_INCLUDE_DIR  "${AOCL_TB_UTILS_INCLUDE_DIR}"  CACHE STRING "" FORCE)
        # In-tree AOCL-DLP (non-Windows: DA's fp16 path links it). A non-empty
        # DLP_LIB makes DA bypass its find_library(DLP) and use the in-tree target.
        if(NOT WIN32 AND ENABLE_AOCL_DLP)
            set(DLP_LIB         aocl-dlp_static                CACHE STRING "" FORCE)
            set(DLP_INCLUDE_DIR "${AOCL_TB_DLP_INCLUDE_DIR}"   CACHE STRING "" FORCE)
        endif()

        set(BOOST_ROOT      "${_da_boost}"     CACHE PATH   "" FORCE)
        # Append DA's CPUID feature defines to the INHERITED flags (block-scoped
        # normal variable, picked up by DA's add_subdirectory and reverted after
        # the block). Must NOT be a FORCE cache write: that would clobber the
        # global CMAKE_CXX_FLAGS default (/EHsc etc.) for every other component
        # and break C++ exception handling (e.g. AOCL-Utils' Logger).
        set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${_da_cxx_flags}")
        set(BUILD_ILP64     ${ENABLE_ILP64}    CACHE BOOL   "" FORCE)
        set(BUILD_SMP       "${_da_smp}"       CACHE STRING "" FORCE)
        set(BUILD_FORTRAN   ON                 CACHE BOOL   "" FORCE)
        set(ARCH            "${DA_ISA_CONFIG}" CACHE STRING "" FORCE)
        set(BUILD_EXAMPLES  OFF                CACHE BOOL   "" FORCE)
        set(BUILD_GTEST     OFF                CACHE BOOL   "" FORCE)
        set(BUILD_PYTHON    OFF                CACHE BOOL   "" FORCE)
        set(BUILD_DOC       OFF                CACHE BOOL   "" FORCE)
        set(COVERAGE        OFF                CACHE BOOL   "" FORCE)
        set(USE_LIBMEM      OFF                CACHE BOOL   "" FORCE)
        if(OpenMP_libomp_LIBRARY)
            set(OpenMP_libomp_LIBRARY "${OpenMP_libomp_LIBRARY}" CACHE STRING "" FORCE)
        endif()

        aocl_tb_declare_source(aocl_da DA aocl-data-analytics)
        FetchContent_MakeAvailable(aocl_da)

        set(AOCL_TB_DA_SRC "${aocl_da_SOURCE_DIR}" CACHE INTERNAL "")
        set(AOCL_TB_DA_BIN "${aocl_da_BINARY_DIR}" CACHE INTERNAL "")
    endblock()

    set(_da_tgt aocl-da)

    # DA's C++ sources include the BLAS CBLAS interface (da_cblas.hh -> cblas.h)
    # and the flattened BLIS header, both generated by AOCL-BLAS at build time.
    # DA compiles through many internal per-ISA OBJECT libraries (generic_OBJECTS,
    # znver4_OBJECTS, ...); without an explicit dependency they race the header
    # generation under the Unix Makefiles generator ("'cblas.h' file not found").
    # Force every compiled target in DA's subtree to wait for the headers.
    aocl_tb_force_target_deps_recursive("${AOCL_TB_DA_SRC}"
        flat-header flat-cblas-header)

    aocl_tb_add_whole_lib(${_da_tgt})

    aocl_tb_install_component(aocl-data-analytics
        TARGETS     ${_da_tgt}
        HEADER_DIRS "${AOCL_TB_DA_SRC}/source/include")

    aocl_tb_emit_shared(da aocl-data-analytics
        OUTPUT_NAME aocl-da
        STATICS     ${_da_tgt}
        SO_DEPS     aoclso_sparse aoclso_lapack aoclso_blas aoclso_utils
        EXTERNAL    ${_da_external_libs})

    if(ENABLE_ILP64)
        set(_da_iface "ilp64")
    else()
        set(_da_iface "lp64")
    endif()
    aocl_tb_register_manifest(da aocl-data-analytics
        "interface=${_da_iface}"
        "smp=${_da_smp}")
endif()
