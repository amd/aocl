# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
#
# rename_symbols.cmake — CMake-native symbol renaming script
#
# Replaces rename_symbols.py: extracts symbols with llvm-nm / dumpbin,
# builds a case-aware redefine-syms map, renames via llvm-objcopy, and
# (on shared-lib builds) re-links the DLL with lld-link / link.exe.
# Headers are copied to renamed/include and symbols are patched in-place
# using CMake's file(READ/WRITE) + string(REGEX REPLACE).
#
# Invoked with:
#   cmake -DINSTALL_PATH=<path>
#         -DPREFIX=<prefix>
#         [-DCREATE_SO=ON]
#         [-DSO_LIBS="lib1;lib2"]          (Linux only)
#         [-DCOMPILER=<path>]              (Linux only)
#         [-DLINKER_FLAGS="flags"]         (Linux only)
#         [-DFORTRAN_LIB_DIR=<dir>]  (Windows optional)
#         [-DOPENSSL_CRYPTO_LIB=<path>]    (Windows optional)
#         [-DLLVM_BIN_DIR=<dir>]           (optional override)
#         -P rename_symbols.cmake
#
# All heavy logic lives in this single file so that it is fully self-contained
# and does NOT need Python or any external interpreter at run-time.

cmake_minimum_required(VERSION 3.18)

# ---------------------------------------------------------------------------
# 0. Validate required arguments
# ---------------------------------------------------------------------------
if(NOT DEFINED INSTALL_PATH OR INSTALL_PATH STREQUAL "")
    message(FATAL_ERROR "rename_symbols.cmake: INSTALL_PATH is required")
endif()
if(NOT DEFINED PREFIX OR PREFIX STREQUAL "")
    message(FATAL_ERROR "rename_symbols.cmake: PREFIX is required")
endif()
if(NOT DEFINED CREATE_SO)
    set(CREATE_SO OFF)
endif()
# Unified-library base name. The parent passes -DLIBNAME=${AOCL_SINGLE_LIBRARY_NAME}
# so the umbrella library files this script hoists / keeps / renames match the
# name the unified build produced (aocl{.dll,.lib,_static.lib}, libaocl.{so,a} by
# default, or any custom name). Falls back to "aocl" for standalone invocations.
if(NOT DEFINED LIBNAME OR LIBNAME STREQUAL "")
    set(LIBNAME "aocl")
endif()

# Normalise path separators
file(TO_CMAKE_PATH "${INSTALL_PATH}" INSTALL_PATH)

if(NOT EXISTS "${INSTALL_PATH}")
    message(FATAL_ERROR "Installation path does not exist: ${INSTALL_PATH}")
endif()
if(NOT EXISTS "${INSTALL_PATH}/lib")
    message(FATAL_ERROR "lib directory not found under: ${INSTALL_PATH}")
endif()
if(NOT EXISTS "${INSTALL_PATH}/include")
    message(FATAL_ERROR "include directory not found under: ${INSTALL_PATH}")
endif()

# ---------------------------------------------------------------------------
# 1. Detect platform and locate required tools
# ---------------------------------------------------------------------------
if(CMAKE_HOST_WIN32)
    set(_PLATFORM "Windows")
else()
    set(_PLATFORM "Linux")
endif()

# Candidate search order for LLVM tools
set(_LLVM_SEARCH_DIRS "")
if(DEFINED LLVM_BIN_DIR AND NOT LLVM_BIN_DIR STREQUAL "")
    list(APPEND _LLVM_SEARCH_DIRS "${LLVM_BIN_DIR}")
endif()
if(_PLATFORM STREQUAL "Windows")
    list(APPEND _LLVM_SEARCH_DIRS
        "C:/Program Files/LLVM/bin"
        "C:/Program Files (x86)/LLVM/bin"
    )
else()
    list(APPEND _LLVM_SEARCH_DIRS
        "/usr/bin"
        "/usr/local/bin"
        "/usr/lib/llvm-14/bin"
        "/usr/lib/llvm-15/bin"
        "/usr/lib/llvm-16/bin"
        "/usr/lib/llvm-17/bin"
    )
endif()

macro(_find_tool VAR_NAME)
    set(_NAMES ${ARGN})
    set(${VAR_NAME} "${VAR_NAME}-NOTFOUND")
    foreach(_dir ${_LLVM_SEARCH_DIRS})
        foreach(_name ${_NAMES})
            if(EXISTS "${_dir}/${_name}")
                set(${VAR_NAME} "${_dir}/${_name}")
                break()
            endif()
        endforeach()
        if(NOT ${VAR_NAME} STREQUAL "${VAR_NAME}-NOTFOUND")
            break()
        endif()
    endforeach()
    if(${VAR_NAME} STREQUAL "${VAR_NAME}-NOTFOUND")
        find_program(${VAR_NAME} NAMES ${_NAMES})
    endif()
endmacro()

_find_tool(LLVM_NM_TOOL       llvm-nm       llvm-nm.exe)
_find_tool(LLVM_OBJCOPY_TOOL  llvm-objcopy  llvm-objcopy.exe)

message(STATUS "=== AOCL Symbol Renaming (CMake-native) ===")
message(STATUS "Platform      : ${_PLATFORM}")
message(STATUS "Install path  : ${INSTALL_PATH}")
message(STATUS "Prefix        : ${PREFIX}")
message(STATUS "Create shared : ${CREATE_SO}")

# -- Include the OS-specific module --
# Each module runs its own tool detection on include and defines the
# OS-specific symbol-extraction / export-reading / umbrella-creation functions
# (extract_symbols_*, get_*_exports_*, create_dll_windows /
# create_shared_library_linux). The common driver below owns the orchestration
# and dispatches the regex-heavy map generation + header rewrite to the OS
# engine (rename_engine_windows.ps1 (-Mode map) / embedded pwsh on Windows;
# rename_engine_linux.py --emit-map/--emit-headers on Linux).
if(_PLATFORM STREQUAL "Windows")
    include("${CMAKE_CURRENT_LIST_DIR}/rename_symbols_windows.cmake")
else()
    include("${CMAKE_CURRENT_LIST_DIR}/rename_symbols_linux.cmake")
endif()

# ---------------------------------------------------------------------------
# 2. ABI / compiler-generated symbol exclusion patterns
#    Mirrored from rename_symbols.py ABI_EXCLUDES + _MSVC_ABI_EXCLUDES
# ---------------------------------------------------------------------------

# Each entry is a CMake regex used with string(REGEX MATCH).
# Patterns that differ from Python regex are translated as closely as possible.
set(_ABI_EXCLUDE_REGEXES
    # C++ runtime/exceptions (Itanium)
    "^__gxx_personality_v0$"
    "^__cxa_"
    "^_Unwind_"
    "^__stack_chk_(fail|guard)$"
    "^__tls_get_addr$"
    "^__dso_handle$"
    # libc / pthread
    "^__libc_"
    "^__pthread_"
    # Debug/anonymous/temp
    "^DW\\.ref\\."
    "^\\.(L|local)"
    "^a\\."
    # GOT/PLT
    "^_GLOBAL_OFFSET_TABLE_$"
    # ELF version symbols (Linux only – skipped on Windows below)
    "@@"
    # Init/fini
    "^_init$"
    "^_fini$"
    "^__gmon_start__$"
)

set(_MSVC_ABI_EXCLUDE_REGEXES
    "^\\?\\?_R"
    "^\\?\\?_7"
    "^\\?\\?_8"
    "^\\?\\?_9"
    "^\\?\\?_C@"
    "^\\?\\?2@"
    "^\\?\\?3@"
    "^\\?\\?_E"
    "^\\?\\?_G"
    "^__real@"
    "^__xmm@"
    "^__ymm@"
    "^__imp_"
    "^_CRT_"
    "^__security_"
    "^__GSHandler"
    "^__std_"
)

# ---------------------------------------------------------------------------
# Standard C/POSIX/math library symbols that must NEVER be renamed.
# Mirrors STDLIB_SYMBOL_EXCLUDES in rename_symbols.py and $stdlibExcludeSet in
# rename_engine_windows.ps1 (-Mode map). BLIS emits these as weak/COMDAT defined symbols
# from BLIS_INLINE functions (e.g. bli_round->round(), sup paths->printf()); if
# they enter the rename map they get prefixed in both the binary and the header
# text rewrite, producing undeclared myprefix_round/myprefix_printf in renamed headers.
# ---------------------------------------------------------------------------
set(_STDLIB_EXCLUDE_SYMS
    # <math.h>
    abs labs llabs div ldiv lldiv
    fabs fabsf fabsl fmin fminf fminl fmax fmaxf fmaxl
    sqrt sqrtf sqrtl cbrt cbrtf cbrtl hypot hypotf hypotl
    pow powf powl exp expf expl exp2 exp2f expm1 expm1f
    log logf logl log2 log2f log10 log10f log1p log1pf
    sin sinf sinl cos cosf cosl tan tanf tanl
    asin asinf acos acosf atan atanf atan2 atan2f
    sinh sinhf cosh coshf tanh tanhf
    asinh acosh atanh erf erff erfc erfcf tgamma lgamma
    floor floorf floorl ceil ceilf ceill
    round roundf roundl lround lroundf llround llroundf
    rint rintf lrint llrint nearbyint nearbyintf
    trunc truncf truncl fmod fmodf fmodl remainder remainderf
    fma fmaf fmal frexp frexpf ldexp ldexpf modf modff
    scalbn scalbnf scalbln copysign copysignf copysignl
    nextafter nextafterf fdim fdimf signbit
    isnan isinf isfinite isnormal fpclassify
    # <stdio.h>
    printf fprintf sprintf snprintf vprintf vfprintf vsprintf
    vsnprintf scanf fscanf sscanf puts fputs putchar putc
    fputc getchar getc fgetc gets fgets fopen freopen
    fclose fread fwrite fflush fseek ftell rewind fsetpos
    fgetpos setvbuf setbuf perror remove rename tmpfile tmpnam
    # <stdlib.h>
    malloc calloc realloc free aligned_alloc posix_memalign
    atoi atol atoll atof strtol strtoll strtoul strtoull
    strtod strtof qsort bsearch rand srand exit _Exit
    abort atexit getenv system mblen mbtowc wctomb
    # <string.h>
    memcpy memmove memset memcmp memchr strlen strnlen
    strcpy strncpy strcat strncat strcmp strncmp strcoll
    strchr strrchr strstr strspn strcspn strpbrk strtok
    strdup strndup strerror
    # <ctype.h>
    isalnum isalpha isblank iscntrl isdigit isgraph islower
    isprint ispunct isspace isupper isxdigit tolower toupper
)

# ---------------------------------------------------------------------------
# Helper: check whether a symbol should be excluded from renaming
# Sets _SKIP to TRUE or FALSE in parent scope.
# ---------------------------------------------------------------------------
macro(_should_skip_symbol SYM)
    set(_SKIP FALSE)

    # Too short
    string(LENGTH "${SYM}" _sym_len)
    if(_sym_len LESS 2)
        set(_SKIP TRUE)
    endif()

    # Standard C library symbol (exact match) — never rename.
    if(NOT _SKIP)
        if("${SYM}" IN_LIST _STDLIB_EXCLUDE_SYMS)
            set(_SKIP TRUE)
        endif()
    endif()

    if(NOT _SKIP)
        # std:: namespace (plain text check – fast)
        if("${SYM}" MATCHES "std::")
            set(_SKIP TRUE)
        endif()
    endif()

    if(NOT _SKIP)
        # Itanium std:: - _ZSt / _ZNSt / _ZTSSt etc.
        if("${SYM}" MATCHES "^_ZSt" OR "${SYM}" MATCHES "^_ZNSt" OR
           "${SYM}" MATCHES "^_ZTS[Ss]t" OR "${SYM}" MATCHES "^_ZTI[Ss]t" OR
           "${SYM}" MATCHES "^_ZTV[Ss]t" OR "${SYM}" MATCHES "^_ZTT[Ss]t")
            set(_SKIP TRUE)
        endif()
    endif()

    if(NOT _SKIP)
        # Reserved C++ implementation namespaces (libstdc++/libc++/ABI internals:
        # __gnu_cxx, __cxxabiv1, __gnu_debug, ...). The C++ standard reserves
        # leading double-underscore names for the implementation, so an outermost
        # mangled namespace component of __xxx belongs to the STL, not AOCL, and
        # must never be renamed (mirrors is_reserved_impl_mangled_symbol in .py).
        if("${SYM}" MATCHES "^_ZN[a-zA-Z]*[0-9]+__" OR
           "${SYM}" MATCHES "^_Z(TV|TI|TS|TT|TC|GV|GR)N[0-9]+__")
            set(_SKIP TRUE)
        endif()
    endif()

    if(NOT _SKIP)
        # Apply platform-aware ABI exclusion patterns
        foreach(_rx ${_ABI_EXCLUDE_REGEXES})
            # Skip the @@ ELF version check on Windows (MSVC names legitimately contain @@)
            if(_PLATFORM STREQUAL "Windows" AND "${_rx}" STREQUAL "@@")
                continue()
            endif()
            if("${SYM}" MATCHES "${_rx}")
                set(_SKIP TRUE)
                break()
            endif()
        endforeach()
    endif()

    if(NOT _SKIP AND _PLATFORM STREQUAL "Windows")
        # MSVC mangled symbol starts with '?'
        if("${SYM}" MATCHES "^\\?")
            # Check MSVC ABI exclusions
            foreach(_rx ${_MSVC_ABI_EXCLUDE_REGEXES})
                if("${SYM}" MATCHES "${_rx}")
                    set(_SKIP TRUE)
                    break()
                endif()
            endforeach()
            # MSVC std:: outermost-namespace check.
            #
            # The qualified-name part ends at the first '@@' that is followed
            # by an MSVC access/calling-convention code letter. So a symbol
            # whose OUTERMOST namespace is 'std' matches '@std@@<code-letter>'
            # — e.g. ?what@exception@std@@UEBAPEBDXZ (U=public-virtual)
            # or ?foo@bar@std@@YAHXZ (Y=cdecl-free-fn).
            #
            # The previous loose '@std@@' substring match also tripped on
            # symbols where 'std' merely appeared inside a template argument
            # (e.g. ?do_bijection@?A0x...@openrng@@...@std@@@1@@Z), which are
            # NOT in std::. Restrict to the type-code follow-on form so we
            # mirror the Linux Python script (which only skips _ZSt*/_ZNSt*
            # symbols whose qualified name STARTS with std).
            if(NOT _SKIP)
                if("${SYM}" MATCHES "@std@@[A-Z0-9]")
                    set(_SKIP TRUE)
                endif()
            endif()
        endif()
    endif()
endmacro()

# ---------------------------------------------------------------------------
# Helper: compute case-aware prefix for a plain-C symbol
# Sets _RESULT_PREFIX in parent scope.
# ---------------------------------------------------------------------------
macro(_get_intelligent_prefix SYM BASE_PREFIX)
    # Strip trailing underscores for case operations; keep the full run to re-append
    # (so multi-underscore prefixes like `myprefix__` are preserved, matching the C++ rename).
    string(REGEX REPLACE "_+$" "" _clean_prefix "${BASE_PREFIX}")
    string(REGEX MATCH "_+$" _trailing_us "${BASE_PREFIX}")

    # Check for leading underscores
    string(REGEX MATCH "^_+" _leading_us "${SYM}")
    string(LENGTH "${_leading_us}" _leading_count)
    string(SUBSTRING "${SYM}" ${_leading_count} -1 _rest)

    if(NOT _rest STREQUAL "")
        # Detect case of rest: all uppercase?
        string(TOUPPER "${_rest}" _rest_upper)
        string(TOLOWER "${_rest}" _rest_lower)
        if("${_rest}" STREQUAL "${_rest_upper}" AND NOT _rest STREQUAL "")
            # All uppercase
            string(TOUPPER "${_clean_prefix}" _pfx)
        elseif("${_rest}" STREQUAL "${_rest_lower}")
            # All lowercase
            string(TOLOWER "${_clean_prefix}" _pfx)
        else()
            # Mixed case → uppercase prefix
            string(TOUPPER "${_clean_prefix}" _pfx)
        endif()

        set(_RESULT_PREFIX "${_leading_us}${_pfx}${_trailing_us}")
    else()
        set(_RESULT_PREFIX "${BASE_PREFIX}")
    endif()
endmacro()

# ---------------------------------------------------------------------------
# Helper: Rename an Itanium mangled symbol by injecting prefix into first
#         nested-name component (_ZN3alcp... → _ZN8AOCL_alcp...)
# Sets _RENAMED_SYM in parent scope (= original sym if cannot rename)
# ---------------------------------------------------------------------------
macro(_rename_itanium_symbol SYM PREFIX_TOKEN)
    set(_RENAMED_SYM "${SYM}")

    # Normalise prefix token (strip non-identifier chars, keep trailing _)
    string(REGEX REPLACE "[^A-Za-z0-9_]" "" _tok "${PREFIX_TOKEN}")
    if("${_tok}" STREQUAL "")
        # Empty token – nothing to do
    else()
        # Find the nested-name 'N' index
        # Supported forms: _ZN, _ZZN, _ZTVN, _ZTIN, _ZTSN, _ZTTN, _ZTCN, _ZGVN, _ZGRN
        set(_n_idx -1)
        if("${SYM}" MATCHES "^_ZN")
            set(_n_idx 2)
        elseif("${SYM}" MATCHES "^_ZZN")
            set(_n_idx 3)
        else()
            foreach(_pfx _ZTVN _ZTIN _ZTSN _ZTTN _ZTCN _ZGVN _ZGRN)
                if("${SYM}" MATCHES "^${_pfx}")
                    string(LENGTH "${_pfx}" _pfx_len)
                    math(EXPR _n_idx "${_pfx_len} - 1")
                    break()
                endif()
            endforeach()
        endif()

        # Thunk variants: look for _N inside
        if(_n_idx EQUAL -1)
            if("${SYM}" MATCHES "^_ZTh" OR "${SYM}" MATCHES "^_ZTv" OR "${SYM}" MATCHES "^_ZTc")
                # Find position of _N (as substring index)
                string(FIND "${SYM}" "_N" _under_n_pos)
                if(_under_n_pos GREATER -1)
                    math(EXPR _n_idx "${_under_n_pos} + 1")
                endif()
            endif()
        endif()

        # Guard variables: _ZGVZ...N...
        if(_n_idx EQUAL -1 AND "${SYM}" MATCHES "^_ZGVZ")
            # string(FIND) has no start-offset argument, so search the tail
            # after the 5-char "_ZGVZ" prefix and re-add the offset.
            string(SUBSTRING "${SYM}" 5 -1 _sym_guard_tail)
            string(FIND "${_sym_guard_tail}" "N" _n_pos_guard)
            if(_n_pos_guard GREATER -1)
                math(EXPR _n_pos_guard "${_n_pos_guard} + 5")
                set(_n_idx ${_n_pos_guard})
            endif()
        endif()

        if(_n_idx GREATER -1)
            math(EXPR _after_n "${_n_idx} + 1")
            string(LENGTH "${SYM}" _sym_len)

            # Skip CV/ref qualifiers after N
            set(_i ${_after_n})
            set(_continue_loop TRUE)
            while(_continue_loop AND _i LESS _sym_len)
                string(SUBSTRING "${SYM}" ${_i} 1 _ch)
                if("${_ch}" MATCHES "[rVKRO]")
                    math(EXPR _i "${_i} + 1")
                else()
                    set(_continue_loop FALSE)
                endif()
            endwhile()

            # Parse <len><identifier>
            set(_j ${_i})
            set(_digits "")
            set(_continue_loop TRUE)
            while(_continue_loop AND _j LESS _sym_len)
                string(SUBSTRING "${SYM}" ${_j} 1 _ch)
                if("${_ch}" MATCHES "[0-9]")
                    string(APPEND _digits "${_ch}")
                    math(EXPR _j "${_j} + 1")
                else()
                    set(_continue_loop FALSE)
                endif()
            endwhile()

            if(NOT _digits STREQUAL "" AND _j GREATER _i)
                set(_name_len ${_digits})
                set(_start ${_j})
                math(EXPR _end "${_start} + ${_name_len}")

                if(_end LESS_EQUAL _sym_len)
                    string(SUBSTRING "${SYM}" ${_start} ${_name_len} _first_comp)

                    # Avoid double-prefixing
                    if(NOT "${_first_comp}" MATCHES "^${_tok}")
                        set(_new_comp "${_tok}${_first_comp}")
                        string(LENGTH "${_new_comp}" _new_comp_len)

                        # Rebuild: prefix + N + CV-quals + new_len + new_comp + rest
                        string(SUBSTRING "${SYM}" 0 ${_i}   _head)  # everything up to (not incl) digit start
                        string(SUBSTRING "${SYM}" ${_end} -1 _tail)  # everything after first component
                        set(_RENAMED_SYM "${_head}${_new_comp_len}${_new_comp}${_tail}")
                    endif()
                endif()
            endif()
        endif()
    endif()
endmacro()

# ---------------------------------------------------------------------------
# Helper: prefix embedded AOCL type-name components inside an MSVC mangled
#         symbol (Option A). Mirrors Prefix-MsvcTypes in
#         rename_engine_windows.ps1 (-Mode map): a user type segment is <intro><name>@ where
#         intro = W<digit> (enum) | U|V|T (struct/class/union) | @ (nested
#         scope). Only the long, distinctive AOCL tags collected by the
#         PowerShell map generator (written to the 'aocl_type_tags.txt' sidecar
#         next to the map files) are touched, so the cmake fallback path renames
#         the exact same tag set the fast path does. Rewrites the variable named
#         by _SYMVAR in place; no-op when the sidecar is absent.
#
# Loading is lazy + cached in a GLOBAL property so it works in both normal and
# `cmake -P` script mode and is read only once.
# ---------------------------------------------------------------------------
macro(_prefix_msvc_types _SYMVAR _TOK)
    get_property(_aocl_tags_loaded GLOBAL PROPERTY _AOCL_TAGS_LOADED)
    if(NOT _aocl_tags_loaded)
        set(_aocl_tags_tmp "")
        if(DEFINED INSTALL_PATH AND EXISTS "${INSTALL_PATH}/lib/aocl_type_tags.txt")
            file(STRINGS "${INSTALL_PATH}/lib/aocl_type_tags.txt" _aocl_tags_tmp)
        endif()
        set_property(GLOBAL PROPERTY _AOCL_TAGS "${_aocl_tags_tmp}")
        set_property(GLOBAL PROPERTY _AOCL_TAGS_LOADED TRUE)
    endif()
    get_property(_aocl_tags GLOBAL PROPERTY _AOCL_TAGS)
    foreach(_tt IN LISTS _aocl_tags)
        string(FIND "${${_SYMVAR}}" "${_tt}" _ttp)
        if(NOT _ttp EQUAL -1)
            # Capture the intro anchor + trailing '@' and re-emit them so
            # adjacent segments (processed in later tag iterations) keep their
            # anchors intact. Tags are plain identifiers (no regex specials).
            string(REGEX REPLACE
                "(W[0-9]|[UVT@])(${_tt})@"
                "\\1${_TOK}\\2@"
                ${_SYMVAR} "${${_SYMVAR}}")
        endif()
    endforeach()
endmacro()

# ---------------------------------------------------------------------------
# Helper: Rename an MSVC mangled symbol using a SYMMETRIC-WITH-ITANIUM
#         strategy. The Linux script (rename_symbols.py /
#         _replace_first_nested_component) injects the prefix into the
#         OUTERMOST nested-name component, so that, after rename, both
#         platforms produce the same fully-qualified C++ name, e.g.
#         ::AOCL_alcp::utils::CpuId::cpuIsZen3() rather than the previous
#         asymmetric ::alcp::utils::CpuId::AOCL_cpuIsZen3() on Windows.
#
# In MSVC mangling, the @-segment immediately BEFORE the first '@@'
# terminator is the outermost scope (namespace or top-level class). When
# there is no scope at all (free function/operator at global scope), the
# segment immediately after the operator-prefix marker IS the function /
# operator name itself, so we prefix that.
#
# Examples:
#   ?cpuIsZen3@CpuId@utils@alcp@@SA_NXZ
#     -> ?cpuIsZen3@CpuId@utils@AOCL_alcp@@SA_NXZ
#   ??0X86Cpu@Au@@QEAA@I@Z         (constructor of Au::X86Cpu)
#     -> ??0X86Cpu@AOCL_Au@@QEAA@I@Z
#   ?foo@@YAXH@Z                    (free function)
#     -> ?AOCL_foo@@YAXH@Z
#
# Backref preservation: MSVC parameter back-references (`0..9`) refer to
# encoded names by slot index, not by content. Replacing a name in-place
# with a longer prefixed string keeps the slot order intact.
#
# IMPORTANT: This must stay byte-for-byte equivalent to the PowerShell
# `Rename-Msvc` function in rename_engine_windows.ps1 (-Mode map) — both implementations
# feed different consumers (objcopy redefine-syms map vs DLL .def export
# list) and any divergence yields undefined symbols at link time.
#
# Sets _RENAMED_SYM in parent scope (= original SYM if no rename applied).
# ---------------------------------------------------------------------------
macro(_rename_msvc_symbol SYM PREFIX_TOKEN)
    set(_RENAMED_SYM "${SYM}")

    string(REGEX REPLACE "[^A-Za-z0-9_]" "" _tok "${PREFIX_TOKEN}")
    if("${_tok}" STREQUAL "")
        # Nothing to do
    elseif(NOT "${SYM}" MATCHES "^\\?")
        # Not MSVC mangled
    else()
        string(LENGTH "${SYM}" _sym_len)
        if(_sym_len LESS 3)
            # Too short to be a real mangled name
        else()
            # Determine operator-prefix length (chars after leading '?').
            # Order matters: more-specific multi-char prefixes first.
            set(_op_len 0)
            set(_is_tmpl FALSE)
            if("${SYM}" MATCHES "^\\?\\?\\$")
                set(_op_len 3)        # ??$ template instantiation
                set(_is_tmpl TRUE)
            else()
                string(SUBSTRING "${SYM}" 0 2 _first2)
                if(_sym_len GREATER_EQUAL 4)
                    string(SUBSTRING "${SYM}" 0 4 _first4)
                else()
                    set(_first4 "")
                endif()
                if(_sym_len GREATER_EQUAL 4 AND "${_first4}" MATCHES "^\\?\\?_.$")
                    set(_op_len 4)    # ??_X extended special
                elseif("${SYM}" MATCHES "^\\?\\?[0-9A-Z]")
                    set(_op_len 3)    # ??<digit/letter> ctor/dtor/operator
                elseif("${_first2}" STREQUAL "??")
                    # Bare '??' that doesn't match the patterns above -
                    # leave alone to avoid corrupting unknown encodings.
                    set(_op_len 0)
                else()
                    set(_op_len 1)    # ? regular function/data
                endif()
            endif()

            if(_op_len GREATER 0 AND _sym_len GREATER _op_len)
                # Depth-aware scan: '?$' opens nested template-id (depth++), '@@' closes it (depth--);
                # terminator = first '@@' at depth 0. MUST match Rename-Msvc in rename_engine_windows.ps1 (-Mode map).
                set(_depth 0)
                set(_term -1)
                set(_firstAt0 -1)
                set(_lastAt0 -1)
                set(_i ${_op_len})
                while(_i LESS _sym_len)
                    string(SUBSTRING "${SYM}" ${_i} 1 _c)
                    math(EXPR _i1 "${_i} + 1")
                    set(_c2 "")
                    if(_i1 LESS _sym_len)
                        string(SUBSTRING "${SYM}" ${_i1} 1 _c2)
                    endif()
                    if("${_c}" STREQUAL "?" AND "${_c2}" STREQUAL "$")
                        math(EXPR _depth "${_depth} + 1")
                        math(EXPR _i "${_i} + 2")
                        continue()
                    endif()
                    if("${_c}" STREQUAL "@" AND "${_c2}" STREQUAL "@")
                        if(_depth EQUAL 0)
                            set(_term ${_i})
                            break()
                        endif()
                        math(EXPR _depth "${_depth} - 1")
                        math(EXPR _i "${_i} + 2")
                        continue()
                    endif()
                    if("${_c}" STREQUAL "@" AND _depth EQUAL 0)
                        if(_firstAt0 LESS 0)
                            set(_firstAt0 ${_i})
                        endif()
                        set(_lastAt0 ${_i})
                    endif()
                    math(EXPR _i "${_i} + 1")
                endwhile()

                if(_term GREATER_EQUAL 0)
                    if(_firstAt0 LESS 0)
                        # No depth-0 '@' before terminator: free function / data
                        # (no enclosing scope) -> prefix the name itself.
                        set(_inject_at ${_op_len})
                    elseif(_is_tmpl AND _firstAt0 EQUAL _lastAt0)
                        # Global template: the single depth-0 '@' is the
                        # name/args separator and there is NO enclosing scope
                        # (e.g. ??$da_handle_init@M@@...) -> prefix the function
                        # name. A scoped template has a 2nd depth-0 '@'.
                        set(_inject_at ${_op_len})
                    else()
                        # Scoped (namespaced) symbol, template OR not: prefix the
                        # OUTERMOST scope (after the last depth-0 '@'), mirroring
                        # the Linux namespace rename so aoclsparse::trsv<T> ->
                        # av1_aoclsparse::trsv<T> (not aoclsparse::av1_trsv).
                        math(EXPR _inject_at "${_lastAt0} + 1")
                    endif()

                    # Build result with prefix injected at _inject_at, but
                    # only if the segment isn't already prefixed (idempotent).
                    string(SUBSTRING "${SYM}" 0 ${_inject_at} _head)
                    string(SUBSTRING "${SYM}" ${_inject_at} -1 _tail)
                    string(LENGTH "${_tok}" _tok_len)
                    string(LENGTH "${_tail}" _tail_len)
                    set(_already_prefixed FALSE)
                    if(_tail_len GREATER_EQUAL _tok_len)
                        string(SUBSTRING "${_tail}" 0 ${_tok_len} _tail_pfx)
                        if("${_tail_pfx}" STREQUAL "${_tok}")
                            set(_already_prefixed TRUE)
                        endif()
                    endif()
                    if(NOT _already_prefixed)
                        set(_RENAMED_SYM "${_head}${_tok}${_tail}")
                    endif()
                endif()
            endif()

            # Option A: prefix embedded AOCL type-name components so C++
            # template/overload symbols match the renamed headers. Applied on
            # every MSVC path (mirrors pwsh Rename-Msvc, which always returns
            # via Prefix-MsvcTypes), including when no name/namespace rename
            # occurred above.
            _prefix_msvc_types(_RENAMED_SYM "${_tok}")
        endif()
    endif()
endmacro()

# ---------------------------------------------------------------------------
# Helper: compute new symbol name for one plain-C / Itanium / MSVC symbol
# Sets _NEW_SYM in parent scope; sets _NEW_SYM to "" if symbol should be skipped.
# ---------------------------------------------------------------------------
macro(_compute_new_symbol SYM)
    _should_skip_symbol("${SYM}")
    if(_SKIP)
        set(_NEW_SYM "")
    else()
        # Normalised prefix token (strip non-identifier chars)
        string(REGEX REPLACE "[^A-Za-z0-9_]" "" _prefix_tok "${PREFIX}")

        if("${SYM}" MATCHES "^_Z")
            # Itanium C++ mangled
            _rename_itanium_symbol("${SYM}" "${_prefix_tok}")
            set(_NEW_SYM "${_RENAMED_SYM}")
        elseif(_PLATFORM STREQUAL "Windows" AND "${SYM}" MATCHES "^\\?")
            # MSVC C++ mangled
            _rename_msvc_symbol("${SYM}" "${_prefix_tok}")
            set(_NEW_SYM "${_RENAMED_SYM}")
        else()
            # Plain C / assembler symbol — case-aware textual prefixing
            _get_intelligent_prefix("${SYM}" "${PREFIX}")
            # For symbols with leading underscores, _RESULT_PREFIX already contains them
            string(REGEX MATCH "^_+" _leading_us2 "${SYM}")
            string(LENGTH "${_leading_us2}" _leading_count2)
            string(SUBSTRING "${SYM}" ${_leading_count2} -1 _sym_rest2)
            set(_NEW_SYM "${_RESULT_PREFIX}${_sym_rest2}")
        endif()

        # No-op? skip
        if("${_NEW_SYM}" STREQUAL "${SYM}")
            set(_NEW_SYM "")
        endif()
    endif()
endmacro()




# ---------------------------------------------------------------------------
# 4. Map file generation
#    Reads symbols, applies filtering + renaming, writes the redefine-syms file
#    Returns: MAP_FILE path, SYMBOL_MAPPING list "old new" entries
# ---------------------------------------------------------------------------
function(generate_map_file LIB_FILE OUT_MAP_FILE OUT_MAPPING_COUNT)
    # Determine base name for map file (placed in build dir / cwd)
    get_filename_component(_lib_base "${LIB_FILE}" NAME_WE)
    set(_map_file "${INSTALL_PATH}/lib/${_lib_base}_map.txt")

    # -- Fast path: Python-driven map generation on Linux --------------------
    # CMake orchestrates; delegate the regex-heavy Itanium mangling + Option-A
    # embedded-type-tag rename to rename_engine_linux.py (--emit-map), which
    # reuses the exact functions the full Python flow uses (no behaviour
    # divergence). Same rationale as the pwsh fast path on Windows: pure-CMake
    # regex over 100k+ symbols is far too slow and cannot do the
    # mangled-namespace / type-component rewrite.
    if(NOT _PLATFORM STREQUAL "Windows" AND PYTHON3_EXE)
        execute_process(
            COMMAND "${PYTHON3_EXE}" "${CMAKE_CURRENT_LIST_DIR}/rename_engine_linux.py"
                    --emit-map "${LIB_FILE}" "${PREFIX}" "${_map_file}"
                    "${INSTALL_PATH}/include"
            RESULT_VARIABLE _py_rc
            OUTPUT_VARIABLE _py_out
            ERROR_VARIABLE  _py_err
        )
        if(_py_rc EQUAL 0 AND EXISTS "${_map_file}")
            file(STRINGS "${_map_file}" _py_map_lines)
            list(LENGTH _py_map_lines _count)
            message(STATUS "  Python map gen        : ${_count} symbol(s)")
            set(${OUT_MAP_FILE} "${_map_file}" PARENT_SCOPE)
            set(${OUT_MAPPING_COUNT} "${_count}" PARENT_SCOPE)
            return()
        else()
            message(STATUS "  Python map gen failed (rc=${_py_rc}); falling back to pure-CMake path")
            if(_py_err)
                message(STATUS "  ${_py_err}")
            endif()
        endif()
    endif()

    # -- Fast path: PowerShell-driven map generation on Windows --
    # Pure-CMake regex over 100k+ symbols takes 25+ minutes per library;
    # the equivalent PowerShell script (rename_engine_windows.ps1 (-Mode map)) does the
    # same work in 30-60 seconds (~50× speedup) by using compiled .NET
    # System.Text.RegularExpressions.Regex objects.
    #
    # Both implementations apply the SAME logic — keep them in sync when
    # editing _compute_new_symbol / _rename_msvc_symbol /
    # _rename_itanium_symbol / _should_skip_symbol / _get_intelligent_prefix.
    if(_PLATFORM STREQUAL "Windows")
        find_program(_POWERSHELL_EXE NAMES pwsh.exe powershell.exe)
        set(_ps_script "${CMAKE_CURRENT_LIST_DIR}/rename_engine_windows.ps1")
        if(_POWERSHELL_EXE AND EXISTS "${_ps_script}" AND LLVM_NM_TOOL)
            execute_process(
                COMMAND "${_POWERSHELL_EXE}" -NoProfile -ExecutionPolicy Bypass
                        -File "${_ps_script}"
                        -Mode map
                        -LibFile "${LIB_FILE}"
                        -LlvmNm  "${LLVM_NM_TOOL}"
                        -OutMap  "${_map_file}"
                        -Prefix  "${PREFIX}"
                        -IncludeDir "${INSTALL_PATH}/include"
                RESULT_VARIABLE _ps_rc
                OUTPUT_VARIABLE _ps_out
                ERROR_VARIABLE  _ps_err
            )
            if(_ps_rc EQUAL 0 AND EXISTS "${_map_file}")
                # Echo the script's progress/timing lines to the user, and
                # parse the "Symbols to rename : N" line to avoid re-reading
                # the (potentially 19 MB / 100 k+ line) map file just to count
                # entries — that count alone took ~30 s in pure-CMake.
                set(_count 0)
                if(_ps_out)
                    string(REPLACE "\n" ";" _ps_lines "${_ps_out}")
                    foreach(_l ${_ps_lines})
                        string(STRIP "${_l}" _l)
                        if(NOT _l STREQUAL "")
                            message(STATUS "  ${_l}")
                        endif()
                        if("${_l}" MATCHES "Symbols to rename[ \t]*:[ \t]*([0-9]+)")
                            set(_count "${CMAKE_MATCH_1}")
                        endif()
                    endforeach()
                endif()
                if(_count EQUAL 0)
                    # Fallback: still need to count if PS output didn't include it.
                    file(STRINGS "${_map_file}" _map_lines)
                    list(LENGTH _map_lines _count)
                endif()
                set(${OUT_MAP_FILE} "${_map_file}" PARENT_SCOPE)
                set(${OUT_MAPPING_COUNT} "${_count}" PARENT_SCOPE)
                return()
            else()
                message(STATUS "  PowerShell map gen failed (rc=${_ps_rc}); falling back to pure-CMake path")
                if(_ps_err)
                    message(STATUS "  ${_ps_err}")
                endif()
            endif()
        endif()
    endif()

    # -- Slow fallback: pure-CMake symbol-by-symbol map generation --
    # Extract symbols
    if(_PLATFORM STREQUAL "Windows")
        extract_symbols_windows("${LIB_FILE}" _syms)
    else()
        extract_symbols_linux("${LIB_FILE}" _syms)
    endif()

    list(LENGTH _syms _total_syms)
    message(STATUS "  Total symbols found   : ${_total_syms}")

    # Build the map file
    file(WRITE "${_map_file}" "")
    set(_count 0)

    foreach(_sym ${_syms})
        _compute_new_symbol("${_sym}")
        if(NOT _NEW_SYM STREQUAL "")
            # Escape any special chars for safe file writing
            file(APPEND "${_map_file}" "${_sym} ${_NEW_SYM}\n")
            math(EXPR _count "${_count} + 1")
        endif()
    endforeach()

    message(STATUS "  Symbols to rename     : ${_count}")
    set(${OUT_MAP_FILE} "${_map_file}" PARENT_SCOPE)
    set(${OUT_MAPPING_COUNT} "${_count}" PARENT_SCOPE)
endfunction()

# ---------------------------------------------------------------------------
# 5. Library renaming: copy to renamed/lib and run llvm-objcopy
# ---------------------------------------------------------------------------
function(rename_library LIB_FILE MAP_FILE)
    set(_renamed_dir "${INSTALL_PATH}/renamed/lib")
    file(MAKE_DIRECTORY "${_renamed_dir}")

    get_filename_component(_lib_name "${LIB_FILE}" NAME)
    set(_renamed_lib "${_renamed_dir}/${_lib_name}")

    # Copy original → renamed location
    file(COPY "${LIB_FILE}" DESTINATION "${_renamed_dir}")

    # Run objcopy / llvm-objcopy
    if(_PLATFORM STREQUAL "Windows")
        set(_objcopy "${LLVM_OBJCOPY_TOOL}")
        set(_extra_args "--remove-section" ".drectve")
    else()
        set(_objcopy "${OBJCOPY_TOOL}")
        set(_extra_args "")
    endif()

    message(STATUS "  Running objcopy on    : ${_renamed_lib}")
    execute_process(
        COMMAND "${_objcopy}" "--redefine-syms=${MAP_FILE}" ${_extra_args} "${_renamed_lib}"
        OUTPUT_VARIABLE _oc_out
        ERROR_VARIABLE  _oc_err
        RESULT_VARIABLE _oc_ret
    )
    if(NOT _oc_ret EQUAL 0)
        message(FATAL_ERROR "  llvm-objcopy failed for ${_lib_name}:\n${_oc_err}")
    endif()
    message(STATUS "  Symbol renaming done  : ${_renamed_lib}")
endfunction()




# ---------------------------------------------------------------------------
# 7. Header file renaming
#    Copies include/ to renamed/include/ then rewrites symbols in headers.
#    Uses the map file for plain-C symbols, plus regex-based namespace rewriting.
# ---------------------------------------------------------------------------
function(rename_headers MAP_FILE)
    set(_src_include "${INSTALL_PATH}/include")
    set(_dst_include "${INSTALL_PATH}/renamed/include")

    # Copy entire include tree
    file(COPY "${_src_include}/" DESTINATION "${_dst_include}")
    message(STATUS "  Copied headers        : ${_src_include} -> ${_dst_include}")

    # -- Fast path: Python-driven header rewrite on Linux --------------------
    # Delegate the FULL header rewrite (plain-C symbols + C++ namespaces +
    # CBLAS/OpenRNG enums + AOCL-vs-AOCL enum/type coexistence) to
    # rename_engine_linux.py (--emit-headers), which reuses the exact functions
    # the full Python flow uses (no behaviour divergence). CMake already copied
    # include/ -> renamed/include above; Python rewrites that copy in place
    # using the combined objcopy map. Same rationale as the pwsh path below:
    # pure-CMake cannot do the C++ namespace / enum-body / coexistence rewrite.
    if(NOT _PLATFORM STREQUAL "Windows" AND PYTHON3_EXE)
        execute_process(
            COMMAND "${PYTHON3_EXE}" "${CMAKE_CURRENT_LIST_DIR}/rename_engine_linux.py"
                    --emit-headers "${MAP_FILE}" "${_dst_include}"
            RESULT_VARIABLE _py_hdr_rc
            OUTPUT_VARIABLE _py_hdr_out
            ERROR_VARIABLE  _py_hdr_err
        )
        if(_py_hdr_rc EQUAL 0)
            if(_py_hdr_out)
                string(REPLACE "\n" ";" _py_hdr_lines "${_py_hdr_out}")
                foreach(_l ${_py_hdr_lines})
                    string(STRIP "${_l}" _l)
                    if(NOT _l STREQUAL "")
                        message(STATUS "  ${_l}")
                    endif()
                endforeach()
            endif()
            return()
        else()
            message(WARNING "  Python header rewrite failed (${_py_hdr_rc}): ${_py_hdr_err}")
            message(STATUS "  Falling back to CMake loop...")
        endif()
    endif()

    # -- Fast path: PowerShell (Windows) --
    # On Windows, delegate the whole map-read + filter + rewrite to a single
    # PowerShell call. The previous pure-CMake preprocessing did
    # file(STRINGS) on the 19 MB / 100 k-line map, then a
    # while/list(GET) loop over the same 100 k entries to build a CSV
    # (~3 minutes alone). PowerShell does the equivalent in <2 s.
    if(_PLATFORM STREQUAL "Windows")
        find_program(_POWERSHELL_EXE NAMES pwsh.exe powershell.exe)
        if(_POWERSHELL_EXE)
            file(TO_NATIVE_PATH "${MAP_FILE}"     _map_native)
            file(TO_NATIVE_PATH "${_dst_include}" _dst_include_native)
            set(_ps_script "${CMAKE_CURRENT_LIST_DIR}/rename_engine_windows.ps1")
            # Compute uppercase prefix here so the script can prefix CBLAS/
            # OpenRNG compile-time identifiers in headers (parity with the
            # Linux Python rename's apply_cblas_enum_renames /
            # apply_openrng_macro_renames passes).
            string(REGEX REPLACE "[^A-Za-z0-9_]" "" _hdr_prefix_tok "${PREFIX}")
            string(TOUPPER "${_hdr_prefix_tok}" _hdr_upper_prefix)

            message(STATUS "  Using PowerShell for fast header rewrite...")
            execute_process(
                COMMAND "${_POWERSHELL_EXE}" -NoProfile -ExecutionPolicy Bypass
                        -File "${_ps_script}"
                        -Mode headers
                        -MapFile "${_map_native}"
                        -IncludeDir "${_dst_include_native}"
                        -UpperPrefix "${_hdr_upper_prefix}"
                OUTPUT_VARIABLE _ps_out
                ERROR_VARIABLE  _ps_err
                RESULT_VARIABLE _ps_ret
            )
            if(_ps_ret EQUAL 0)
                if(_ps_out)
                    string(REPLACE "\n" ";" _ps_lines "${_ps_out}")
                    foreach(_l ${_ps_lines})
                        string(STRIP "${_l}" _l)
                        if(NOT _l STREQUAL "")
                            message(STATUS "  ${_l}")
                        endif()
                    endforeach()
                endif()
                return()
            else()
                message(WARNING "  PowerShell header rewrite failed (${_ps_ret}): ${_ps_err}")
                message(STATUS "  Falling back to CMake loop...")
            endif()
        endif()
    endif()

    # -- Fallback: CMake loop (slow but portable) --
    file(STRINGS "${MAP_FILE}" _map_lines)
    set(_old_syms "")
    set(_new_syms "")
    foreach(_line ${_map_lines})
        string(STRIP "${_line}" _line)
        if("${_line}" STREQUAL "")
            continue()
        endif()
        string(REGEX MATCH "^([^ ]+) (.+)$" _m "${_line}")
        if(CMAKE_MATCH_1 AND CMAKE_MATCH_2)
            set(_old "${CMAKE_MATCH_1}")
            set(_new "${CMAKE_MATCH_2}")
            if("${_old}" MATCHES "^[A-Za-z_][A-Za-z0-9_]*$")
                list(APPEND _old_syms "${_old}")
                list(APPEND _new_syms "${_new}")
            endif()
        endif()
    endforeach()

    list(LENGTH _old_syms _n_plain_syms)
    message(STATUS "  Plain-C symbols for header rewrite: ${_n_plain_syms}")

    file(GLOB_RECURSE _headers
        "${_dst_include}/*.h"
        "${_dst_include}/*.hpp"
        "${_dst_include}/*.hxx"
        "${_dst_include}/*.hh"
    )
    list(LENGTH _headers _n_headers)
    message(STATUS "  Processing headers    : ${_n_headers}")

    set(_processed 0)
    # Sentinels used to shield #include directive lines from symbol renaming
    # (an include path token like `alcp/` is NOT a symbol; renaming it would turn
    # `#include <alcp/macros.h>` into `#include <coexbalcp/macros.h>`).
    string(ASCII 1 _SOH)   # newline sentinel (flatten for MATCHALL)
    string(ASCII 2 _STX)   # placeholder delimiter (not in any header/token)
    foreach(_hdr ${_headers})
        file(READ "${_hdr}" _content)
        set(_original_content "${_content}")

        # Protect #include directives: stash each directive line behind a
        # placeholder, rename symbols, then restore the directives verbatim.
        string(REPLACE "\n" "${_SOH}" _flat "${_content}")
        string(REGEX MATCHALL "#[ \t]*include[^${_SOH}]*" _inc_dirs "${_flat}")
        set(_pi 0)
        foreach(_inc IN LISTS _inc_dirs)
            string(REPLACE "${_inc}" "${_STX}AOCLINC${_pi}${_STX}" _content "${_content}")
            math(EXPR _pi "${_pi} + 1")
        endforeach()

        # Replace each plain-C symbol using word-boundary matching.
        # Pre-check with string(FIND) before the slower REGEX REPLACE.
        set(_idx 0)
        list(LENGTH _old_syms _n)
        while(_idx LESS _n)
            list(GET _old_syms ${_idx} _old)
            list(GET _new_syms ${_idx} _new)
            string(FIND "${_content}" "${_old}" _quick_pos)
            if(NOT _quick_pos EQUAL -1)
                string(REGEX REPLACE "(^|[^A-Za-z0-9_])(${_old})([^A-Za-z0-9_]|$)"
                    "\\1${_new}\\3" _content "${_content}")
            endif()
            math(EXPR _idx "${_idx} + 1")
        endwhile()

        # Restore the protected #include directives.
        set(_pi 0)
        foreach(_inc IN LISTS _inc_dirs)
            string(REPLACE "${_STX}AOCLINC${_pi}${_STX}" "${_inc}" _content "${_content}")
            math(EXPR _pi "${_pi} + 1")
        endforeach()

        if(NOT "${_content}" STREQUAL "${_original_content}")
            file(WRITE "${_hdr}" "${_content}")
            math(EXPR _processed "${_processed} + 1")
        endif()
    endforeach()

    message(STATUS "  Headers updated       : ${_processed}/${_n_headers}")
endfunction()

# ---------------------------------------------------------------------------
# 8. Main processing loop
# ---------------------------------------------------------------------------
file(MAKE_DIRECTORY "${INSTALL_PATH}/renamed/lib")

# Find library files
if(_PLATFORM STREQUAL "Windows")
    file(GLOB _static_libs "${INSTALL_PATH}/lib/*_static.lib")
    file(GLOB _dlls        "${INSTALL_PATH}/lib/*.dll")
    set(_lib_files ${_static_libs})   # Process static libs; DLLs handled per-static
else()
    file(GLOB _lib_files
        "${INSTALL_PATH}/lib/*.a"
        "${INSTALL_PATH}/lib/*.so"
    )
endif()

list(LENGTH _lib_files _n_libs)
if(_n_libs EQUAL 0)
    message(FATAL_ERROR "No library files found in ${INSTALL_PATH}/lib")
endif()

message(STATUS "Found ${_n_libs} library file(s) to process")

# -- Optimization: master-map reuse --
# On Windows the per-component aocl_*_static.lib files are subsets of the
# union aocl_static.lib (which is built from the same object files via
# OBJECT libraries). Generating the symbol map is the slow part — pure-CMake
# regex over ~115 k symbols takes minutes. By generating the map ONCE for
# the union library and reusing it for all per-component libs, we cut the
# rename time roughly N-fold (N = number of static libs, typically 9-10).
#
# objcopy --redefine-syms silently ignores entries whose source symbol is
# not present in the input archive, so the union map is safe to use as-is
# for every subset library.
#
# To enable: hoist aocl_static.lib to the front of the processing order
# and remember its map for subsequent iterations.
if(_PLATFORM STREQUAL "Windows")
    set(_master_lib "${INSTALL_PATH}/lib/${LIBNAME}_static.lib")
    if(EXISTS "${_master_lib}")
        list(REMOVE_ITEM _lib_files "${_master_lib}")
        list(INSERT _lib_files 0 "${_master_lib}")
        message(STATUS "Master union library  : ${LIBNAME}_static.lib (will share its map across all per-component libs)")
    endif()
endif()
set(_master_map_file "")
set(_master_map_count 0)
set(_deferred_objcopy_libs "")

set(_all_map_file "")   # We accumulate into a combined map for header rewriting
set(_combined_map "${INSTALL_PATH}/lib/combined_map.txt")
file(WRITE "${_combined_map}" "")

set(_successful 0)
foreach(_lib ${_lib_files})
    get_filename_component(_lib_name "${_lib}" NAME)
    message(STATUS "")
    message(STATUS "--- Processing: ${_lib_name} ---")

    # On Linux, skip .so initially and process .a only;
    # .so will be recreated from the renamed .a later.
    if(NOT _PLATFORM STREQUAL "Windows" AND "${_lib}" MATCHES "\\.so$")
        message(STATUS "  Skipping .so (will recreate from renamed .a)")
        continue()
    endif()

    # Generate the symbol map (or reuse existing if SKIP_MAP_GEN=ON and map exists,
    # or reuse the master union map on Windows for per-component libs).
    get_filename_component(_lib_base_check "${_lib}" NAME_WE)
    set(_map_file_check "${INSTALL_PATH}/lib/${_lib_base_check}_map.txt")
    set(_using_master_map FALSE)
    if(SKIP_MAP_GEN AND EXISTS "${_map_file_check}")
        message(STATUS "  Reusing existing map file: ${_map_file_check}")
        file(STRINGS "${_map_file_check}" _map_lines_check)
        list(LENGTH _map_lines_check _map_count)
        set(_map_file "${_map_file_check}")
    elseif(_PLATFORM STREQUAL "Windows" AND _master_map_file AND NOT _lib STREQUAL _master_lib)
        # Reuse the master union map (huge perf win — see comment above).
        # IMPORTANT: do NOT re-read the 19 MB / 105 k-line master map here just
        # to get its line count — that re-parse takes ~30 s per iteration and
        # adds 4-5 minutes across the 9 per-component libs. Use the cached
        # count from the first iteration instead.
        message(STATUS "  Reusing master union map: ${_master_map_file}")
        set(_map_file "${_master_map_file}")
        set(_map_count "${_master_map_count}")
        set(_using_master_map TRUE)
    else()
        generate_map_file("${_lib}" _map_file _map_count)
        # Remember the master map (and its size) for later reuse
        if(_PLATFORM STREQUAL "Windows" AND _lib STREQUAL _master_lib)
            set(_master_map_file  "${_map_file}")
            set(_master_map_count "${_map_count}")
        endif()
    endif()

    if(_map_count EQUAL 0)
        message(STATUS "  No symbols to rename – skipping")
        continue()
    endif()

    # Rename the library (copy + objcopy).
    # Skip library rename if SKIP_MAP_GEN=ON (map was reused, so static lib already renamed).
    # On Windows, libs that share the master map are deferred to a parallel
    # batch run after the loop (see _windows_parallel_objcopy below) — this
    # alone cuts the rename phase ~N× (N = logical CPU cores).
    if(SKIP_MAP_GEN AND EXISTS "${_map_file_check}")
        message(STATUS "  Skipping library rename (SKIP_MAP_GEN=ON)")
    elseif(_using_master_map)
        # Just copy now; objcopy is batched at the end.
        set(_renamed_dir "${INSTALL_PATH}/renamed/lib")
        file(MAKE_DIRECTORY "${_renamed_dir}")
        file(COPY "${_lib}" DESTINATION "${_renamed_dir}")
        list(APPEND _deferred_objcopy_libs "${_renamed_dir}/${_lib_name}")
        message(STATUS "  Deferred objcopy (will run in parallel batch)")
    else()
        rename_library("${_lib}" "${_map_file}")
    endif()
    math(EXPR _successful "${_successful} + 1")

    # Accumulate into combined map for header processing.
    # Skip when reusing the master union map — its content was already
    # appended on the first iteration; appending again would just produce
    # 9× duplicates and bloat the header-rename pass.
    if(NOT _using_master_map)
        file(READ "${_map_file}" _map_content)
        file(APPEND "${_combined_map}" "${_map_content}")
    endif()

    # Windows: optionally relink DLL
    if(_PLATFORM STREQUAL "Windows" AND CREATE_SO)
        # Derive DLL name from *_static.lib → *.dll
        string(REGEX REPLACE "_static\\.lib$" ".dll" _dll_name "${_lib_name}")
        if("${_dll_name}" STREQUAL "${_lib_name}")
            string(REGEX REPLACE "\\.lib$" ".dll" _dll_name "${_lib_name}")
        endif()
        set(_orig_dll "${INSTALL_PATH}/lib/${_dll_name}")
        set(_renamed_lib_path "${INSTALL_PATH}/renamed/lib/${_lib_name}")

        if(EXISTS "${_orig_dll}")
            create_dll_windows("${_renamed_lib_path}" "${_orig_dll}" "${_map_file}")
        else()
            message(STATUS "  No DLL found at ${_orig_dll} – skipping DLL creation")
        endif()
    endif()

    # Linux: create .so from renamed .a, using the original .so as export reference
    if(NOT _PLATFORM STREQUAL "Windows" AND CREATE_SO)
        string(REGEX REPLACE "\\.a$" "" _a_stem "${_lib_name}")
        set(_orig_so "${INSTALL_PATH}/lib/${_a_stem}.so")
        if(EXISTS "${_orig_so}")
            set(_renamed_a "${INSTALL_PATH}/renamed/lib/${_lib_name}")
            create_shared_library_linux("${_renamed_a}" "${_orig_so}" _out_so)
        endif()
    endif()
endforeach()

# ---------------------------------------------------------------------------
# 8b. Parallel objcopy batch (Windows only)
#     Runs --redefine-syms on all libs that share the master union map in
#     parallel via parallel_objcopy.ps1. With ~9 libs and ~8 cores this
#     converts a serial ~8 min step into ~1-2 min wall time.
# ---------------------------------------------------------------------------
if(_PLATFORM STREQUAL "Windows" AND _deferred_objcopy_libs AND _master_map_file)
    list(LENGTH _deferred_objcopy_libs _n_def)
    message(STATUS "")
    message(STATUS "--- Parallel objcopy batch (${_n_def} libs) ---")
    find_program(_POWERSHELL_EXE NAMES pwsh.exe powershell.exe)
    set(_par_script "${CMAKE_CURRENT_LIST_DIR}/rename_engine_windows.ps1")
    if(_POWERSHELL_EXE AND EXISTS "${_par_script}")
        # Write the lib list to a file (avoids any CLI list/array parsing
        # quirks for paths that may contain spaces or commas).
        set(_libs_file "${INSTALL_PATH}/lib/_par_objcopy_libs.txt")
        file(WRITE "${_libs_file}" "")
        foreach(_dlib ${_deferred_objcopy_libs})
            file(APPEND "${_libs_file}" "${_dlib}\n")
        endforeach()
        execute_process(
            COMMAND "${_POWERSHELL_EXE}" -NoProfile -ExecutionPolicy Bypass
                    -File "${_par_script}"
                    -Mode parobjcopy
                    -Objcopy  "${LLVM_OBJCOPY_TOOL}"
                    -MapFile  "${_master_map_file}"
                    -LibsFile "${_libs_file}"
                    -RemoveDrectve
            RESULT_VARIABLE _par_rc
            OUTPUT_VARIABLE _par_out
            ERROR_VARIABLE  _par_err
        )
        if(_par_out)
            string(REPLACE "\n" ";" _par_lines "${_par_out}")
            foreach(_l ${_par_lines})
                string(STRIP "${_l}" _l)
                if(NOT _l STREQUAL "")
                    message(STATUS "  ${_l}")
                endif()
            endforeach()
        endif()
        if(NOT _par_rc EQUAL 0)
            message(WARNING "Parallel objcopy returned ${_par_rc}; falling back to sequential")
            if(_par_err)
                message(STATUS "  ${_par_err}")
            endif()
            foreach(_dlib ${_deferred_objcopy_libs})
                execute_process(
                    COMMAND "${LLVM_OBJCOPY_TOOL}" "--redefine-syms=${_master_map_file}"
                            --remove-section .drectve "${_dlib}"
                    RESULT_VARIABLE _oc_rc
                )
                if(NOT _oc_rc EQUAL 0)
                    message(FATAL_ERROR "Sequential fallback objcopy failed on ${_dlib}")
                endif()
            endforeach()
        endif()
    else()
        message(STATUS "PowerShell not found; running deferred objcopy sequentially")
        foreach(_dlib ${_deferred_objcopy_libs})
            execute_process(
                COMMAND "${LLVM_OBJCOPY_TOOL}" "--redefine-syms=${_master_map_file}"
                        --remove-section .drectve "${_dlib}"
                RESULT_VARIABLE _oc_rc
            )
            if(NOT _oc_rc EQUAL 0)
                message(FATAL_ERROR "Sequential objcopy failed on ${_dlib}")
            endif()
        endforeach()
    endif()
endif()

# ---------------------------------------------------------------------------
# 9. Rename headers using the combined map
# ---------------------------------------------------------------------------
message(STATUS "")
message(STATUS "--- Renaming headers ---")
rename_headers("${_combined_map}")

# ---------------------------------------------------------------------------
# 10. Summary
# ---------------------------------------------------------------------------
message(STATUS "")
message(STATUS "=== Symbol Renaming Summary ===")
message(STATUS "Libraries processed : ${_successful}/${_n_libs}")
message(STATUS "Prefix applied      : ${PREFIX}")
message(STATUS "Original libs       : ${INSTALL_PATH}/lib")
message(STATUS "Renamed libs        : ${INSTALL_PATH}/renamed/lib")
message(STATUS "Original headers    : ${INSTALL_PATH}/include")
message(STATUS "Renamed headers     : ${INSTALL_PATH}/renamed/include")

# ---------------------------------------------------------------------------
# 11. Prune renamed/lib down to the final umbrella library only
# ---------------------------------------------------------------------------
# Shared build:  keep aocl.dll + aocl.lib (Win) or libaocl.so (Linux)
# Static build:  keep aocl_static.lib renamed to aocl.lib (Win)
#                or libaocl.a (Linux, already correctly named)
set(_renamed_dir "${INSTALL_PATH}/renamed/lib")
file(GLOB _renamed_artifacts
    "${_renamed_dir}/*.lib"
    "${_renamed_dir}/*.dll"
    "${_renamed_dir}/*.so"
    "${_renamed_dir}/*.so.*"
    "${_renamed_dir}/*.a"
    "${_renamed_dir}/*.def"
    "${_renamed_dir}/*.rsp"
    "${_renamed_dir}/*.log"
    "${_renamed_dir}/*.exp"
    "${_renamed_dir}/*.txt"
)

# Pick the keepers based on platform + mode.
set(_keep "")
if(_PLATFORM STREQUAL "Windows")
    if(CREATE_SO)
        # Final shared umbrella: ${LIBNAME}.dll + its import library ${LIBNAME}.lib.
        list(APPEND _keep "${_renamed_dir}/${LIBNAME}.dll" "${_renamed_dir}/${LIBNAME}.lib")
    else()
        # Static-only: rename umbrella ${LIBNAME}_static.lib -> ${LIBNAME}.lib.
        if(EXISTS "${_renamed_dir}/${LIBNAME}_static.lib")
            file(RENAME "${_renamed_dir}/${LIBNAME}_static.lib"
                        "${_renamed_dir}/${LIBNAME}.lib")
            message(STATUS "Renamed ${LIBNAME}_static.lib -> ${LIBNAME}.lib")
        endif()
        list(APPEND _keep "${_renamed_dir}/${LIBNAME}.lib")
    endif()
else()
    if(CREATE_SO)
        # Linux shared: keep lib${LIBNAME}.so (and any versioned symlinks).
        file(GLOB _so_keepers "${_renamed_dir}/lib${LIBNAME}.so*")
        list(APPEND _keep ${_so_keepers})
    else()
        # Linux static: keep lib${LIBNAME}.a.
        list(APPEND _keep "${_renamed_dir}/lib${LIBNAME}.a")
    endif()
endif()

set(_removed 0)
foreach(_f IN LISTS _renamed_artifacts)
    list(FIND _keep "${_f}" _idx)
    if(_idx EQUAL -1)
        file(REMOVE "${_f}")
        math(EXPR _removed "${_removed} + 1")
    endif()
endforeach()
if(_removed GREATER 0)
    message(STATUS "Pruned ${_removed} intermediate artifact(s) from ${_renamed_dir}")
endif()

# Optional: prune the staging install_package/lib down to the umbrella library
# only. Enabled via -DPRUNE_STAGING_LIBS=ON, which the CMakeLists install hook
# passes for full builds. Standalone iterators like _rename_only.bat omit it,
# so the per-component *_static.lib inputs survive across re-runs.
if(PRUNE_STAGING_LIBS)
    set(_staging_dir "${INSTALL_PATH}/lib")
    file(GLOB _staging_artifacts
        "${_staging_dir}/*.lib"
        "${_staging_dir}/*.dll"
        "${_staging_dir}/*.exp"
        "${_staging_dir}/*.txt"
    )
    set(_staging_keep "")
    if(_PLATFORM STREQUAL "Windows")
        if(CREATE_SO)
            list(APPEND _staging_keep "${_staging_dir}/${LIBNAME}.dll" "${_staging_dir}/${LIBNAME}.lib")
        else()
            # Static: the ONLY deliverable end users (and the original,
            # un-renamed tests) consume is ${LIBNAME}.lib -- the unified static
            # archive (canonical link name for both linkages). ${LIBNAME}_static.lib
            # is merely the rename-flow duplicate that fed this pass; the rename
            # loop above has already consumed it, so drop it here. PRUNE_STAGING_LIBS
            # is set only for full builds -- standalone re-run iterators
            # (e.g. _rename_only.bat) skip this block entirely and thus retain
            # their *_static.lib re-run input.
            list(APPEND _staging_keep "${_staging_dir}/${LIBNAME}.lib")
        endif()
    endif()
    set(_staging_removed 0)
    foreach(_f IN LISTS _staging_artifacts)
        list(FIND _staging_keep "${_f}" _idx)
        if(_idx EQUAL -1)
            file(REMOVE "${_f}")
            math(EXPR _staging_removed "${_staging_removed} + 1")
        endif()
    endforeach()
    if(_staging_removed GREATER 0)
        message(STATUS "Pruned ${_staging_removed} intermediate artifact(s) from ${_staging_dir}")
    endif()
endif()

message(STATUS "Symbol renaming completed successfully!")
