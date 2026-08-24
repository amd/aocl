# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
#
# Centralized AOCL build-options layer (Phase 1).
# ---------------------------------------------------------------------------
# Two tiers:
#   * GLOBAL single-select knobs that must be consistent across every component
#     (linkage, threading runtime, integer size, architecture). These are
#     validated as single-valued enums -- e.g. exactly ONE threading runtime,
#     so openmp/iomp/gomp/pthread can never be mixed.
#   * PER-COMPONENT overrides that may legitimately differ between components
#     (threading MT/ST, DTL logging), resolved against the global defaults.
#
# To stay 100% backward compatible with the existing presets (which only set
# the legacy ENABLE_*/BUILD_SHARED_LIBS/AMD_CONFIG cache variables), every new
# option defaults to "auto"/"inherit": when left at the default we DERIVE from
# the legacy variables and touch nothing; when set explicitly we DRIVE the
# legacy variables. This module is included early by the root CMakeLists, after
# the legacy option() block and before those variables are consumed.
# ---------------------------------------------------------------------------

if(DEFINED _AOCL_OPTIONS_INCLUDED)
    return()
endif()
set(_AOCL_OPTIONS_INCLUDED ON)

# Canonical component list (matches the ENABLE_AOCL_<C> switches / wrappers).
set(AOCL_COMPONENTS
    UTILS BLAS LAPACK SPARSE DA CRYPTO LIBM COMPRESSION LIBMEM OPENRNG FFTZ DLP
    CACHE INTERNAL "AOCL component identifiers")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# FATAL if the value of ${var_name} is not one of the allowed tokens.
function(_aocl_validate_enum var_name)
    set(_allowed ${ARGN})
    set(_val "${${var_name}}")
    if(NOT _val IN_LIST _allowed)
        message(FATAL_ERROR
            "[aocl-options] Invalid value '${_val}' for ${var_name}. "
            "Allowed: ${_allowed}")
    endif()
endfunction()

# ---------------------------------------------------------------------------
# GLOBAL options (single-select enums)
# ---------------------------------------------------------------------------
set(AOCL_LINKAGE "auto" CACHE STRING "Library linkage for the build: auto|shared|static")
set_property(CACHE AOCL_LINKAGE PROPERTY STRINGS auto shared static)

set(AOCL_MT_RUNTIME "auto" CACHE STRING
    "Threading runtime (exactly one): auto|serial|pthread|openmp|gomp|libomp|iomp")
set_property(CACHE AOCL_MT_RUNTIME PROPERTY STRINGS auto serial pthread openmp gomp libomp iomp)

set(AOCL_INT_SIZE "auto" CACHE STRING "Integer size: auto|lp64|ilp64")
set_property(CACHE AOCL_INT_SIZE PROPERTY STRINGS auto lp64 ilp64)

set(AOCL_ARCH "auto" CACHE STRING "Target architecture: auto|zen2|zen3|zen4|zen5|amdzen|native")
set_property(CACHE AOCL_ARCH PROPERTY STRINGS auto zen2 zen3 zen4 zen5 amdzen native)

set(AOCL_DTL "off" CACHE STRING "Global DTL (debug/trace logging) default: off|on")
set_property(CACHE AOCL_DTL PROPERTY STRINGS off on)

_aocl_validate_enum(AOCL_LINKAGE    auto shared static)
_aocl_validate_enum(AOCL_MT_RUNTIME auto serial pthread openmp gomp libomp iomp)
_aocl_validate_enum(AOCL_INT_SIZE   auto lp64 ilp64)
_aocl_validate_enum(AOCL_ARCH       auto zen2 zen3 zen4 zen5 amdzen native)
_aocl_validate_enum(AOCL_DTL        off on)

# ---------------------------------------------------------------------------
# Bridge: explicit new option DRIVES the legacy variable; "auto" leaves the
# legacy variable untouched (so existing presets are unaffected).
# Runs before BUILD_STATIC_LIBS / ENABLE_ILP64 / AMD_CONFIG are consumed.
# ---------------------------------------------------------------------------
# Linkage -> BUILD_SHARED_LIBS
if(NOT AOCL_LINKAGE STREQUAL "auto")
    if(AOCL_LINKAGE STREQUAL "shared")
        set(BUILD_SHARED_LIBS ON  CACHE BOOL "Build using shared libraries" FORCE)
    else()
        set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build using shared libraries" FORCE)
    endif()
endif()

# Integer size -> ENABLE_ILP64
if(NOT AOCL_INT_SIZE STREQUAL "auto")
    if(AOCL_INT_SIZE STREQUAL "ilp64")
        set(ENABLE_ILP64 ON  CACHE BOOL "Check if we need to enable ILP64" FORCE)
    else()
        set(ENABLE_ILP64 OFF CACHE BOOL "Check if we need to enable ILP64" FORCE)
    endif()
endif()

# Threading runtime -> ENABLE_MULTITHREADING (the specific runtime library
# selection is wired in Phase 2; here serial=>OFF, anything else=>ON, which
# matches today's single ENABLE_MULTITHREADING behaviour).
if(NOT AOCL_MT_RUNTIME STREQUAL "auto")
    if(AOCL_MT_RUNTIME STREQUAL "serial")
        set(ENABLE_MULTITHREADING OFF CACHE BOOL "Check if we need to enable multithreading" FORCE)
    else()
        set(ENABLE_MULTITHREADING ON  CACHE BOOL "Check if we need to enable multithreading" FORCE)
    endif()
endif()

# Architecture -> AMD_CONFIG (set with FORCE before the root's non-FORCE
# default at line ~130, so this value wins; "native" => empty => auto-detect).
if(NOT AOCL_ARCH STREQUAL "auto")
    if(AOCL_ARCH STREQUAL "native")
        set(AMD_CONFIG "" CACHE STRING "AMD ISA target" FORCE)
    else()
        set(AMD_CONFIG "${AOCL_ARCH}" CACHE STRING "AMD ISA target" FORCE)
    endif()
endif()

# ---------------------------------------------------------------------------
# Effective resolved global values (normal/internal vars used by resolvers,
# validation and the summary). Cached as INTERNAL so they are visible to the
# component wrapper scopes that call the resolver functions.
# ---------------------------------------------------------------------------
if(AOCL_LINKAGE STREQUAL "auto")
    if(BUILD_SHARED_LIBS)
        set(_eff_link "shared")
    else()
        set(_eff_link "static")
    endif()
else()
    set(_eff_link "${AOCL_LINKAGE}")
endif()
set(AOCL_LINKAGE_EFFECTIVE "${_eff_link}" CACHE INTERNAL "resolved AOCL linkage")

if(AOCL_MT_RUNTIME STREQUAL "auto")
    if(ENABLE_MULTITHREADING)
        set(_eff_mt "openmp")   # legacy MT == OpenMP (compiler default runtime)
    else()
        set(_eff_mt "serial")
    endif()
else()
    set(_eff_mt "${AOCL_MT_RUNTIME}")
endif()
set(AOCL_MT_RUNTIME_EFFECTIVE "${_eff_mt}" CACHE INTERNAL "resolved AOCL threading runtime")
if(_eff_mt STREQUAL "serial")
    set(AOCL_MT_GLOBAL OFF CACHE INTERNAL "global multithreading enabled")
else()
    set(AOCL_MT_GLOBAL ON  CACHE INTERNAL "global multithreading enabled")
endif()

if(AOCL_INT_SIZE STREQUAL "auto")
    if(ENABLE_ILP64)
        set(_eff_int "ilp64")
    else()
        set(_eff_int "lp64")
    endif()
else()
    set(_eff_int "${AOCL_INT_SIZE}")
endif()
set(AOCL_INT_SIZE_EFFECTIVE "${_eff_int}" CACHE INTERNAL "resolved AOCL integer size")

# NOTE: the root declares AMD_CONFIG AFTER this early include, so guard for the
# undefined/empty case (empty == auto-detect/amdzen default).
if(NOT AOCL_ARCH STREQUAL "auto")
    set(_eff_arch "${AOCL_ARCH}")
elseif(DEFINED AMD_CONFIG AND NOT "${AMD_CONFIG}" STREQUAL "")
    set(_eff_arch "${AMD_CONFIG}")
else()
    set(_eff_arch "amdzen")
endif()
set(AOCL_ARCH_EFFECTIVE "${_eff_arch}" CACHE INTERNAL "resolved AOCL architecture")

# ---------------------------------------------------------------------------
# PER-COMPONENT overrides (default "inherit") + validation
# ---------------------------------------------------------------------------
foreach(_C IN LISTS AOCL_COMPONENTS)
    set(AOCL_${_C}_THREADING "inherit" CACHE STRING
        "Threading for ${_C}: inherit|mt|st (mt uses the global AOCL_MT_RUNTIME)")
    set_property(CACHE AOCL_${_C}_THREADING PROPERTY STRINGS inherit mt st)

    set(AOCL_${_C}_DTL "inherit" CACHE STRING
        "DTL logging for ${_C}: inherit|on|off")
    set_property(CACHE AOCL_${_C}_DTL PROPERTY STRINGS inherit on off)

    _aocl_validate_enum(AOCL_${_C}_THREADING inherit mt st)
    _aocl_validate_enum(AOCL_${_C}_DTL       inherit on off)

    # A component cannot be MT when there is no global threading runtime.
    if(AOCL_${_C}_THREADING STREQUAL "mt" AND NOT AOCL_MT_GLOBAL)
        message(FATAL_ERROR
            "[aocl-options] AOCL_${_C}_THREADING=mt requires a multithreaded "
            "global runtime, but AOCL_MT_RUNTIME resolves to 'serial'. "
            "Set AOCL_MT_RUNTIME (or ENABLE_MULTITHREADING=ON) first.")
    endif()
endforeach()

# ---------------------------------------------------------------------------
# Resolver functions (consumed by the component wrappers in Phase 2)
# ---------------------------------------------------------------------------
# Effective threading for a component -> "mt" or "st".
function(aocl_opt_threading COMP outvar)
    string(TOUPPER "${COMP}" _c)
    set(_v "${AOCL_${_c}_THREADING}")
    if(_v STREQUAL "inherit")
        if(AOCL_MT_GLOBAL)
            set(_r "mt")
        else()
            set(_r "st")
        endif()
    else()
        set(_r "${_v}")
    endif()
    set(${outvar} "${_r}" PARENT_SCOPE)
endfunction()

# Effective DTL for a component -> "on" or "off".
function(aocl_opt_dtl COMP outvar)
    string(TOUPPER "${COMP}" _c)
    set(_v "${AOCL_${_c}_DTL}")
    if(_v STREQUAL "inherit")
        set(_r "${AOCL_DTL}")
    else()
        set(_r "${_v}")
    endif()
    set(${outvar} "${_r}" PARENT_SCOPE)
endfunction()

# Convenience: resolve a component's threading + DTL into ON/OFF booleans in the
# CALLER's scope (macro, so no PARENT_SCOPE needed). After calling
# aocl_resolve_component(BLAS) the caller can read:
#   AOCL_BLAS_THREADS_ON  -> ON when the component should build multithreaded
#   AOCL_BLAS_DTL_ON      -> ON when DTL logging should be enabled
# For a component left at "inherit" these mirror the global resolved values, so
# the legacy behaviour is preserved exactly.
macro(aocl_resolve_component COMP)
    string(TOUPPER "${COMP}" _AOCL_RC)
    aocl_opt_threading(${_AOCL_RC} _AOCL_RC_THR)
    aocl_opt_dtl(${_AOCL_RC} _AOCL_RC_DTL)
    if(_AOCL_RC_THR STREQUAL "mt")
        set(AOCL_${_AOCL_RC}_THREADS_ON ON)
    else()
        set(AOCL_${_AOCL_RC}_THREADS_ON OFF)
    endif()
    if(_AOCL_RC_DTL STREQUAL "on")
        set(AOCL_${_AOCL_RC}_DTL_ON ON)
    else()
        set(AOCL_${_AOCL_RC}_DTL_ON OFF)
    endif()
    message(STATUS "[aocl-options] ${_AOCL_RC}: threads=${AOCL_${_AOCL_RC}_THREADS_ON} dtl=${AOCL_${_AOCL_RC}_DTL_ON}")
endmacro()

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
message(STATUS "---------------------------------------------------------------")
message(STATUS "[aocl-options] linkage=${AOCL_LINKAGE_EFFECTIVE}  "
               "threading=${AOCL_MT_RUNTIME_EFFECTIVE}  "
               "int=${AOCL_INT_SIZE_EFFECTIVE}  arch=${AOCL_ARCH_EFFECTIVE}")
foreach(_C IN LISTS AOCL_COMPONENTS)
    if(NOT AOCL_${_C}_THREADING STREQUAL "inherit" OR NOT AOCL_${_C}_DTL STREQUAL "inherit")
        message(STATUS "[aocl-options]   override ${_C}: "
                       "threading=${AOCL_${_C}_THREADING} dtl=${AOCL_${_C}_DTL}")
    endif()
endforeach()
message(STATUS "---------------------------------------------------------------")
