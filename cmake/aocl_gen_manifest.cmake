# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
#
# Build-time generator for the unified libaocl manifest. Run via `cmake -P` AFTER
# all component ExternalProjects have installed, so it can harvest each
# component's *version* from its install tree (pkg-config Version, else SONAME)
# and emit the per-library configure options recorded at configure time in
# ${MANIFEST_DIR}/<key>.cfg.
#
# Emits both an embeddable C source (OUT_C) and a plain-text sidecar (OUT_TXT).
#
# Expected -D inputs: PROJECT_NAME OUT_C OUT_TXT MANIFEST_DIR COMPONENTS (pipe-
# separated keys) LINKAGE INTSIZE THREADING ARCH SYMPREFIX BUILDTYPE COMPILER.

# Map an internal component KEY to a human-readable name.
function(_aocl_label KEY OUT)
    if(KEY STREQUAL "utils")
        set(${OUT} "AOCL-Utils" PARENT_SCOPE)
    elseif(KEY STREQUAL "blas")
        set(${OUT} "AOCL-BLAS (BLIS)" PARENT_SCOPE)
    elseif(KEY STREQUAL "lapack")
        set(${OUT} "AOCL-LAPACK (libFLAME)" PARENT_SCOPE)
    elseif(KEY STREQUAL "sparse")
        set(${OUT} "AOCL-Sparse" PARENT_SCOPE)
    elseif(KEY STREQUAL "da")
        set(${OUT} "AOCL-DA (Data Analytics)" PARENT_SCOPE)
    elseif(KEY STREQUAL "libm")
        set(${OUT} "AOCL-LibM" PARENT_SCOPE)
    elseif(KEY STREQUAL "libmem")
        set(${OUT} "AOCL-LibMem" PARENT_SCOPE)
    elseif(KEY STREQUAL "compression")
        set(${OUT} "AOCL-Compression" PARENT_SCOPE)
    elseif(KEY STREQUAL "crypto")
        set(${OUT} "AOCL-Crypto (ALCP)" PARENT_SCOPE)
    elseif(KEY STREQUAL "openrng")
        set(${OUT} "AOCL-OpenRNG" PARENT_SCOPE)
    elseif(KEY STREQUAL "fftz")
        set(${OUT} "AOCL-FFTZ" PARENT_SCOPE)
    elseif(KEY STREQUAL "dlp")
        set(${OUT} "AOCL-DLP" PARENT_SCOPE)
    else()
        set(${OUT} "${KEY}" PARENT_SCOPE)
    endif()
endfunction()

# Harvest a component version from its install tree: prefer the pkg-config
# "Version:" field, fall back to a versioned SONAME (lib*.so.X.Y.Z).
function(_aocl_version INSTALL_DIR OUT)
    set(_ver "unknown")
    if(INSTALL_DIR AND EXISTS "${INSTALL_DIR}")
        file(GLOB_RECURSE _pcs "${INSTALL_DIR}/*.pc")
        foreach(_pc IN LISTS _pcs)
            file(STRINGS "${_pc}" _vlines REGEX "^[Vv]ersion:")
            foreach(_vl IN LISTS _vlines)
                if(_vl MATCHES "([0-9]+\\.[0-9]+(\\.[0-9]+)?)")
                    set(_ver "${CMAKE_MATCH_1}")
                    break()
                endif()
            endforeach()
            if(NOT _ver STREQUAL "unknown")
                break()
            endif()
        endforeach()
        if(_ver STREQUAL "unknown")
            file(GLOB_RECURSE _sos "${INSTALL_DIR}/*.so.*")
            foreach(_so IN LISTS _sos)
                get_filename_component(_n "${_so}" NAME)
                if(_n MATCHES "\\.so\\.([0-9]+\\.[0-9]+\\.[0-9]+)")
                    set(_ver "${CMAKE_MATCH_1}")
                    break()
                endif()
            endforeach()
        endif()
    endif()
    set(${OUT} "${_ver}" PARENT_SCOPE)
endfunction()

# Fallback: harvest the version string directly from a component's source tree.
# Some components ship no pkg-config/SONAME version, but every component records
# its release version somewhere in its sources; the per-key (file, regex) below
# captures it. Returns "unknown" if not found.
function(_aocl_version_from_source KEY SRC OUT)
    set(_v "unknown")
    # Some components express their version as three separate CMake set() lines
    # (MAJOR / MINOR / PATCH); compose those here.
    if(KEY STREQUAL "sparse")
        set(_f "${SRC}/CMakeLists.txt")
        if(EXISTS "${_f}")
            file(READ "${_f}" _t)
            if(_t MATCHES "AOCLSPARSE_VERSION_MAJOR[ \t]+([0-9]+)"
               AND _t MATCHES "AOCLSPARSE_VERSION_MINOR[ \t]+([0-9]+)")
                string(REGEX MATCH "AOCLSPARSE_VERSION_MAJOR[ \t]+([0-9]+)" _ "${_t}")
                set(_maj "${CMAKE_MATCH_1}")
                string(REGEX MATCH "AOCLSPARSE_VERSION_MINOR[ \t]+([0-9]+)" _ "${_t}")
                set(_min "${CMAKE_MATCH_1}")
                string(REGEX MATCH "AOCLSPARSE_VERSION_PATCH[ \t]+([0-9]+)" _ "${_t}")
                set(_pat "${CMAKE_MATCH_1}")
                set(_v "${_maj}.${_min}.${_pat}")
            endif()
        endif()
        set(${OUT} "${_v}" PARENT_SCOPE)
        return()
    elseif(KEY STREQUAL "openrng")
        set(_f "${SRC}/CMakeLists.txt")
        if(EXISTS "${_f}")
            file(READ "${_f}" _t)
            if(_t MATCHES "AOCL_OPENRNG_MAJOR[ \t]+\"?([0-9]+)")
                string(REGEX MATCH "AOCL_OPENRNG_MAJOR[ \t]+\"?([0-9]+)" _ "${_t}")
                set(_maj "${CMAKE_MATCH_1}")
                string(REGEX MATCH "AOCL_OPENRNG_MINOR[ \t]+\"?([0-9]+)" _ "${_t}")
                set(_min "${CMAKE_MATCH_1}")
                string(REGEX MATCH "AOCL_OPENRNG_PATCH[ \t]+\"?([0-9]+)" _ "${_t}")
                set(_pat "${CMAKE_MATCH_1}")
                set(_v "${_maj}.${_min}.${_pat}")
            endif()
        endif()
        set(${OUT} "${_v}" PARENT_SCOPE)
        return()
    elseif(KEY STREQUAL "lapack")
        # libFLAME records its release in the so_version file (one number per
        # line, e.g. "5" then "3.1" => 5.3.1). Compose those into a dotted version.
        set(_f "${SRC}/so_version")
        if(EXISTS "${_f}")
            file(STRINGS "${_f}" _sv REGEX "[0-9]")
            if(_sv)
                string(JOIN "." _v ${_sv})
            endif()
        endif()
        set(${OUT} "${_v}" PARENT_SCOPE)
        return()
    endif()
    set(_file "")
    set(_rx "")
    if(KEY STREQUAL "compression")
        set(_file "${SRC}/api/aocl_compression.h")
        set(_rx "AOCL_COMPRESSION_LIBRARY_VERSION[^0-9]*([0-9]+\\.[0-9]+(\\.[0-9]+)?)")
    elseif(KEY STREQUAL "libm")
        set(_file "${SRC}/src/alm_version.h")
        set(_rx "ALM_VERSION_STRING[^0-9]*([0-9]+\\.[0-9]+(\\.[0-9]+)?)")
    elseif(KEY STREQUAL "da")
        set(_file "${SRC}/CMakeLists.txt")
        set(_rx "AOCL-DA[ \t]+VERSION[ \t]+([0-9]+\\.[0-9]+(\\.[0-9]+)?)")
    elseif(KEY STREQUAL "crypto")
        set(_file "${SRC}/CMakeLists.txt")
        set(_rx "AOCL_RELEASE_VERSION[^0-9]*([0-9]+\\.[0-9]+(\\.[0-9]+)?)")
    elseif(KEY STREQUAL "fftz")
        set(_file "${SRC}/CMakeLists.txt")
        set(_rx "FFTZ_VERSION[^0-9]*([0-9]+\\.[0-9]+(\\.[0-9]+)?)")
    elseif(KEY STREQUAL "libmem")
        set(_file "${SRC}/CMakeLists.txt")
        set(_rx "LIBMEM_VERSION_STRING[^0-9]*([0-9]+\\.[0-9]+(\\.[0-9]+)?)")
    elseif(KEY STREQUAL "dlp")
        set(_file "${SRC}/cmake/dlp_variables.cmake")
        set(_rx "PROJECT_VERSION[ \t]+\"([0-9]+\\.[0-9]+(\\.[0-9]+)?)\"")
    elseif(KEY STREQUAL "blas")
        set(_file "${SRC}/version")
        set(_rx "([0-9]+\\.[0-9]+(\\.[0-9]+)?)")
    elseif(KEY STREQUAL "utils")
        set(_file "${SRC}/version.txt")
        set(_rx "([0-9]+\\.[0-9]+(\\.[0-9]+)?)")
    endif()
    if(_file AND EXISTS "${_file}")
        file(READ "${_file}" _txt)
        if(_txt MATCHES "${_rx}")
            set(_v "${CMAKE_MATCH_1}")
        endif()
    endif()
    set(${OUT} "${_v}" PARENT_SCOPE)
endfunction()

string(REPLACE "|" ";" _components "${COMPONENTS}")
string(TIMESTAMP _date "%Y-%m-%d %H:%M:%S UTC" UTC)
if(NOT SYMPREFIX)
    set(SYMPREFIX "(none)")
endif()

# Assemble the manifest body, one line per list element.
set(_lines "")
list(APPEND _lines "AOCL-MANIFEST-BEGIN")
# LIBNAME is the platform-correct library base name (libaocl on ELF, aocl on
# Windows). Fall back to the historical lib-prefixed form if not supplied.
if(NOT LIBNAME)
    set(LIBNAME "lib${PROJECT_NAME}")
endif()
list(APPEND _lines "library: ${LIBNAME}")
list(APPEND _lines "build_date: ${_date}")
list(APPEND _lines "linkage: ${LINKAGE}")
list(APPEND _lines "integer_size: ${INTSIZE}")
list(APPEND _lines "threading: ${THREADING}")
list(APPEND _lines "threading_library: ${THREADLIB}")
list(APPEND _lines "architecture: ${ARCH}")
# Only surface symbol_prefix when symbol renaming was actually applied.
if(SYMPREFIX AND NOT SYMPREFIX STREQUAL "(none)")
    list(APPEND _lines "symbol_prefix: ${SYMPREFIX}")
endif()
list(APPEND _lines "build_type: ${BUILDTYPE}")
list(APPEND _lines "compiler: ${COMPILER}")
list(LENGTH _components _ncomp)
list(APPEND _lines "component_count: ${_ncomp}")
list(APPEND _lines "components:")

foreach(_k IN LISTS _components)
    _aocl_label("${_k}" _label)
    set(_install "")
    set(_source "")
    set(_cfg "${MANIFEST_DIR}/${_k}.cfg")
    if(EXISTS "${_cfg}")
        file(STRINGS "${_cfg}" _flines REGEX "^(install|source)=")
        foreach(_fl IN LISTS _flines)
            if(_fl MATCHES "^install=(.*)")
                set(_install "${CMAKE_MATCH_1}")
            elseif(_fl MATCHES "^source=(.*)")
                set(_source "${CMAKE_MATCH_1}")
            endif()
        endforeach()
    endif()
    _aocl_version("${_install}" _ver)
    # libFLAME's authoritative release lives in its so_version file; prefer that
    # source value for lapack even when the install tree exposes a SONAME version.
    if(_k STREQUAL "lapack")
        _aocl_version_from_source("lapack" "${_source}" _lv)
        if(NOT _lv STREQUAL "unknown")
            set(_ver "${_lv}")
        endif()
    elseif(_ver STREQUAL "unknown")
        _aocl_version_from_source("${_k}" "${_source}" _ver)
    endif()
    list(APPEND _lines "  - name: ${_label}")
    list(APPEND _lines "    version: ${_ver}")
endforeach()
list(APPEND _lines "AOCL-MANIFEST-END")

# --- plain-text sidecar ---------------------------------------------------
string(REPLACE ";" "\n" _txt "${_lines}")
file(WRITE "${OUT_TXT}" "${_txt}\n")

# --- embeddable C source --------------------------------------------------
set(_cbody "")
foreach(_l IN LISTS _lines)
    string(REPLACE "\\" "\\\\" _l "${_l}")
    string(REPLACE "\"" "\\\"" _l "${_l}")
    string(APPEND _cbody "    \"${_l}\\n\"\n")
endforeach()
file(WRITE "${OUT_C}"
"/* Auto-generated by aocl_gen_manifest.cmake -- do not edit.
 *
 * Self-describing manifest for the unified ${PROJECT_NAME} library. Inspect via:
 *     readelf -p .aocl_manifest lib${PROJECT_NAME}.so
 *     strings lib${PROJECT_NAME}.so | grep -A60 AOCL-MANIFEST-BEGIN
 * or at runtime through aocl_get_manifest().
 */
#if defined(__GNUC__) || defined(__clang__)
#  define AOCL_MANIFEST_ATTR __attribute__((used, section(\".aocl_manifest\")))
#else
#  define AOCL_MANIFEST_ATTR
#endif

AOCL_MANIFEST_ATTR
const char aocl_manifest[] =
${_cbody}    ;

const char *aocl_get_manifest(void)
{
    return aocl_manifest;
}
")
