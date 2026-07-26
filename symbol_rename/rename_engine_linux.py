#!/usr/bin/env python3
# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
"""
Symbol renaming engine (Linux) with case-aware prefixing.

Renames symbols in static libraries (.a) via objcopy, then builds shared
libraries (.so) from the renamed archives. Case-aware prefixing:
   - UPPERCASE symbols  → UPPERCASE prefix  (DGEMM_       → AOCL_DGEMM_)
   - lowercase symbols  → lowercase prefix  (cblas_dgemm  → aocl_cblas_dgemm)
   - mixed-case symbols → UPPERCASE prefix  (CblasNoTrans → AOCL_CblasNoTrans)
   - leading underscores are preserved      (_example_api → _aocl_example_api)

C++ runtime/ABI and std:: symbols are preserved; other mangled C++ symbols are
renamed by injecting the namespace component. Uses gcc (default) to link the
shared libraries.
"""

import glob
import multiprocessing
import os
import platform
import re
import shutil
import subprocess
import sys
import time

# Regexes for Itanium C++ ABI artifacts that should never be renamed
ABI_EXCLUDES = [
    # C++ runtime & exceptions
    r'^__gxx_personality_v0$',
    r'^__cxa_',
    r'^_Unwind_',
    r'^__stack_chk_(fail|guard)$',
    r'^__tls_get_addr$',
    r'^__dso_handle$',
    
    # Common system/libc/pthread
    r'^__libc_', r'^__pthread_',
    
    # Debug/anonymous/temporary
    r'^DW\.ref\.', r'^\.(L|local)', r'^a\.',
    
    # GOT/PLT related
    r'^_GLOBAL_OFFSET_TABLE_$',
    
    # Version symbols
    r'@@',
    
    # Init/fini
    r'^_init$', r'^_fini$',
    r'^__gmon_start__$',
]

# Standard C/POSIX/math symbols that must never be renamed. They appear as weak
# (W) defined symbols in BLIS static libraries (emitted from BLIS_INLINE
# functions) but are libc/libm symbols and must keep their original names.

def _build_stdlib_excludes_from_system():
    """Dynamically build stdlib exclusion set from installed system shared libraries.

    Queries libc, libm, and libpthread via `nm -D --defined-only` so the set
    is always correct for the target system without requiring a hand-maintained
    symbol list.  Falls back to a minimal hardcoded set when system libs are
    unavailable (e.g., cross-compilation environments).
    """
    # Minimal fallback covering the symbols actually observed in BLIS .a files.
    # Used as a safety net when no system libraries can be found.
    _FALLBACK = frozenset([
        'abs', 'fabs', 'fabsf', 'sqrt', 'sqrtf', 'round', 'roundf',
        'floor', 'floorf', 'ceil', 'ceilf', 'fmin', 'fminf', 'fmax', 'fmaxf',
        'malloc', 'free', 'memcpy', 'memset', 'memcmp', 'strlen',
        'pthread_create', 'pthread_join',
    ])

    # Candidate paths covering Debian/Ubuntu (x86_64 + aarch64) and RHEL/CentOS.
    candidates = [
        '/lib/x86_64-linux-gnu/libm.so.6',
        '/lib/x86_64-linux-gnu/libc.so.6',
        '/lib/x86_64-linux-gnu/libpthread.so.0',
        '/lib/aarch64-linux-gnu/libm.so.6',
        '/lib/aarch64-linux-gnu/libc.so.6',
        '/lib/aarch64-linux-gnu/libpthread.so.0',
        '/lib64/libm.so.6',
        '/lib64/libc.so.6',
        '/lib64/libpthread.so.0',
        '/usr/lib/x86_64-linux-gnu/libm.so.6',
        '/usr/lib/x86_64-linux-gnu/libc.so.6',
    ]

    excludes = set()
    libs_found = 0
    for lib in candidates:
        if not os.path.exists(lib):
            continue
        result = subprocess.run(
            ['nm', '-D', '--defined-only', '--no-sort', lib],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            continue
        libs_found += 1
        for line in result.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) >= 3 and parts[1] in ('T', 'W', 'D', 'B'):
                excludes.add(parts[2])

    if libs_found == 0:
        print("Warning: No system shared libraries found for stdlib exclusion; "
              "using fallback symbol set.", file=sys.stderr)
        return _FALLBACK

    # Always include the fallback to cover stripped libs that omit weak symbols.
    excludes |= _FALLBACK
    return frozenset(excludes)

STDLIB_SYMBOL_EXCLUDES = _build_stdlib_excludes_from_system()

# Itanium C++ mangling helpers
CV_REF_QUALIFIERS = set('rVKRO')

def is_itanium_mangled_symbol(symbol):
    """Return True if symbol appears to be an Itanium C++ mangled name."""
    return symbol.startswith('_Z')

def normalize_mangled_prefix_token(prefix):
    """Normalize user prefix for C++ mangled first-component replacement.

    Keeps case (important for user-requested branding like AOCL_52_) and strips
    non-identifier characters.

    The caller's trailing-underscore intent is preserved:
      - prefix="AOCL_" -> token="AOCL_"
      - prefix="aocl"  -> token="aocl"
    """
    token = re.sub(r'[^A-Za-z0-9_]', '', prefix)
    if not token:
        return ''
    return token

def _find_nested_name_index(symbol):
    """Find the 'N' index of the primary nested-name encoding in a mangled symbol.

    Returns:
        int | None: index of 'N' if found, else None.
    """
    if not symbol.startswith('_Z'):
        return None

    # Most common function/type encodings.
    if symbol.startswith('_ZN'):
        return 2

    # Local names containing nested entities (e.g., static locals in functions).
    if symbol.startswith('_ZZN'):
        return 3

    # Local entity of a top-level (non-namespace) function: _ZZ<digits><name>...
    # These are local statics (lookup tables, caches) inside top-level template
    # functions.  The digit at position 3 distinguishes them from _ZZN (nested).
    # Example: _ZZ14aoclsparse_rotIdE...3tbl -> _ZZ19AOCL_aoclsparse_rotIdE...3tbl
    if symbol.startswith('_ZZ') and len(symbol) > 3 and symbol[3].isdigit():
        return 2  # _replace_first_nested_component reads <len><name> at [3:]

    # Special-name encodings with nested type names.
    special_prefixes = (
        '_ZTVN', '_ZTIN', '_ZTSN', '_ZTTN', '_ZTCN', '_ZGVN', '_ZGRN'
    )
    for pfx in special_prefixes:
        if symbol.startswith(pfx):
            return len(pfx) - 1

    # Guard variable for local static with embedded encoding (_ZGVZ...).
    if symbol.startswith('_ZGVZ'):
        # Top-level function check FIRST: digit at position 5 means the enclosing
        # function is a top-level (non-namespace) template function.
        # Must precede the find('N') search because template args often contain N.
        # Example: _ZGVZ21aoclsparse_blkcsrmv_tIdENSt9enable_if...E8can_exec
        #       -> _ZGVZ26AOCL_aoclsparse_blkcsrmv_tIdENSt9enable_if...E8can_exec
        if len(symbol) > 5 and symbol[5].isdigit():
            return 4  # _replace_first_nested_component reads <len><name> at [5:]
        # Nested function: search for 'N' that starts the nested-name encoding.
        pos = symbol.find('N', 5)
        if pos != -1:
            return pos

    # Thunk variants often include an underscore followed by a nested encoding.
    # Examples: _ZThn16_N3foo3barEv, _ZTv0_n24_N3foo3barEv
    if symbol.startswith(('_ZTh', '_ZTv', '_ZTc')):
        pos = symbol.find('_N')
        if pos != -1:
            return pos + 1

    # Top-level RTTI / vtable / typeinfo for non-nested (non-namespace) types.
    # Handles _ZTI<len><name>, _ZTV<len><name>, _ZTS<len><name>, etc.
    # Example: _ZTI12basic_handleIdE  -> _ZTI17AOCL_basic_handleIdE
    # Note: _ZTIN / _ZTVN / _ZTSN are already handled by special_prefixes above;
    # this branch only fires when the character after the 4-char prefix is a digit.
    for _rtti_pfx in ('_ZTI', '_ZTV', '_ZTS', '_ZTT', '_ZTC', '_ZGV', '_ZGR'):
        if symbol.startswith(_rtti_pfx):
            rest_idx = len(_rtti_pfx)  # position right after the prefix
            if rest_idx < len(symbol) and symbol[rest_idx].isdigit():
                # Return rest_idx - 1 so that _replace_first_nested_component
                # skips one char (as if skipping 'N') and lands on the digits.
                return rest_idx - 1
            break  # prefix matched but next char is not digit; handled elsewhere

    # Top-level function / variable: _Z<digits><name>...
    # Covers template functions and free functions not inside any namespace.
    # Examples:
    #   _Z11da_tree_fitIdE...        -> _Z16AOCL_da_tree_fitIdE...
    #   _Z10kt_trsv_ltILN16...       -> _Z15AOCL_kt_trsv_ltILN16...
    #   _Z12estimate_nnz...cold      -> _Z17AOCL_estimate_nnz...cold  (clones preserved)
    # Condition: third character is a digit (rules out _ZN, _ZS, _ZT, _ZG etc.).
    if len(symbol) > 2 and symbol[2].isdigit():
        return 1  # fake n_index: _replace_first_nested_component reads <len><name> at [2:]

    return None

def _is_std_at_nested_name(symbol, n_index):
    """Check if a nested-name encoding starts with std:: (St abbreviation)."""
    if n_index is None:
        return False

    i = n_index + 1
    while i < len(symbol) and symbol[i] in CV_REF_QUALIFIERS:
        i += 1
    return symbol[i:i+2] == 'St'

def _replace_first_nested_component(symbol, n_index, prefix_token):
    """Replace first nested-name component with <prefix><orig_component>.

    This preserves nesting depth and keeps Itanium back-references (e.g. NS0_)
    aligned with the original substitution table.
    """
    if n_index is None:
        return symbol

    i = n_index + 1
    while i < len(symbol) and symbol[i] in CV_REF_QUALIFIERS:
        i += 1

    # Parse first source-name <len><identifier> component.
    j = i
    while j < len(symbol) and symbol[j].isdigit():
        j += 1
    if j == i:
        return symbol

    name_len = int(symbol[i:j])
    start = j
    end = start + name_len
    if end > len(symbol):
        return symbol

    first_component = symbol[start:end]
    replaced_component = f"{prefix_token}{first_component}"

    # Avoid duplicate replacement when already prefixed.
    if first_component.startswith(prefix_token):
        return symbol

    encoded = f"{len(replaced_component)}{replaced_component}"
    return symbol[:i] + encoded + symbol[end:]

def _extract_first_nested_component(symbol):
    """Extract first nested-name component from an Itanium mangled symbol."""
    n_index = _find_nested_name_index(symbol)
    if n_index is None:
        return None

    i = n_index + 1
    while i < len(symbol) and symbol[i] in CV_REF_QUALIFIERS:
        i += 1

    j = i
    while j < len(symbol) and symbol[j].isdigit():
        j += 1
    if j == i:
        return None

    name_len = int(symbol[i:j])
    start = j
    end = start + name_len
    if end > len(symbol):
        return None

    return symbol[start:end]

def build_namespace_rename_map(symbol_mapping):
    """Build first-namespace identifier rename map from mangled symbol mapping.

    Example:
        _ZN4alcp5utils... -> _ZN12AOCL_52_alcp5utils...
        yields {'alcp': 'AOCL_52_alcp'}
    """
    namespace_renames = {}

    for old_name, new_name in symbol_mapping.items():
        if not (is_itanium_mangled_symbol(old_name) and is_itanium_mangled_symbol(new_name)):
            continue

        old_ns = _extract_first_nested_component(old_name)
        new_ns = _extract_first_nested_component(new_name)

        if not old_ns or not new_ns or old_ns == new_ns:
            continue

        if old_ns in namespace_renames and namespace_renames[old_ns] != new_ns:
            continue

        namespace_renames[old_ns] = new_ns

    return namespace_renames

def apply_namespace_renames(content, namespace_renames):
    """Apply C++ namespace identifier rewrites in headers.

    This performs a mechanical first-identifier rename (e.g. alcp -> AOCL_52_alcp)
    in common namespace contexts while avoiding partial identifier rewrites.
    """
    if not namespace_renames:
        return content

    updated = content
    for old_ns, new_ns in sorted(namespace_renames.items(), key=lambda x: len(x[0]), reverse=True):
        if old_ns == new_ns:
            continue

        # Qualified usages: old_ns::...
        updated = re.sub(
            rf'(?<![A-Za-z0-9_]){re.escape(old_ns)}(?=::)',
            new_ns,
            updated
        )

        # namespace old_ns { ... }
        updated = re.sub(
            rf'(\bnamespace\s+){re.escape(old_ns)}(?=\s*\{{)',
            rf'\1{new_ns}',
            updated
        )

        # using namespace old_ns;
        updated = re.sub(
            rf'(\busing\s+namespace\s+){re.escape(old_ns)}(?=\s*;)',
            rf'\1{new_ns}',
            updated
        )

        # namespace close comments: // namespace old_ns::...
        updated = re.sub(
            rf'(//\s*namespace\s+){re.escape(old_ns)}(?=\s*(::|\b))',
            rf'\1{new_ns}',
            updated
        )

    return updated

def build_api_prefix_rename_map(symbol_mapping):
    """Build API family prefix rewrites from concrete symbol mappings.

    Example:
        cblas_sgemm -> aocl_52_cblas_sgemm
        yields {'cblas_': 'aocl_52_cblas_'}

    These rewrites are used for C++ wrapper identifiers in headers (e.g.,
    cblas_gemm overloads) that may not appear as concrete ELF symbols.
    """
    # NOTE:
    # - cblas_/lapacke_/blis_/bli_ are classic API families.
    # - da_/aoclsparse_ are included for wrapper/prototype fallbacks in headers
    #   where concrete symbol-level replacement may miss a declaration.
    #   Actual rewrite is constrained to function-like identifiers in
    #   apply_api_prefix_renames() to avoid touching types like da_status,
    #   da_int, aoclsparse_int, etc.
    families = ('cblas_', 'lapacke_', 'blis_', 'bli_', 'da_', 'aoclsparse_')
    prefix_map = {}

    for old_name, new_name in symbol_mapping.items():
        if not isinstance(old_name, str) or not isinstance(new_name, str):
            continue

        for family in families:
            if not old_name.startswith(family):
                continue
            if not new_name.endswith(old_name):
                continue

            new_family = new_name[:-len(old_name)] + family
            if new_family == family:
                continue

            if family in prefix_map and prefix_map[family] != new_family:
                continue

            prefix_map[family] = new_family

    return prefix_map

def infer_wrapper_prefix(api_prefix_renames, preferred_families=None):
    """Infer the common textual wrapper prefix from API family rewrites.

    Example:
        {'cblas_': 'mylib_52_cblas_'} -> 'mylib_52_'
    """
    if not api_prefix_renames:
        return ''

    requested_families = preferred_families
    if requested_families is None:
        requested_families = ('cblas_', 'lapacke_', 'blis_', 'bli_', 'da_', 'aoclsparse_')

    for family in requested_families:
        mapped = api_prefix_renames.get(family)
        if mapped and isinstance(mapped, str) and mapped.endswith(family):
            return mapped[:-len(family)]

    # When explicit families are requested, do not infer from unrelated mappings.
    if preferred_families is not None:
        return ''

    for old_prefix, new_prefix in api_prefix_renames.items():
        if isinstance(old_prefix, str) and isinstance(new_prefix, str) and old_prefix and new_prefix.endswith(old_prefix):
            return new_prefix[:-len(old_prefix)]

    return ''

def build_cpp_namespace_fallback_map(api_prefix_renames):
    """Build deterministic C++ namespace fallback rewrites for wrapper headers.

    This targets wrapper namespaces that are not represented as mangled symbols,
    such as `namespace blis` and `namespace libflame`.
    """
    # Restrict fallback namespace rewrites to BLAS/LAPACK-related mappings.
    wrapper_prefix = infer_wrapper_prefix(
        api_prefix_renames,
        preferred_families=('cblas_', 'lapacke_', 'blis_', 'bli_'),
    )
    if not wrapper_prefix:
        return {}

    return {
        'blis': f'{wrapper_prefix}blis',
        'libflame': f'{wrapper_prefix}libflame',
    }

def apply_define_macro_lhs_renames(content, api_prefix_renames):
    """Rename the LHS (macro name) and RHS of object-like #define alias macros.

    BLIS uses chains of object-like #define aliases to select
    type-specific implementations, e.g.:
        #define bli_cscal2ris    bli_cccscal2ris
    The macro name (bli_cscal2ris) is a pure preprocessor alias and never
    appears as a binary symbol, so generate_mapping() never produces a mapping
    for it.  When the inline function body referencing it is renamed, the
    alias #define must also be renamed to avoid undefined identifier errors.

    The RHS target (bli_cccscal2ris) may also be an inline-only symbol absent
    from the binary map; if it carries a known API prefix it is renamed here
    as well so that both sides of the alias agree after renaming.

    This function renames the LHS token of #define lines that:
      - define an object-like macro (no '(' immediately after the name), and
      - whose name matches one of the API family prefixes being renamed.
    It also renames any bare identifier on the RHS that starts with an old prefix.
    """
    if not api_prefix_renames:
        return content

    def _rename_identifier(ident):
        for old_prefix, new_prefix in api_prefix_renames.items():
            if ident.startswith(old_prefix) and not ident.startswith(new_prefix):
                return new_prefix + ident[len(old_prefix):]
        return ident

    lines = content.split('\n')
    result = []
    for line in lines:
        # Match: #define IDENTIFIER  (with optional leading whitespace, no '(' after name)
        m = re.match(r'^(\s*#\s*define\s+)([A-Za-z_][A-Za-z0-9_]*)(\s+\S)', line)
        if m:
            prefix_part  = m.group(1)
            macro_name   = m.group(2)
            rest_of_line = line[m.end(2):]
            # Rename the LHS if it starts with a known old prefix
            new_macro_name = _rename_identifier(macro_name)
            # Rename every identifier in the RHS that starts with a known old prefix
            new_rhs = re.sub(
                r'\b([A-Za-z_][A-Za-z0-9_]*)\b',
                lambda mo: _rename_identifier(mo.group(1)),
                rest_of_line,
            )
            if new_macro_name != macro_name or new_rhs != rest_of_line:
                line = prefix_part + new_macro_name + new_rhs
        result.append(line)
    return '\n'.join(result)


def apply_paste_token_prefix_renames(content, api_prefix_renames):
    """Rename API prefixes that appear before token-paste operators (##) in macros.

    BLIS defines helper macros that build symbol names via token pasting, e.g.:
        #define PASTEMAC_(ch,op)  bli_ ## ch ## op
    Because the prefix appears as a bare string fragment (not a complete C
    identifier) before '##', the word-boundary regex used by
    apply_api_prefix_renames skips it.  After renaming, the binary has
    <prefix>bli_sXXX but the macro still generates bli_sXXX, causing
    'implicit declaration' errors at compile time.

    This function finds occurrences of old_prefix immediately followed by
    optional whitespace and '##' in any #define body and replaces the prefix.
    """
    if not api_prefix_renames:
        return content

    for old_prefix, new_prefix in api_prefix_renames.items():
        if old_prefix == new_prefix:
            continue
        # Match the prefix as a token fragment before ##, e.g.  bli_ ## or  bli_## 
        pattern = re.escape(old_prefix) + r'(\s*##)'
        replacement = new_prefix + r'\1'
        content = re.sub(pattern, replacement, content)
    return content

def apply_pastef77_prefix_renames(content, api_prefix_renames):
    """Prepend the rename prefix token to PASTEF77x Fortran name-mangling macro bodies.

    BLIS provides PASTEF770/PASTEF77/PASTEF772/PASTEF773 (and their S and
    underscore variants) to build Fortran BLAS symbol names via token pasting:
        #define PASTEF770(name)      name           -> expands to e.g. sgemm
        #define PASTEF770(name)      name ## _      -> expands to e.g. sgemm_

    After symbol renaming the Fortran symbols are prefixed (e.g. <prefix>sgemm_),
    so the macro bodies must emit the new prefix token at the start:
        #define PASTEF770(name)      <prefix> ## name
        #define PASTEF770(name)      <prefix> ## name ## _

    This function rewrites only the #define bodies of these eight macro families
    by inserting `<rename_prefix> ## ` at the start of the token-paste chain.
    It is idempotent: if the prefix is already present the line is left unchanged.
    """
    if not api_prefix_renames:
        return content

    rename_token = infer_wrapper_prefix(
        api_prefix_renames,
        preferred_families=('cblas_', 'lapacke_', 'blis_', 'bli_'),
    )
    if not rename_token:
        return content

    esc = re.escape(rename_token)

    def _patch_line(line):
        # Only act on lines that define one of the PASTEF77x macros.
        m = re.match(r'^(\s*#\s*define\s+)(PASTEF77[0-9]*S?)\s*\(', line)
        if not m:
            return line
        # Already patched?
        if re.search(esc, line):
            return line
        # Find the end of the parameter list (closing ')').
        paren_start = line.index('(', m.end(1) + len(m.group(2)))
        depth = 0
        body_start = paren_start
        for i in range(paren_start, len(line)):
            if line[i] == '(':
                depth += 1
            elif line[i] == ')':
                depth -= 1
                if depth == 0:
                    body_start = i + 1
                    break
        # body_start points to the first character after the closing ')'
        after_paren = line[body_start:]
        body = after_paren.lstrip()
        ws = after_paren[: len(after_paren) - len(body)]
        # Insert `rename_token ## ` before the existing body
        new_body = rename_token + ' ## ' + body
        return line[:body_start] + ws + new_body

    return '\n'.join(_patch_line(l) for l in content.split('\n'))


def apply_lapack_global_suffix_renames(content, api_prefix_renames):
    """Rename bare Fortran symbol names inside LAPACK_GLOBAL_SUFFIX() calls.

    lapack.h declares Fortran-interface wrappers as:
        #define LAPACK_cgbrfsx_base LAPACK_GLOBAL_SUFFIX(cgbrfsx,CGBRFSX)
    The Fortran symbol cgbrfsx_ is not present as a defined symbol in the
    static library (LAPACK Fortran symbols are link-time external references),
    so it never appears in the binary symbol map. Consequently the
    LAPACK_GLOBAL_SUFFIX arguments are left unrenamed, meaning the header still
    references the original Fortran symbol name while the binary was renamed.

    This function renames the lowercase and UPPERCASE arguments inside every
    LAPACK_GLOBAL_SUFFIX(name, NAME) invocation according to the active API
    prefix renames (specifically the lapacke_ family prefix which drives the
    lowercase prefix for Fortran symbols).
    """
    if not api_prefix_renames:
        return content

    # Infer the lowercase wrapper prefix from cblas_/lapacke_/bli_ mappings
    wrapper_prefix = infer_wrapper_prefix(
        api_prefix_renames,
        preferred_families=('cblas_', 'lapacke_', 'blis_', 'bli_'),
    )
    if not wrapper_prefix:
        return content

    upper_prefix = wrapper_prefix.upper()

    def _rename_global_suffix(m):
        low_name  = m.group(1)   # e.g. "cgbrfsx"
        up_name   = m.group(2)   # e.g. "CGBRFSX"
        # Only rename if not already prefixed
        if not low_name.startswith(wrapper_prefix):
            low_name = wrapper_prefix + low_name
        if not up_name.startswith(upper_prefix):
            up_name = upper_prefix + up_name
        return f'LAPACK_GLOBAL_SUFFIX({low_name},{up_name})'

    def _rename_global_suffix_line(line):
        # Skip the macro *definition* line — only rename call sites.
        # The definition uses its parameter names as mere identifiers;
        # renaming them without updating the body would break the macro.
        if '#define LAPACK_GLOBAL_SUFFIX(' in line:
            return line
        return re.sub(
            r'LAPACK_GLOBAL_SUFFIX\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)',
            _rename_global_suffix,
            line,
        )

    content = '\n'.join(_rename_global_suffix_line(l) for l in content.split('\n'))
    return content

def apply_lapack_export_renames(content, api_prefix_renames):
    """Rename Fortran symbols inside LAPACK_EXPORT_* macros and bare call sites.

    FLAME.h declares un-prefixed Fortran LAPACK symbols via:
        #define LAPACK_EXPORT_<name>  F77_FUNC( <name> , <NAME> )
    Those symbols are external references that objcopy never renames, so
    they conflict with other vendors' LAPACK headers on "conflicting
    types" errors when both are included in the same translation unit.
    libflame_interface.hh also calls the same names directly as bare Fortran
    call sites, so both forms must be patched.
    """
    if not api_prefix_renames:
        return content

    wrapper_prefix = infer_wrapper_prefix(
        api_prefix_renames,
        preferred_families=('cblas_', 'lapacke_', 'blis_', 'bli_'),
    )
    if not wrapper_prefix:
        return content

    upper_prefix = wrapper_prefix.upper()

    _lapack_export_def_re = re.compile(
        r'^(\s*#\s*define\s+LAPACK_EXPORT_\S+\s+F77_FUNC\(\s*)'
        r'([A-Za-z_][A-Za-z0-9_]*)'
        r'(\s*,\s*)'
        r'([A-Za-z_][A-Za-z0-9_]*)'
        r'(\s*\))',
        re.MULTILINE,
    )

    def _rename_export_def(m):
        low_name  = m.group(2)
        up_name   = m.group(4)
        if not low_name.startswith(wrapper_prefix):
            low_name = wrapper_prefix + low_name
        if not up_name.startswith(upper_prefix):
            up_name = upper_prefix + up_name
        return m.group(1) + low_name + m.group(3) + up_name + m.group(5)

    content = _lapack_export_def_re.sub(_rename_export_def, content)

    # Bare call sites in libflame_interface.hh: *(rfsx|svxx)_ and
    # *la_*rfsx_extended_ in the four type-letters {s,d,c,z}.
    _lapack_extended_call_re = re.compile(
        r'(?<![A-Za-z0-9_])'
        r'([sdcz](?:gb|ge|he|po|sy)(?:rfsx|svxx)_'
        r'|[sdcz]la_(?:gb|ge|he|po|sy)rfsx_extended_)'
        r'(?=\s*\()'
    )
    def _rename_extended_call(m):
        name = m.group(1)
        if name.startswith(wrapper_prefix):
            return name
        return wrapper_prefix + name
    content = _lapack_extended_call_re.sub(_rename_extended_call, content)

    return content


def apply_cblas_enum_renames(content, prefix):
    """Rename CBLAS enum type names, enumerator constants, and LAPACK macros.

    CBLAS enum types (CBLAS_ORDER, CBLAS_TRANSPOSE, CBLAS_UPLO,
    CBLAS_DIAG, CBLAS_SIDE), their enumerator constants (CblasRowMajor, etc.),
    and LAPACK integer macros (LAPACK_ROW_MAJOR, LAPACK_COL_MAJOR) are
    identical across BLAS/LAPACK vendors.  Since they are compile-time
    constructs (not binary symbols) they are never renamed by the
    object-copy pass.

    This function renames them in the copied renamed headers so that
    including both AOCL renamed headers and another vendor's BLAS/LAPACK
    headers in the same translation unit does not cause redefinition errors.
    """
    if not prefix:
        return content

    # Derive the uppercase and mixed-case prefix variants
    # e.g. prefix="mylib_" -> upper="MYLIB_", mixed="Mylib_"
    upper_prefix = prefix.upper()
    # For mixed-case enumerators like CblasRowMajor, we use UPPER prefix
    enum_prefix = upper_prefix

    # CBLAS enum type names  (e.g. CBLAS_ORDER -> <prefix>_CBLAS_ORDER)
    cblas_enum_types = [
        'CBLAS_ORDER', 'CBLAS_LAYOUT', 'CBLAS_TRANSPOSE',
        'CBLAS_UPLO', 'CBLAS_DIAG', 'CBLAS_SIDE',
        'CBLAS_IDENTIFIER', 'CBLAS_STORAGE',
    ]
    for name in cblas_enum_types:
        new_name = enum_prefix + name
        content = re.sub(rf'(?<![A-Za-z0-9_]){re.escape(name)}(?![A-Za-z0-9_])', new_name, content)

    # CBLAS enumerator constants (mixed-case, e.g. CblasRowMajor -> <prefix>CblasRowMajor)
    cblas_enumerators = [
        'CblasRowMajor', 'CblasColMajor',
        'CblasNoTrans', 'CblasTrans', 'CblasConjTrans',
        'CblasUpper', 'CblasLower',
        'CblasNonUnit', 'CblasUnit',
        'CblasLeft', 'CblasRight',
        'CblasForward', 'CblasBackward',
        'CblasConjNoTrans',
        'CblasPacked',
        'CblasAMatrix', 'CblasBMatrix',
    ]
    for name in cblas_enumerators:
        new_name = enum_prefix + name
        content = re.sub(rf'(?<![A-Za-z0-9_]){re.escape(name)}(?![A-Za-z0-9_])', new_name, content)

    # LAPACK integer macros (LAPACK_ROW_MAJOR, LAPACK_COL_MAJOR)
    lapack_layout_macros = ['LAPACK_ROW_MAJOR', 'LAPACK_COL_MAJOR']
    for name in lapack_layout_macros:
        new_name = enum_prefix + name
        content = re.sub(rf'(?<![A-Za-z0-9_]){re.escape(name)}(?![A-Za-z0-9_])', new_name, content)

    return content

def apply_openrng_macro_renames(content, prefix):
    """Prefix OpenRNG VSL_* macros and the VSLBRngProperties typedef.

    Avoids collisions when the renamed openrng.h is included alongside
    another vendor's VSL-style headers (shared VSL_* macro names with
    differing values; conflicting VSLBRngProperties typedef tags).
    """
    if not prefix:
        return content

    upper_prefix = prefix.upper()

    # VSL_* macros that may be defined by other vendors' VSL headers too.
    openrng_macros = [
        # BRNG IDs.
        'VSL_BRNG_ARS5', 'VSL_BRNG_DABSTRACT', 'VSL_BRNG_IABSTRACT',
        'VSL_BRNG_MCG31', 'VSL_BRNG_MCG59', 'VSL_BRNG_MRG32K3A',
        'VSL_BRNG_MT19937', 'VSL_BRNG_MT2203', 'VSL_BRNG_NIEDERR',
        'VSL_BRNG_NONDETERM', 'VSL_BRNG_PHILOX4X32X10', 'VSL_BRNG_R250',
        'VSL_BRNG_SABSTRACT', 'VSL_BRNG_SFMT19937', 'VSL_BRNG_SOBOL',
        'VSL_BRNG_WH',
        # Status / error codes.
        'VSL_STATUS_OK', 'VSL_ERROR_OK',
        'VSL_ERROR_BADARGS', 'VSL_ERROR_FEATURE_NOT_IMPLEMENTED',
        'VSL_ERROR_MEM_FAILURE', 'VSL_ERROR_NULL_PTR',
        'VSL_RNG_ERROR_BAD_MEM_FORMAT', 'VSL_RNG_ERROR_BAD_STREAM',
        'VSL_RNG_ERROR_BRNG_NOT_SUPPORTED', 'VSL_RNG_ERROR_BRNGS_INCOMPATIBLE',
        'VSL_RNG_ERROR_FILE_CLOSE', 'VSL_RNG_ERROR_FILE_OPEN',
        'VSL_RNG_ERROR_FILE_READ', 'VSL_RNG_ERROR_FILE_WRITE',
        'VSL_RNG_ERROR_INVALID_BRNG_INDEX',
        'VSL_RNG_ERROR_LEAPFROG_UNSUPPORTED',
        'VSL_RNG_ERROR_NONDETERM_NOT_SUPPORTED',
        'VSL_RNG_ERROR_SKIPAHEADEX_UNSUPPORTED',
        'VSL_RNG_ERROR_SKIPAHEAD_UNSUPPORTED',
        'VSL_DISTR_MULTINOMIAL_BAD_PROBABILITY_ARRAY',
        # Storage / QRNG / user-stream macros.
        'VSL_MATRIX_STORAGE_DIAGONAL', 'VSL_MATRIX_STORAGE_FULL',
        'VSL_MATRIX_STORAGE_PACKED',
        'VSL_QRNG_OVERRIDE_1ST_DIM_INIT',
        'VSL_USER_DIRECTION_NUMBERS', 'VSL_USER_INIT_DIRECTION_NUMBERS',
        'VSL_USER_PRIMITIVE_POLYMS', 'VSL_USER_QRNG_INITIAL_VALUES',
        # Distribution method selectors.
        'VSL_RNG_METHOD_BERNOULLI_ICDF', 'VSL_RNG_METHOD_BINOMIAL_BTPE',
        'VSL_RNG_METHOD_CAUCHY_ICDF',
        'VSL_RNG_METHOD_EXPONENTIAL_ICDF',
        'VSL_RNG_METHOD_EXPONENTIAL_ICDF_ACCURATE',
        'VSL_RNG_METHOD_GAMMA_GNORM', 'VSL_RNG_METHOD_GAMMA_GNORM_ACCURATE',
        'VSL_RNG_METHOD_GAUSSIAN_BOXMULLER',
        'VSL_RNG_METHOD_GAUSSIAN_BOXMULLER2',
        'VSL_RNG_METHOD_GAUSSIAN_ICDF',
        'VSL_RNG_METHOD_GAUSSIANMV_BOXMULLER',
        'VSL_RNG_METHOD_GAUSSIANMV_BOXMULLER2',
        'VSL_RNG_METHOD_GAUSSIANMV_ICDF',
        'VSL_RNG_METHOD_GEOMETRIC_ICDF',
        'VSL_RNG_METHOD_GUMBEL_ICDF', 'VSL_RNG_METHOD_LAPLACE_ICDF',
        'VSL_RNG_METHOD_LOGNORMAL_BOXMULLER2',
        'VSL_RNG_METHOD_LOGNORMAL_ICDF',
        'VSL_RNG_METHOD_MULTINOMIAL_MULTPOISSON',
        'VSL_RNG_METHOD_POISSON_POISNORM',
        'VSL_RNG_METHOD_POISSON_PTPE',
        'VSL_RNG_METHOD_RAYLEIGH_ICDF',
        'VSL_RNG_METHOD_RAYLEIGH_ICDF_ACCURATE',
        'VSL_RNG_METHOD_UNIFORM_STD',
        'VSL_RNG_METHOD_UNIFORM_STD_ACCURATE',
        'VSL_RNG_METHOD_UNIFORMBITS_STD',
        'VSL_RNG_METHOD_UNIFORMBITS32_STD',
        'VSL_RNG_METHOD_UNIFORMBITS64_STD',
        'VSL_RNG_METHOD_WEIBULL_ICDF',
        'VSL_RNG_METHOD_WEIBULL_ICDF_ACCURATE',
    ]
    for name in openrng_macros:
        new_name = upper_prefix + name
        content = re.sub(
            rf'(?<![A-Za-z0-9_]){re.escape(name)}(?![A-Za-z0-9_])',
            new_name,
            content,
        )

    # Typedef names that may collide with other vendors' VSL-style headers.
    # The leading-underscore tag form is matched separately to preserve the
    # underscore: `_VSLBRngProperties` -> `_AOCL_VSLBRngProperties`.
    openrng_typedefs = ['VSLBRngProperties', 'VSLStreamStatePtr']
    for name in openrng_typedefs:
        # Standalone occurrence (no leading underscore).
        content = re.sub(
            rf'(?<![A-Za-z0-9_]){re.escape(name)}(?![A-Za-z0-9_])',
            upper_prefix + name,
            content,
        )
        # Leading-underscore tag form: keep the underscore at the front.
        content = re.sub(
            rf'(?<![A-Za-z0-9_])_{re.escape(name)}(?![A-Za-z0-9_])',
            '_' + upper_prefix + name,
            content,
        )

    return content

# ---------------------------------------------------------------------------
# AOCL-vs-AOCL coexistence: prefix the public enum/type identifiers of the
# AOCL-specific libraries (DA, Sparse, Compression, Crypto, LibM). These do NOT
# collide with MKL (so apply_cblas_enum_renames skips them) but ARE identical
# between two renamed AOCL builds, so two renamed versions cannot be included in
# one translation unit without prefixing them.
# ---------------------------------------------------------------------------
_AOCL_LIB_HEADER_MARKERS = (
    'aoclda', 'aocl_da', 'aoclsparse', 'aocl_compression',
    'amdlibm', 'aoclutils', 'aocl_libmem', 'libmem',
)
_TYPE_ENUM_NEVER = {
    'int', 'char', 'short', 'long', 'float', 'double', 'void', 'unsigned',
    'signed', 'const', 'volatile', 'static', 'extern', 'struct', 'union',
    'enum', 'typedef', 'return', 'sizeof', 'size_t', 'ssize_t', 'ptrdiff_t',
    'intptr_t', 'uintptr_t', 'wchar_t', 'bool', '_Bool', '_Complex', 'FILE',
    'va_list', 'true', 'false', 'NULL', 'nullptr',
    'int8_t', 'int16_t', 'int32_t', 'int64_t',
    'uint8_t', 'uint16_t', 'uint32_t', 'uint64_t',
}
# Short/generic lowercase words that could appear in prose/comments or as common
# identifiers; never prefix these even if they show up as bare enum constants.
_TYPE_ENUM_COMMON_WORDS = {
    'on', 'off', 'yes', 'no', 'none', 'all', 'any', 'min', 'max', 'low', 'high',
    'end', 'len', 'size', 'data', 'type', 'mode', 'base', 'zero', 'one', 'two',
    'in', 'out', 'up', 'down', 'left', 'right', 'top', 'get', 'set', 'add', 'new',
}

def _keep_type_enum_name(n):
    """Only prefix identifiers distinctive enough to be real library types/enums:
    contains '_', or an uppercase acronym (LZ4/ZLIB), or a longer lowercase word.
    Skips std types and short/common words to avoid polluting prose/comments."""
    if (not n or n in _TYPE_ENUM_NEVER or n in _TYPE_ENUM_COMMON_WORDS
            or n in _STRUCT_ATTR_KW
            or n.startswith('__') or len(n) <= 1
            or re.match(r'^_[A-Z]', n)   # reserved impl types: _Fcomplex/_Complex/_Bool
            or not re.match(r'^[A-Za-z_]\w*$', n)):
        return False
    return ('_' in n) or (n.isupper() and len(n) >= 2) or (len(n) >= 5)

def _is_aocl_lib_header(header_path):
    """True for AOCL-specific library public headers (not the MKL-coexist ones)."""
    p = header_path.replace('\\', '/').lower()
    base = os.path.basename(p)
    if base in ('cblas.h', 'cblas.hh', 'lapacke.h', 'lapack.h', 'openrng.h'):
        return False
    if '/alcp/' in p or base.startswith('alcp') or base.startswith('rng'):
        return True
    return any(m in base for m in _AOCL_LIB_HEADER_MARKERS)

# Attribute/qualifier keywords that may sit between a struct/union keyword and
# the actual tag name (e.g. `struct alignas(2*sizeof(double)) tag {`).
_STRUCT_ATTR_KW = {'alignas', '_Alignas', '__attribute__', '__declspec',
                   'packed', 'aligned'}

def _strip_c_comments(s):
    """Remove /* */ and // comments so braces/identifiers inside doc comments
    (e.g. LaTeX \\text{tril}) don't break enum/struct body scanning or get
    mis-collected as enum constants. Used ONLY for name collection."""
    s = re.sub(r'/\*.*?\*/', ' ', s, flags=re.S)
    s = re.sub(r'//[^\n]*', ' ', s)
    return s

def _last_tag_ident(pre):
    """Given the text between a struct/union keyword and its '{', return the
    tag identifier (last identifier that is not an attribute keyword), or None
    for an anonymous struct. Parenthesised attribute args are dropped first."""
    pre = re.sub(r'\([^()]*\)', ' ', pre)
    pre = re.sub(r'\([^()]*\)', ' ', pre)  # 2nd pass for nested ()
    for tid in reversed(re.findall(r'[A-Za-z_]\w*', pre)):
        if tid not in _STRUCT_ATTR_KW:
            return tid
    return None

def _collect_type_enum_names_from_content(content):
    """Collect enum tags, enum constants, typedef names and struct/union tags.
    Runs on a comment-stripped copy so doc-comment braces (LaTeX) and trailing
    enumerators without a comma are handled; tolerates alignas()/attributes."""
    names = set()
    scan = _strip_c_comments(content)
    # enum <tag>? { constants } <name>?  (comment-free -> body has no braces)
    for m in re.finditer(r'\benum\b\s*(\w+)?\s*\{([^{}]*)\}\s*(\w+)?', scan, re.S):
        if m.group(1):
            names.add(m.group(1))
        if m.group(3):
            names.add(m.group(3))
        for cm in re.finditer(r'([A-Za-z_]\w*)\s*(?:=[^,]*)?(?:,|\Z)', m.group(2)):
            names.add(cm.group(1))
    # typedef struct/union [attrs] [tag]? { members (<=1 nesting) } Name;
    for m in re.finditer(
            r'\btypedef\s+(?:struct|union)\b([^{;]*?)\{(?:[^{}]|\{[^{}]*\})*\}\s*(\w+)\s*;',
            scan, re.S):
        tag = _last_tag_ident(m.group(1))
        if tag:
            names.add(tag)
        names.add(m.group(2))
    # typedef <...no braces...> Name;  (simple / struct-tag typedefs)
    for m in re.finditer(r'\btypedef\s+[^;{}]+?\b([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*;', scan):
        names.add(m.group(1))
    # struct/union tag references (defs, forward decls, usages), attr-tolerant.
    scan_np = re.sub(r'\([^()]*\)', ' ', scan)
    scan_np = re.sub(r'\([^()]*\)', ' ', scan_np)
    for m in re.finditer(
            r'\b(?:struct|union)\s+(?:(?:alignas|_Alignas|__attribute__|__declspec|packed|aligned)\s+)*([A-Za-z_]\w*)',
            scan_np):
        names.add(m.group(1))
    return names

def collect_aocl_lib_type_enum_names(header_files):
    """Scan all AOCL-specific library headers up-front so enum/type usages stay
    consistent across headers (a type declared in *_types.h is used elsewhere)."""
    names = set()
    for hp in header_files:
        if not _is_aocl_lib_header(hp):
            continue
        try:
            with open(hp, 'r', encoding='utf-8') as f:
                c = f.read()
        except Exception:
            try:
                with open(hp, 'r', encoding='latin-1') as f:
                    c = f.read()
            except Exception:
                continue
        names |= _collect_type_enum_names_from_content(c)
    return {n for n in names if _keep_type_enum_name(n)}

def apply_aocl_lib_type_enum_renames(content, prefix, names):
    """Prefix collected AOCL-lib enum/type identifiers (whole-word) so two
    renamed AOCL builds don't clash on their otherwise-unprefixed enums/types."""
    if not prefix or not names:
        return content
    present = [n for n in names if n in content and not n.startswith(prefix)]
    for n in sorted(present, key=len, reverse=True):
        content = re.sub(rf'(?<![A-Za-z0-9_]){re.escape(n)}(?![A-Za-z0-9_])',
                         prefix + n, content)
    return content

def apply_api_prefix_renames(content, api_prefix_renames):
    """Apply identifier-level API family prefix rewrites in headers.

    Rewrites identifiers that begin with known API family stems, such as:
      cblas_*  -> aocl_52_cblas_*
      lapacke_* -> aocl_52_lapacke_*
    """
    if not api_prefix_renames:
        return content

    updated = content
    for old_prefix, new_prefix in sorted(api_prefix_renames.items(), key=lambda x: len(x[0]), reverse=True):
        if old_prefix == new_prefix:
            continue

        # Restrict to function-like identifiers only, i.e. tokens that are
        # eventually followed by '(' (possibly with spaces in-between).
        # Also skip callback/type-like names (e.g., da_resfun_t_d) to avoid
        # breaking typedef-based API contracts.
        pattern = re.compile(
            rf'(?<![A-Za-z0-9_])({re.escape(old_prefix)}[A-Za-z0-9_]*)(?=\s*\()'
        )

        def _rewrite_if_function_name(match):
            token = match.group(1)
            # Callback/type-like identifiers should not be rewritten.
            # Example: da_resfun_t_d, da_reshes_t_s
            if '_t_' in token or token.endswith('_t'):
                return token
            return token.replace(old_prefix, new_prefix, 1)

        updated = pattern.sub(_rewrite_if_function_name, updated)

    return updated

def apply_cpp_wrapper_identifier_renames(content, header_path, api_prefix_renames):
    """Rename unprefixed C++ wrapper function identifiers in selected headers.

    Scope-limited fallback for wrapper façades that don't appear as concrete ELF
    symbols (e.g., rotg/potrf overload wrappers in blis/libflame headers).
    """
    if not header_path:
        return content

    basename = os.path.basename(header_path)
    if basename not in {'blis.hh', 'libflame_interface.hh'}:
        return content

    # Keep wrapper fallback tied to BLAS/LAPACK-related API mappings only.
    wrapper_prefix = infer_wrapper_prefix(
        api_prefix_renames,
        preferred_families=('cblas_', 'lapacke_', 'blis_', 'bli_'),
    )
    if not wrapper_prefix:
        return content

    updated = content

    # Collect candidate wrapper function names from declarations/definitions.
    decl_pattern = re.compile(
        r'^\s*(?:inline\s+|static\s+|constexpr\s+|extern\s+)*'
        r'[A-Za-z_][A-Za-z0-9_:<>,\s\*&]*\s+'
        r'([A-Za-z_][A-Za-z0-9_]*)\s*\(',
        re.MULTILINE
    )

    reserved = {
        'if', 'for', 'while', 'switch', 'return', 'sizeof', 'catch'
    }

    candidates = {
        m.group(1)
        for m in decl_pattern.finditer(updated)
        if m.group(1) not in reserved and not m.group(1).startswith(wrapper_prefix)
    }

    for name in sorted(candidates, key=len, reverse=True):
        updated = re.sub(
            rf'(?<![A-Za-z0-9_]){re.escape(name)}(?=\s*\()',
            f'{wrapper_prefix}{name}',
            updated
        )

    return updated

def is_std_mangled_symbol(symbol):
    """Detect mangled symbols rooted in std:: namespace and skip them.

    Covers common Itanium forms:
    - _ZSt...           (abbreviated std::)
    - _ZNSt... / _ZNKSt... etc. (nested std::)
    """
    if not is_itanium_mangled_symbol(symbol):
        return False

    if symbol.startswith('_ZSt'):
        return True

    # Special-name std::* forms (typeinfo/vtable/typeinfo-name/etc.).
    if symbol.startswith(('_ZTSSt', '_ZTISt', '_ZTVSt', '_ZTTSt', '_ZTCSt')):
        return True

    n_index = _find_nested_name_index(symbol)
    if _is_std_at_nested_name(symbol, n_index):
        return True

    return False

def is_reserved_impl_mangled_symbol(symbol):
    """Detect mangled symbols rooted in a reserved C++ implementation namespace
    (libstdc++/libc++/ABI internals such as __gnu_cxx, __cxxabiv1, __gnu_debug).

    The C++ standard reserves identifiers beginning with a double underscore for
    the implementation, so a top-level namespace like __gnu_cxx belongs to the
    standard library, NOT to AOCL. Its symbols (e.g. weak __gnu_cxx::__stoa<>
    instantiations emitted from libstdc++ headers) must never be renamed - doing
    so would create a private av1___gnu_cxx copy divergent from the real STL.
    """
    if not is_itanium_mangled_symbol(symbol):
        return False
    comp = _extract_first_nested_component(symbol)
    return bool(comp) and comp.startswith('__')

_TYPE_COMPONENT_REGEX_CACHE = {}

def _get_type_component_regex(type_names):
    """Build (and cache) a regex matching Itanium source-name components
    (``<len><name>``) for AOCL type tags that must be prefixed inside mangled C++
    symbols.

    Only names >= 8 chars are used: AOCL enum/struct/union tags are long
    (``aoclsparse_status_``, ``_aoclsparse_matrix``), whereas short typedef-to-
    builtin names (``da_int``, ``aoclsparse_int``) resolve to Itanium builtin
    type codes and never appear as source-names -- excluding them avoids
    accidental substring matches inside unrelated identifiers.
    """
    key = frozenset(type_names) if type_names else frozenset()
    cached = _TYPE_COMPONENT_REGEX_CACHE.get(key)
    if cached is not None:
        return cached
    names = sorted((n for n in key if len(n) >= 8), key=len, reverse=True)
    if not names:
        result = (None, {})
    else:
        lookup = {f'{len(n)}{n}': n for n in names}
        # (?<![0-9]) ensures the length digits form a complete count (not the tail
        # of a larger number). Every alternative is length-prefixed so matches are
        # exact, non-overlapping source-name components.
        pattern = re.compile(r'(?<![0-9])(' + '|'.join(re.escape(t) for t in lookup) + r')')
        result = (pattern, lookup)
    _TYPE_COMPONENT_REGEX_CACHE[key] = result
    return result

def _prefix_mangled_type_components(symbol, prefix_token, type_names):
    """Prefix AOCL type tags that appear as ``<len><name>`` source-name
    components inside a mangled C++ symbol (the return / parameter types of
    template and overloaded functions), so the renamed binary symbol matches the
    renamed public header (whose enum/struct/typedef tags were prefixed).

    Each length prefix is recomputed for the prefixed name. Itanium substitution
    back-references (``S._``) are positional (indexes into the substitution
    table), so changing a component's text/length does not invalidate them.
    """
    pattern, lookup = _get_type_component_regex(type_names)
    if pattern is None:
        return symbol

    def _repl(m):
        name = lookup[m.group(1)]
        new_name = prefix_token + name
        return f'{len(new_name)}{new_name}'

    return pattern.sub(_repl, symbol)

def rename_mangled_symbol_with_namespace(symbol, prefix, type_names=None):
    """Rename an Itanium mangled symbol by injecting a namespace component.

    Example:
        _ZN3foo3barEv + AOCL_ -> _ZN8AOCL_foo3barEv
        _ZN3foo3barEv + aocl  -> _ZN7aoclfoo3barEv

    When ``type_names`` is supplied, embedded AOCL type tags (return/parameter
    types of C++ template & overload symbols) are also prefixed so the binary
    matches the renamed headers.
    """
    prefix_token = normalize_mangled_prefix_token(prefix)
    if not prefix_token:
        return symbol

    # Only mangled symbols are handled here.
    if not is_itanium_mangled_symbol(symbol):
        return symbol

    # Never rename std::* symbols.
    if is_std_mangled_symbol(symbol):
        return symbol

    # Never rename reserved implementation namespaces (__gnu_cxx, __cxxabiv1, ...).
    if is_reserved_impl_mangled_symbol(symbol):
        return symbol

    # Rename the primary nested-name (namespace / top-level function) component.
    n_index = _find_nested_name_index(symbol)
    if n_index is not None:
        symbol = _replace_first_nested_component(symbol, n_index, prefix_token)

    # Also prefix embedded AOCL type tags so C++ template/overload symbols match
    # the renamed public headers (where those tags were prefixed).
    if type_names:
        symbol = _prefix_mangled_type_components(symbol, prefix_token, type_names)

    return symbol

def should_rename_symbol(symbol, prefix="AOCL_", allowed_namespaces=None):
    """Check if a symbol should be renamed.
    
    Decides whether it's safe and useful to rename a symbol in ELF/Linux libraries.
    - Avoids C++ ABI/runtime artifacts (RTTI, vtables, guard vars, exceptions)
    - Optionally restricts to specific namespaces (recommended for C++ code)
    - Does NOT skip symbols that already contain the prefix (they will be renamed again)
    
    Args:
        symbol: Symbol name to check
        prefix: The prefix being added (not used for filtering, kept for compatibility)
        allowed_namespaces: Optional list of namespace patterns to allow (e.g., ['alcp::', '_ZN4alcp'])
    
    Note:
        Even if a symbol already contains the prefix (e.g., "AOCL_DGemm_"), it will still
        be renamed (e.g., "AOCL_AOCL_DGemm_"). The only protection is against renaming
        C++ ABI/system symbols and duplicate processing in the same session.
    """
    if not symbol or len(symbol) < 2:
        return False
    
    # Check against C++ ABI/runtime exclusion patterns
    for rx in ABI_EXCLUDES:
        if re.search(rx, symbol):
            return False

    # Never rename standard C/POSIX/math library symbols.
    # These can appear as weak (W) defined symbols in static libs due to inline
    # function emission, but they must retain their original names.
    if symbol in STDLIB_SYMBOL_EXCLUDES:
        return False

    # Never rename std:: APIs/symbols.
    if 'std::' in symbol or is_std_mangled_symbol(symbol):
        return False

    # Never rename reserved C++ implementation namespaces (__gnu_cxx, __cxxabiv1,
    # etc.) - these belong to libstdc++/libc++, not to AOCL.
    if is_reserved_impl_mangled_symbol(symbol):
        return False
    
    # If allowed_namespaces specified, only rename symbols from those namespaces
    # This is recommended for C++ libraries to avoid renaming STL or other dependencies
    if allowed_namespaces:
        if not any(ns in symbol for ns in allowed_namespaces):
            return False
    
    # NOTE: We do NOT check if the symbol already contains the prefix.
    # Symbols like "AOCL_DGemm_" will be renamed to "AOCL_AOCL_DGemm_" if needed.
    # Double-renaming protection is handled by deduplication in generate_mapping().
    
    return True

def get_intelligent_prefix(symbol_name, base_prefix):
    """
    Generate intelligent prefix based on symbol naming pattern.
    
    Args:
        symbol_name (str): The original symbol name
        base_prefix (str): The base prefix (e.g., "AOCL_" or "xyz")
    
    Returns:
        str: Appropriate prefix based on symbol case pattern
        
    Examples:
        get_intelligent_prefix("cblas_dgemm", "AOCL_") -> "aocl_"
        get_intelligent_prefix("DGEMM_", "AOCL_") -> "AOCL_"
        get_intelligent_prefix("cblas_dgemm", "xyz") -> "xyz"
        get_intelligent_prefix("DGEMM_", "xyz") -> "XYZ"
        get_intelligent_prefix("CblasNoTrans", "AOCL_") -> "AOCL_"
        get_intelligent_prefix("LAPACKE_dgetrf", "AOCL_") -> "AOCL_"
        get_intelligent_prefix("_example_api", "AOCL_") -> "_aocl_"
    
    Note:
        If base_prefix ends with underscore (e.g., "AOCL_"), it will be preserved in the output.
        If base_prefix does not end with underscore (e.g., "xyz"), no underscore is added.
    """
    if not symbol_name or len(symbol_name) == 0:
        return base_prefix
    
    # Preserve the FULL trailing-underscore run (so multi-underscore prefixes like
    # "myprefix__" stay intact, matching the C++ mangled rename and the test harness).
    clean_prefix = base_prefix.rstrip('_')
    trailing_underscores = base_prefix[len(clean_prefix):]
    
    # Analyze symbol naming patterns
    # Pattern 0: Starts with underscore - preserve ALL leading underscores
    # e.g., "_example_api" with "AOCL_" -> "_aocl_example_api"
    # e.g., "_example_api" with "xyz" -> "_xyzexample_api"
    if symbol_name.startswith('_'):
        # Count and preserve ALL leading underscores
        leading_underscores = len(symbol_name) - len(symbol_name.lstrip('_'))
        rest_of_symbol = symbol_name[leading_underscores:]
        
        if not rest_of_symbol:
            return base_prefix
        
        # Determine case pattern and apply prefix with appropriate case
        if rest_of_symbol.isupper():
            prefix = '_' * leading_underscores + clean_prefix.upper()
        elif rest_of_symbol.islower():
            prefix = '_' * leading_underscores + clean_prefix.lower()
        else:
            prefix = '_' * leading_underscores + clean_prefix.upper()
        
        # Preserve the caller's full trailing-underscore run.
        return prefix + trailing_underscores
    
    # Pattern 1: All uppercase (e.g., "DGEMM_", "SSYEV_")
    if symbol_name.isupper():
        prefix = clean_prefix.upper()
        return prefix + trailing_underscores
    
    # Pattern 2: All lowercase (e.g., "cblas_dgemm", "bli_dgemm")
    elif symbol_name.islower():
        prefix = clean_prefix.lower()
        return prefix + trailing_underscores
    
    # Pattern 3: Mixed-case (e.g., "CblasNoTrans", "LAPACKE_dgetrf", "getMaxValue")
    # Use uppercase prefix for all mixed-case symbols
    else:
        prefix = clean_prefix.upper()
        return prefix + trailing_underscores

def generate_mapping(symbols, base_prefix, map_file, type_names=None):
    """Generate mapping file for objcopy with intelligent case-aware prefixing."""
    mapping = {}
    seen_symbols = set()

    # Filter and deduplicate symbols
    valid_symbols = []
    for sym in symbols:
        if sym and sym not in seen_symbols and should_rename_symbol(sym, base_prefix):
            valid_symbols.append(sym)
            seen_symbols.add(sym)
    
    print(f"Total symbols found: {len(symbols)}")
    print(f"Symbols after filtering: {len(valid_symbols)}")
    

    with open(map_file, 'w') as f:
        for sym in valid_symbols:
            # C++ mangled names need namespace-aware rewriting, not textual prefixing.
            if is_itanium_mangled_symbol(sym):
                new_name = rename_mangled_symbol_with_namespace(sym, base_prefix, type_names=type_names)
                intelligent_prefix = '<mangled-namespace>'
            else:
                # Get intelligent prefix based on symbol case pattern
                intelligent_prefix = get_intelligent_prefix(sym, base_prefix)

                # For symbols with leading underscores, prefix already includes them
                # So we only append the rest of the symbol (without leading underscores)
                if sym.startswith('_'):
                    leading_count = len(sym) - len(sym.lstrip('_'))
                    new_name = f"{intelligent_prefix}{sym[leading_count:]}"
                else:
                    new_name = f"{intelligent_prefix}{sym}"

            # Skip no-op mappings to keep map clean and objcopy stable.
            if new_name == sym:
                continue

            f.write(f"{sym} {new_name}\n")
            mapping[sym] = new_name
    
    return mapping

def get_symbols_linux_static(lib_file):
    """Extract symbols using nm on Linux (for static libraries)."""
    result = subprocess.run(['nm', '--no-sort', lib_file], 
                          capture_output=True, text=True)
    if result.returncode != 0:
        result = subprocess.run(['nm', '--defined-only', lib_file], capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(f"nm failed: {result.stderr}")
    
    symbols = []
    for line in result.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) >= 3:
            symbol_type = parts[1]
            symbol_name = parts[2]
            
            # Include both global and local defined symbols
            # UPPERCASE: T=global text, D=global data, R=global read-only, B=global BSS, W=weak, V=weak object
            # lowercase: t=local text, d=local data, r=local read-only, b=local BSS, w=weak, v=weak object
            # u=unique-global (GCC guard variables for function-local statics, e.g. _ZGVZN...)
            # Exclude 'U' (undefined, external references like libc functions)
            if symbol_type in ['T', 'D', 'R', 'B', 'W', 'V', 't', 'd', 'r', 'b', 'w', 'v', 'u']:
                symbols.append(symbol_name)
    
    return symbols

def get_symbols_linux_shared(lib_file):
    """Extract ONLY exported/dynamic symbols from shared library (.so) using nm -D."""
    result = subprocess.run(['nm', '-D', '--defined-only', '--no-sort', lib_file], 
                          capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"nm -D failed: {result.stderr}")
    
    symbols = []
    for line in result.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) >= 3:
            symbol_type = parts[1]
            symbol_name = parts[2]
            
            # For shared libraries, only include exported symbols
            # T=text, D=data, R=read-only data, B=BSS, W=weak, V=weak object
            # These are the PUBLIC API symbols that external code can use
            if symbol_type in ['T', 'D', 'R', 'B', 'W', 'V']:
                symbols.append(symbol_name)
    
    return symbols

def rename_shared_library_objcopy(lib_file, prefix, map_file, symbol_mapping):
    """Rename symbols in shared library (.so) using objcopy.
    
    For shared libraries, we can directly use objcopy without extracting anything.
    """
    print(f"Processing shared library: {lib_file}")
    
    # Create renamed directory structure
    lib_dir = os.path.dirname(lib_file)
    renamed_dir = os.path.join(lib_dir, '..', 'renamed', 'lib')
    os.makedirs(renamed_dir, exist_ok=True)
    renamed_lib = os.path.join(renamed_dir, os.path.basename(lib_file))
    
    # Copy original to renamed location
    print(f"Creating renamed library at: {renamed_dir}")
    shutil.copy2(lib_file, renamed_lib)
    
    # Apply objcopy renaming on the renamed copy
    print(f"Renaming {len(symbol_mapping)} symbols...")
    
    try:
        result = subprocess.run(['objcopy', f'--redefine-syms={map_file}', renamed_lib], 
                              capture_output=True, text=True, timeout=600)
        
        if result.returncode != 0:
            print(f"Error: objcopy failed: {result.stderr}")
            return False
        
        print(f"✓ Symbol renaming completed!")
        return True
        
    except Exception as e:
        print(f"Error during symbol renaming: {e}")
        return False

def rename_static_library_objcopy(lib_file, prefix, map_file, symbol_mapping, create_so=False, so_libs=None, compiler='gcc', linker_flags=None):
    """Rename symbols in static library using objcopy.
    
    Renames all symbols (both global and local) in the static library.
    """
    print(f"Processing static library: {lib_file}")
    
    # Get file size for progress indication
    file_size_mb = os.path.getsize(lib_file) / (1024 * 1024)
    
    if not symbol_mapping:
        print(f"No symbols to rename")
        return False
    
    print(f"Renaming all symbols: {len(symbol_mapping)} symbols (global + local)")
    
    # Create renamed directory structure
    lib_dir = os.path.dirname(lib_file)
    renamed_dir = os.path.join(lib_dir, '..', 'renamed', 'lib')
    os.makedirs(renamed_dir, exist_ok=True)
    renamed_lib = os.path.join(renamed_dir, os.path.basename(lib_file))
    
    # Copy original to renamed location
    shutil.copy2(lib_file, renamed_lib)
    
    # Apply objcopy renaming directly on the .a file
    print(f"Renaming {len(symbol_mapping)} symbols...")
    
    # Calculate timeout based on file size with reasonable range
    # Formula: 30 minutes minimum + 1 minute per 2MB, capped at 60 minutes
    timeout_minutes = min(60, max(30, int(file_size_mb / 2)))
    start_time = time.time()
    result = subprocess.run(['objcopy', f'--redefine-syms={map_file}', renamed_lib], 
                          capture_output=True, text=True, timeout=timeout_minutes*60)
    elapsed = time.time() - start_time
    
    if result.returncode != 0:
        print(f"objcopy failed: {result.stderr}")
        return False
    
    print(f"✓ Symbol renaming completed in {elapsed:.1f} seconds")
    
    # Handle shared library if requested
    if create_so:
        original_so = lib_file.replace('.a', '.so')
        if os.path.exists(original_so):
            # If original .so exists, we need to create a renamed .so from the renamed .a
            print(f"\nCreating renamed shared library from renamed static library...")
            renamed_so = os.path.join(renamed_dir, os.path.basename(original_so))
            
            # Use create_shared_library to properly create .so with renamed symbols
            result_so = create_shared_library(
                static_lib=renamed_lib,
                map_file=map_file,
                output_so=renamed_so,
                additional_libs=so_libs,
                compiler=compiler,
                linker_flags=linker_flags
            )
            
            if result_so:
                print(f"✓ Created renamed shared library: {renamed_so}")
            else:
                print(f"Failed to create renamed shared library")
                print(f"Falling back to copying original .so (symbols will not be renamed)")
                shutil.copy2(original_so, renamed_so)
        else:
            print(f"No corresponding .so file found at: {original_so}")
            print(f"Skipping shared library creation")
    
    return True

def create_shared_library(static_lib, map_file=None, output_so=None, additional_libs=None, compiler='gcc', linker_flags=None):
    """Create a shared library from a renamed static library using --whole-archive method.
    
    This method uses gcc -Wl,--whole-archive to create a .so directly from the .a file,
    preserving all renamed symbols. This is simpler and more reliable than extracting
    and relinking object files.
    
    Args:
        static_lib: Path to the renamed static library (.a file)
        map_file: (Optional, kept for compatibility but not used)
        output_so: Output shared library name (optional, auto-generated if not provided)
        additional_libs: List of additional libraries to link (e.g., ['-lgfortran', '-lm'])
        compiler: Compiler to use (default: 'gcc', can be set from CMAKE_C_COMPILER)
        linker_flags: Linker flags to use (from CMAKE_SHARED_LINKER_FLAGS)
    
    Returns:
        Path to created shared library or None if failed
    """
    if not os.path.exists(static_lib):
        print(f"Error: Static library not found: {static_lib}")
        return None
    
    # Auto-generate output .so name if not provided
    if output_so is None:
        base_name = os.path.splitext(os.path.basename(static_lib))[0]
        # Remove 'lib' prefix if present
        if base_name.startswith('lib'):
            base_name = base_name[3:]
        lib_dir = os.path.dirname(static_lib)
        output_so = os.path.join(lib_dir, f"lib{base_name}.so")
    
    # Build compiler command to create shared library using --whole-archive
    # This method preserves the renamed symbols from the .a file
    cmd = [compiler, '-shared', '-o', output_so,
           '-Wl,--whole-archive', static_lib, '-Wl,--no-whole-archive']
    
    # Add additional libraries if provided
    if additional_libs:
        cmd.extend(additional_libs)
    
    # Add linker flags if provided
    if linker_flags:
        # Split linker flags string into list if it's a string
        if isinstance(linker_flags, str):
            flags_list = linker_flags.split()
        else:
            flags_list = linker_flags
        if flags_list:  # Only add if not empty
            cmd.extend(flags_list)
    
    # Execute compiler command
    result = subprocess.run(cmd, capture_output=True, text=True)
    
    if result.returncode != 0:
        print(f"\nError creating shared library:")
        print(f"  {result.stderr}")
        
        # Check for specific known issues
        if 'undefined reference' in result.stderr:
            print(f"\n  Common cause: Missing dependencies")
            print(f"  Possible solutions:")
            print(f"    1. Add required libraries with --so-libs")
            print(f"    2. Some symbols may need to be resolved at runtime")
        
        return None
    
    if os.path.exists(output_so):
        print(f"✓ Successfully created shared library: {output_so}")
        
        # Verify the shared library has symbols
        result = subprocess.run(['nm', '-D', output_so], capture_output=True, text=True)
        if result.returncode == 0:
            symbol_count = len([line for line in result.stdout.splitlines() if line.strip()])
            print(f"  Exported symbols: {symbol_count}")
        
        return output_so
    else:
        print(f"Error: Shared library was not created")
        return None

def rename_symbols(lib_file, prefix, header_paths=None, create_so=False, so_libs=None, compiler='gcc', linker_flags=None, type_names=None):
    """Main function to rename symbols in libraries.
    
    Args:
        lib_file: Path to the library file
        prefix: Prefix to add to symbols
        header_paths: Paths to header files to update
        create_so: If True, create a shared library from the renamed static library
        so_libs: Additional libraries needed when creating shared library (e.g., ['-lgfortran', '-lm'])
    """
    os_type = platform.system()
    # Use consistent map file name
    map_file = f"{os.path.splitext(os.path.basename(lib_file))[0]}_map.txt"

    if os_type == 'Linux':
        # Determine library type
        file_result = subprocess.run(['file', lib_file], capture_output=True, text=True)
        file_type = file_result.stdout.lower()
        is_static_lib = 'ar archive' in file_type or lib_file.endswith('.a')
        is_shared_lib = 'shared object' in file_type or lib_file.endswith('.so')
        
        if not (is_static_lib or is_shared_lib):
            print(f"Error: Only static (.a) or shared (.so) libraries are supported")
            print(f"Library type detected: {file_type}")
            return {}
        
        print(f"Processing: {lib_file}")
        
        # For .so files, we need to get symbols from the corresponding .a file
        # This ensures we rename all symbols consistently between .a and .so
        if is_shared_lib:
            # Find corresponding .a file to extract complete symbol list
            a_file = lib_file.replace('.so', '.a')
            if os.path.exists(a_file):
                print(f"  Extracting symbols from corresponding .a file: {a_file}")
                symbols = get_symbols_linux_static(a_file)
            else:
                print(f"  Warning: No corresponding .a file found, using .so symbols only")
                symbols = get_symbols_linux_shared(lib_file)
        else:
            # For .a files, get all defined symbols (global + local)
            symbols = get_symbols_linux_static(lib_file)
        
        symbol_mapping = generate_mapping(symbols, prefix, map_file, type_names=type_names)
        
        if not symbol_mapping:
            print(f"No symbols to rename in {lib_file}")
            return {}
        
        # Use appropriate renaming method based on library type
        if is_shared_lib:
            # For shared libraries, we need to create a NEW .so from the renamed .a
            # Find the corresponding renamed .a file
            a_file = lib_file.replace('.so', '.a')
            lib_dir = os.path.dirname(lib_file)
            renamed_dir = os.path.join(lib_dir, '..', 'renamed', 'lib')
            renamed_a = os.path.join(renamed_dir, os.path.basename(a_file))
            renamed_so = os.path.join(renamed_dir, os.path.basename(lib_file))
            
            if os.path.exists(renamed_a):
                print(f"  Creating renamed .so from renamed .a: {renamed_a}")
                # Create the .so from the renamed .a file
                result = create_shared_library(
                    static_lib=renamed_a,
                    map_file=map_file,
                    output_so=renamed_so,
                    additional_libs=so_libs,
                    compiler=compiler,
                    linker_flags=linker_flags
                )
                success = result is not None
            else:
                print(f"  Warning: Renamed .a file not found at {renamed_a}")
                print(f"  Falling back to objcopy on .so (may not work properly)")
                success = rename_shared_library_objcopy(lib_file, prefix, map_file, symbol_mapping)
        else:
            # For static libraries, rename all symbols
            success = rename_static_library_objcopy(
                lib_file, prefix, map_file, symbol_mapping,
                create_so=create_so, so_libs=so_libs, 
                compiler=compiler, linker_flags=linker_flags
            )
        
        if not success:
            print(f"Failed to rename symbols in {lib_file}")
            return {}
        
        # Skip shared library creation if we already have a renamed .so
        # (already handled by build system)

    elif os_type == 'Windows':
        raise NotImplementedError("Windows platform is not supported by this script")
    else:
        raise RuntimeError(f"Unsupported OS: {os_type}")
    
    # Process header files if paths provided
    if header_paths and symbol_mapping:
        process_header_files(header_paths, symbol_mapping)
    
    return symbol_mapping

def find_symbols_in_header(content, symbol_mapping, compiled_pattern=None):
    """Find all occurrences of symbols from mapping in header content.
    
    Returns list of symbols found and their rename status.
    Uses compiled regex pattern for much faster matching (compiling once instead of per-header).
    """
    found_symbols = {}
    
    # If no compiled pattern provided, compile it now (backward compatibility)
    if compiled_pattern is None:
        # Build combined pattern: match any of the symbols
        # Sort by length (longest first) to match longer symbols before shorter ones
        sorted_symbols = sorted(symbol_mapping.keys(), key=len, reverse=True)
        pattern_parts = [re.escape(sym) for sym in sorted_symbols]
        combined_pattern = r'\b(' + '|'.join(pattern_parts) + r')\b'
        compiled_pattern = re.compile(combined_pattern)
    
    # Find all matches in one pass
    for match in compiled_pattern.finditer(content):
        symbol = match.group(1)
        if symbol in found_symbols:
            found_symbols[symbol] += 1
        else:
            found_symbols[symbol] = 1
    
    return found_symbols

# An #include directive's path is NOT a symbol. Without shielding it, a library
# namespace token in the map (e.g. `alcp`) rewrites `#include <alcp/macros.h>`
# into `#include <coexbalcp/macros.h>` -- a path that does not exist -- breaking
# the renamed headers. Mask whole directive lines, rewrite, then restore.
_INCLUDE_DIRECTIVE_RE = re.compile(r'^[ \t]*#[ \t]*include[^\n]*$', re.MULTILINE)

def _protect_include_directives(content):
    """Replace #include directive lines with placeholders. Returns (masked, saved)."""
    saved = []
    def _stash(m):
        idx = len(saved)
        saved.append(m.group(0))
        return '\x02AOCLINC%d\x02' % idx
    return _INCLUDE_DIRECTIVE_RE.sub(_stash, content), saved

def _restore_include_directives(content, saved):
    """Restore #include directive lines masked by _protect_include_directives()."""
    for idx, directive in enumerate(saved):
        content = content.replace('\x02AOCLINC%d\x02' % idx, directive)
    return content

def rename_prototypes_in_header_fast(header_path, symbol_mapping, namespace_renames=None, api_prefix_renames=None, type_enum_names=None, aocl_base_prefix=None):
    """ULTRA-FAST header file symbol renaming using optimized string operations.
    
    For 26K+ symbols, regex patterns are too slow. This uses:
    1. Quick string presence check (fast filter)
    2. Only process symbols that exist in the file
    """
    if not os.path.exists(header_path):
        return False
    
    try:
        with open(header_path, 'r', encoding='utf-8') as f:
            content = f.read()
    except (UnicodeDecodeError, IOError):
        try:
            with open(header_path, 'r', encoding='latin-1') as f:
                content = f.read()
        except:
            return False
    
    original_content = content

    # Shield #include directive paths from every rewrite pass below.
    content, _saved_includes = _protect_include_directives(content)

    # OPTIMIZATION 1: Filter to only symbols that ACTUALLY exist in this header
    # This reduces 26K symbols to typically 10-50 symbols per header!
    relevant_symbols = {old: new for old, new in symbol_mapping.items() if old in content}

    if relevant_symbols:
        # OPTIMIZATION 2: For small symbol counts, use simple word-boundary regex
        # This is much faster than a mega-pattern
        if len(relevant_symbols) <= 100:
            for old_sym, new_sym in sorted(relevant_symbols.items(), key=lambda x: len(x[0]), reverse=True):
                pattern = r'\b' + re.escape(old_sym) + r'\b'
                content = re.sub(pattern, new_sym, content)
        else:
            # For larger counts, use a combined pattern
            sorted_syms = sorted(relevant_symbols.keys(), key=len, reverse=True)
            escaped = [re.escape(s) for s in sorted_syms]
            pattern = r'\b(' + '|'.join(escaped) + r')\b'
            content = re.sub(pattern, lambda m: relevant_symbols[m.group(1)], content)

    # Namespace identifier rewrite for C++ headers (e.g., alcp::utils -> AOCL_52_alcp::utils).
    effective_namespace_renames = dict(namespace_renames or {})
    for old_ns, new_ns in build_cpp_namespace_fallback_map(api_prefix_renames).items():
        effective_namespace_renames.setdefault(old_ns, new_ns)
    content = apply_namespace_renames(content, effective_namespace_renames)

    # API family rewrite for wrapper identifiers not present as concrete ELF symbols
    # (e.g., cblas_gemm overload names in C++ headers).
    content = apply_api_prefix_renames(content, api_prefix_renames)
    content = apply_cpp_wrapper_identifier_renames(content, header_path, api_prefix_renames)

    # Rename object-like #define macro LHS aliases (e.g., bli_cscal2ris) and
    # their RHS targets (e.g., bli_cccscal2ris).  These are pure-preprocessor
    # or inline-only symbols absent from the binary map.
    content = apply_define_macro_lhs_renames(content, api_prefix_renames)

    # Rename API prefixes used as token fragments before ## in macro bodies
    # (e.g., PASTEMAC_: bli_ ## ch ## op -> <prefix>bli_ ## ch ## op).
    content = apply_paste_token_prefix_renames(content, api_prefix_renames)

    # Prepend the rename prefix token to PASTEF77x Fortran name-mangling macros
    # so that PASTEF770(name) -> <prefix> ## name (not just name), matching the
    # renamed Fortran BLAS symbols (e.g. <prefix>sgemm_).
    content = apply_pastef77_prefix_renames(content, api_prefix_renames)

    # Rename Fortran symbol names inside LAPACK_GLOBAL_SUFFIX() calls.
    # Fortran LAPACK symbols (e.g., cgbrfsx_) are not defined in the static lib
    # so they never enter the binary symbol map, but the header still references
    # them and must use the renamed names to match the renamed binary.
    content = apply_lapack_global_suffix_renames(content, api_prefix_renames)

    # Rename Fortran symbol names inside LAPACK_EXPORT_* macros and bare
    # Fortran call sites in libflame_interface.hh, so FLAME.h coexists
    # with other vendors' LAPACK headers in the same TU.
    content = apply_lapack_export_renames(content, api_prefix_renames)

    # Rename CBLAS enum type names, enumerator constants, and LAPACK
    # layout macros which are compile-time constructs invisible to objcopy.
    inferred_prefix = infer_wrapper_prefix(
        api_prefix_renames,
        preferred_families=('cblas_', 'lapacke_', 'blis_', 'bli_'),
    )
    if inferred_prefix:
        content = apply_cblas_enum_renames(content, inferred_prefix)

    # AOCL-vs-AOCL coexistence: prefix the AOCL-specific libraries' enums/types
    # (DA/Sparse/Compression/Crypto/LibM) so two renamed AOCL builds can coexist.
    if type_enum_names and aocl_base_prefix and _is_aocl_lib_header(header_path):
        content = apply_aocl_lib_type_enum_renames(content, aocl_base_prefix, type_enum_names)

    # Rename VSL macros/typedefs in openrng.h for vendor header coexistence.
    # In OpenRNG-only builds inferred_prefix is '' (no cblas_/blis_ families);
    # fall back to deriving the prefix from vsl* function renames.
    _openrng_rename_prefix = inferred_prefix
    if not _openrng_rename_prefix and os.path.basename(header_path) == 'openrng.h':
        for _sym, _new in symbol_mapping.items():
            if (isinstance(_sym, str) and isinstance(_new, str)
                    and _sym.startswith('vsl')
                    and _new.endswith(_sym)
                    and len(_new) > len(_sym)):
                _openrng_rename_prefix = _new[:-len(_sym)]
                break
    if _openrng_rename_prefix:
        content = apply_openrng_macro_renames(content, _openrng_rename_prefix)

    # Patch BLIS_FUNC_PREFIX_STR string literal to match the renamed prefix
    # (used by downstream code that constructs symbol names at runtime).
    if inferred_prefix:
        _func_prefix_str_re = re.compile(
            r'(#\s*define\s+BLIS_FUNC_PREFIX_STR\s+")([A-Za-z_][A-Za-z0-9_]*)(")'
        )
        def _rename_func_prefix(m):
            existing = m.group(2)
            if existing.startswith(inferred_prefix):
                return m.group(0)
            return m.group(1) + inferred_prefix + existing + m.group(3)
        content = _func_prefix_str_re.sub(_rename_func_prefix, content)

    # Restore the shielded #include directive lines verbatim.
    content = _restore_include_directives(content, _saved_includes)

    if content == original_content:
        return False
    
    # Write renamed content
    try:
        with open(header_path, 'w', encoding='utf-8') as f:
            f.write(content)
        return True
    except:
        return False

def rename_prototypes_in_header(header_path, symbol_mapping, compiled_pattern=None, namespace_renames=None, api_prefix_renames=None):
    """Rename function prototypes and references in a header file based on symbol mapping.
    
    Uses word boundary replacement to ensure accurate symbol renaming.
    Uses compiled regex pattern for much faster matching across multiple headers.
    """
    if not os.path.exists(header_path):
        print(f"Warning: Header file {header_path} not found.")
        return False
    
    try:
        with open(header_path, 'r', encoding='utf-8') as f:
            content = f.read()
    except UnicodeDecodeError:
        try:
            with open(header_path, 'r', encoding='latin-1') as f:
                content = f.read()
        except Exception as e:
            print(f"Error reading {header_path}: {e}")
            return False
    
    original_content = content

    # Shield #include directive paths from the rewrite passes below.
    content, _saved_includes = _protect_include_directives(content)

    try:
        # Find which symbols from our mapping exist in this header
        found_symbols = find_symbols_in_header(content, symbol_mapping, compiled_pattern)
        
        total_replacements = 0
        if found_symbols:
            # Replace each symbol using word boundary matching
            # Sort by symbol length (descending) to handle cases where one symbol is substring of another
            sorted_symbols = sorted(found_symbols.keys(), key=len, reverse=True)

            for old_symbol in sorted_symbols:
                new_symbol = symbol_mapping[old_symbol]

                # Use word boundary to match only complete symbol names
                pattern = r'\b' + re.escape(old_symbol) + r'\b'

                # Count and replace
                new_content, count = re.subn(pattern, new_symbol, content)

                if count > 0:
                    content = new_content
                    total_replacements += count

        effective_namespace_renames = dict(namespace_renames or {})
        for old_ns, new_ns in build_cpp_namespace_fallback_map(api_prefix_renames).items():
            effective_namespace_renames.setdefault(old_ns, new_ns)
        content = apply_namespace_renames(content, effective_namespace_renames)
        content = apply_api_prefix_renames(content, api_prefix_renames)
        content = apply_cpp_wrapper_identifier_renames(content, header_path, api_prefix_renames)

        # Restore the shielded #include directive lines verbatim.
        content = _restore_include_directives(content, _saved_includes)

        if total_replacements > 0 or content != original_content:
            # Write modified content
            with open(header_path, 'w', encoding='utf-8') as f:
                f.write(content)
            
            return True
        else:
            return False
            
    except Exception as e:
        print(f"Error processing header {header_path}: {e}")
        import traceback
        traceback.print_exc()
        return False

def process_header_files(header_paths, symbol_mapping):
    """Process multiple header files and rename prototypes IN PARALLEL.
    
    For large symbol counts and many headers, parallel processing is essential.
    """
    if not symbol_mapping:
        print("No symbol mapping provided for header processing.")
        return
    
    # Collect all header files to process
    all_header_files = []
    for path_pattern in header_paths:
        # Handle glob patterns
        if '*' in path_pattern or '?' in path_pattern:
            matching_files = glob.glob(path_pattern)
            if matching_files:
                all_header_files.extend(matching_files)
        else:
            # Handle single file or directory
            if os.path.isdir(path_pattern):
                # Process all .h and .hpp files in directory
                header_files = glob.glob(os.path.join(path_pattern, "*.h")) + \
                              glob.glob(os.path.join(path_pattern, "*.hpp")) + \
                              glob.glob(os.path.join(path_pattern, "*.hh"))
                all_header_files.extend(header_files)
            else:
                all_header_files.append(path_pattern)
    
    if not all_header_files:
        print("No header files found to process")
        return
    
    namespace_renames = build_namespace_rename_map(symbol_mapping)
    api_prefix_renames = build_api_prefix_rename_map(symbol_mapping)
    namespace_fallback_renames = build_cpp_namespace_fallback_map(api_prefix_renames)

    # AOCL-vs-AOCL coexistence: collect the AOCL-lib enum/type identifiers once
    # (cross-header) and derive the base prefix for prefixing them.
    aocl_type_enum_names = collect_aocl_lib_type_enum_names(all_header_files)
    aocl_base_prefix = infer_wrapper_prefix(
        api_prefix_renames,
        preferred_families=('cblas_', 'lapacke_', 'blis_', 'bli_', 'da_', 'aoclsparse_'),
    )
    if aocl_type_enum_names and aocl_base_prefix:
        print(f"AOCL-coexistence: prefixing {len(aocl_type_enum_names)} AOCL-lib enum/type identifiers with '{aocl_base_prefix}'")

    print(f"Processing {len(all_header_files)} header files with {len(symbol_mapping)} symbol mappings...")
    if namespace_renames:
        print(f"Applying {len(namespace_renames)} C++ namespace rename mapping(s): {namespace_renames}")
    if namespace_fallback_renames:
        print(f"Applying {len(namespace_fallback_renames)} C++ namespace fallback mapping(s): {namespace_fallback_renames}")
    if api_prefix_renames:
        print(f"Applying {len(api_prefix_renames)} API family prefix rewrite(s): {api_prefix_renames}")
    
    # Process headers in parallel for speed!
    num_cores = max(2, multiprocessing.cpu_count() - 1)
    
    with multiprocessing.Pool(num_cores) as pool:
        # Create args for each header
        args_list = [(header, symbol_mapping, namespace_renames, api_prefix_renames, aocl_type_enum_names, aocl_base_prefix) for header in all_header_files]
        results = pool.starmap(rename_prototypes_in_header_fast, args_list)
    
    processed_files = sum(1 for r in results if r)
    print(f"Total header files processed: {processed_files}/{len(all_header_files)}")

def find_library_files(install_path):
    """Find library files (.a and .so) in the installation path."""
    lib_dir = os.path.join(install_path, 'lib')
    if not os.path.exists(lib_dir):
        raise RuntimeError(f"Library directory not found: {lib_dir}")
    
    # Look for both static (.a) and shared (.so) library files
    found_libs = []
    
    # Check for .a and .so files
    for ext in ['*.a', '*.so']:
        lib_files = glob.glob(os.path.join(lib_dir, ext))
        for lib_file in lib_files:
            if lib_file not in found_libs:
                found_libs.append(lib_file)
    
    return found_libs

def get_include_directory(install_path):
    """Get the include directory path."""
    include_dir = os.path.join(install_path, 'include')
    if not os.path.exists(include_dir):
        raise RuntimeError(f"Include directory not found: {include_dir}")
    return include_dir

def cleanup_temp_files(install_path):
    """Clean up temporary map.txt files created during renaming.
    
    Args:
        install_path: Path to installation package
    """
    # Check for map files in both install_path and current working directory
    locations = [install_path, os.getcwd()]
    all_map_files = []
    
    for location in locations:
        map_files = glob.glob(os.path.join(location, '*_map.txt'))
        all_map_files.extend(map_files)
    
    # Remove duplicates (in case install_path == cwd)
    all_map_files = list(set(all_map_files))
    
    if all_map_files:
        for map_file in all_map_files:
            try:
                os.remove(map_file)
            except Exception as e:
                print(f"Warning: Failed to remove {map_file}: {e}")
        print(f"Cleaned up {len(all_map_files)} temporary map file(s)")

def validate_package_structure(install_path):
    """Validate that the path looks like a valid AOCL installation package."""
    lib_dir = os.path.join(install_path, 'lib')
    include_dir = os.path.join(install_path, 'include')
    
    issues = []
    
    if not os.path.exists(lib_dir):
        issues.append(f"Missing lib directory: {lib_dir}")
    elif not os.path.isdir(lib_dir):
        issues.append(f"lib path is not a directory: {lib_dir}")
    
    if not os.path.exists(include_dir):
        issues.append(f"Missing include directory: {include_dir}")
    elif not os.path.isdir(include_dir):
        issues.append(f"include path is not a directory: {include_dir}")
    
    if issues:
        raise RuntimeError("Invalid package structure:\n" + "\n".join(f"  - {issue}" for issue in issues))
    
    return True

def rename_symbols_package(install_path, prefix, create_so=False, so_libs=None, compiler='gcc', linker_flags=None):
    """Rename symbols in an installation package (lib/ and include/ structure).
    
    Args:
        install_path: Path to installation package
        prefix: Prefix to add to symbols
        create_so: If True, create shared libraries from renamed static libraries
        so_libs: Additional libraries needed when creating shared libraries
        compiler: Compiler to use for creating shared libraries (from CMAKE_C_COMPILER)
        linker_flags: Linker flags to use (from CMAKE_SHARED_LINKER_FLAGS)
    """
    action = "Processing"
    print(f"{action} AOCL installation package at: {install_path}")
    
    # Normalize path
    install_path = os.path.abspath(install_path)
    
    if not os.path.exists(install_path):
        raise RuntimeError(f"Installation path does not exist: {install_path}")
    
    if not os.path.isdir(install_path):
        raise RuntimeError(f"Installation path is not a directory: {install_path}")
    
    # Validate package structure
    validate_package_structure(install_path)
    
    # Note: We no longer delete existing .so files. Instead, we rename symbols in them directly.
    # The build system creates both .a and .so files, and we process both.
    
    # Find library files (.a and .so)
    lib_dir = os.path.join(install_path, 'lib')
    lib_files = find_library_files(install_path)
    if not lib_files:
        raise RuntimeError(f"No AOCL library files found in {os.path.join(install_path, 'lib')}")
    
    print(f"Found {len(lib_files)} library file(s)")
    
    # Get include directory
    include_dir = get_include_directory(install_path)

    # Collect AOCL enum/struct/typedef tags from the ORIGINAL public headers up
    # front, so the mangled C++ symbol rename can prefix embedded type components
    # consistently with the header rename. This keeps C++ template/overload
    # symbols (e.g. aoclsparse::mv<T>) resolvable against the renamed headers.
    aocl_type_names = set()
    try:
        _orig_headers = []
        for _root, _dirs, _files in os.walk(include_dir):
            for _f in _files:
                if _f.endswith(('.h', '.hpp', '.hxx', '.hh')):
                    _orig_headers.append(os.path.join(_root, _f))
        aocl_type_names = collect_aocl_lib_type_enum_names(_orig_headers)
        if aocl_type_names:
            print(f"Collected {len(aocl_type_names)} AOCL type tag(s) for mangled C++ symbol renaming")
    except Exception as _e:
        print(f"Warning: could not collect AOCL type tags for mangled rename: {_e}")
        aocl_type_names = set()
    
    # Process each library file
    all_mappings = {}
    successful_libs = 0
    
    print(f"\n=== Processing library files ===")
    for lib_file in lib_files:
        try:
            # Process library file and rename all symbols
            mapping = rename_symbols(
                lib_file, prefix, 
                create_so=create_so,
                so_libs=so_libs, 
                compiler=compiler, 
                linker_flags=linker_flags,
                type_names=aocl_type_names
            )
            
            if mapping:
                base_name = os.path.splitext(os.path.basename(lib_file))[0]
                all_mappings.update(mapping)
                successful_libs += 1
        except Exception as e:
            print(f"Warning: Failed to process {lib_file}: {e}")
            continue
    
    if not all_mappings:
        raise RuntimeError("No symbols were successfully renamed in any library file")
    
    # Copy header files to renamed directory
    print("\n=== Copying header files ===")
    renamed_include = os.path.join(install_path, 'renamed', 'include')
    os.makedirs(renamed_include, exist_ok=True)
    
    header_count = 0
    for root, dirs, files in os.walk(include_dir):
        # Calculate relative path from include_dir
        rel_path = os.path.relpath(root, include_dir)
        dest_root = os.path.join(renamed_include, rel_path) if rel_path != '.' else renamed_include
        
        # Create destination directory
        os.makedirs(dest_root, exist_ok=True)
        
        # Copy header files
        for file in files:
            if file.endswith(('.h', '.hpp', '.hxx', '.hh')):
                src = os.path.join(root, file)
                dest = os.path.join(dest_root, file)
                shutil.copy2(src, dest)
                header_count += 1
    
    print(f"Copied {header_count} header files to {renamed_include}")
    
    # Process header files in renamed directory
    renamed_include = os.path.join(install_path, 'renamed', 'include')
    print(f"\n=== Renaming symbols in headers ===")
    
    # Find all header files recursively
    header_search_dir = renamed_include
    header_files = []
    for root, dirs, files in os.walk(header_search_dir):
        for file in files:
            if file.endswith(('.h', '.hpp', '.hxx', '.hh')):
                header_files.append(os.path.join(root, file))
    
    if header_files and all_mappings:
        process_header_files(header_files, all_mappings)
    elif not header_files:
        print("Warning: No header files found")
    
    print(f"\n=== Summary ===")
    print(f"Symbols renamed: {len(all_mappings)}")
    print(f"Libraries processed: {successful_libs}/{len(lib_files)}")
    print(f"\nOriginal: {os.path.join(install_path, 'lib')} | {os.path.join(install_path, 'include')}")
    print(f"Renamed:  {os.path.join(install_path, 'renamed', 'lib')} | {os.path.join(install_path, 'renamed', 'include')}")
    
    # Copy symbol map files to renamed directory for reference
    print(f"\n=== Copying symbol map files ===")
    renamed_lib_dir = os.path.join(install_path, 'renamed', 'lib')
    map_files_copied = 0
    for map_file in glob.glob('*.map.txt') + glob.glob('*_map.txt'):
        dest_map = os.path.join(renamed_lib_dir, map_file)
        try:
            shutil.copy2(map_file, dest_map)
            map_files_copied += 1
        except Exception as e:
            print(f"Warning: Failed to copy {map_file}: {e}")
    
    if map_files_copied > 0:
        print(f"Copied {map_files_copied} symbol map file(s) to {renamed_lib_dir}")
    
    # Clean up temporary map.txt files from current directory
    cleanup_temp_files(install_path)
    
    return all_mappings

if __name__ == "__main__":
    # Check for Windows and raise NotImplementedError
    if platform.system() == 'Windows':
        print("Error: Windows platform is not currently supported.")
        print("This script is designed for Linux/Unix systems.")
        sys.exit(1)

    # -- CMake-native driver sub-task modes --
    # When rename_symbols.cmake drives the rename on Linux it does the
    # orchestration (loop, objcopy, .so re-link, prune) itself and delegates
    # only the two regex-heavy steps to this script, which REUSES the exact
    # same functions the full flow uses (no behaviour divergence):
    #   --emit-map     : extract symbols from ONE library + write its objcopy map
    #                    (incl. Option-A embedded type-tag renaming when an
    #                     include dir is given).
    #   --emit-headers : rewrite the (already-copied) renamed headers in place
    #                    using a combined objcopy map (C symbols + C++ namespaces
    #                    + CBLAS/OpenRNG enums + AOCL-vs-AOCL enum/type coexist).
    if len(sys.argv) >= 2 and sys.argv[1] == '--emit-map':
        # python rename_engine_linux.py --emit-map <lib_file> <prefix> <out_map> [<include_dir>]
        if len(sys.argv) < 5:
            print("Usage: rename_engine_linux.py --emit-map <lib_file> <prefix> <out_map> [<include_dir>]")
            sys.exit(1)
        _lib_file = sys.argv[2]
        _prefix = sys.argv[3]
        _out_map = sys.argv[4]
        _include_dir = sys.argv[5] if len(sys.argv) > 5 else None
        _base = os.path.basename(_lib_file)
        if _base.endswith('.so') or '.so.' in _base:
            _symbols = get_symbols_linux_shared(_lib_file)
        else:
            _symbols = get_symbols_linux_static(_lib_file)
        _type_names = set()
        if _include_dir and os.path.isdir(_include_dir):
            _hdrs = []
            for _root, _dirs, _files in os.walk(_include_dir):
                for _f in _files:
                    if _f.endswith(('.h', '.hpp', '.hxx', '.hh')):
                        _hdrs.append(os.path.join(_root, _f))
            try:
                _type_names = collect_aocl_lib_type_enum_names(_hdrs)
            except Exception as _e:
                print(f"Warning: could not collect AOCL type tags: {_e}")
                _type_names = set()
        generate_mapping(_symbols, _prefix, _out_map, type_names=_type_names)
        sys.exit(0)

    if len(sys.argv) >= 2 and sys.argv[1] == '--emit-headers':
        # python rename_engine_linux.py --emit-headers <combined_map> <include_dir>
        if len(sys.argv) < 4:
            print("Usage: rename_engine_linux.py --emit-headers <combined_map> <include_dir>")
            sys.exit(1)
        _map_file = sys.argv[2]
        _include_dir = sys.argv[3]
        _symbol_mapping = {}
        with open(_map_file, 'r') as _mf:
            for _line in _mf:
                _line = _line.strip()
                if not _line:
                    continue
                _sp = _line.find(' ')
                if _sp < 1:
                    continue
                _symbol_mapping[_line[:_sp]] = _line[_sp + 1:]
        _header_files = []
        for _root, _dirs, _files in os.walk(_include_dir):
            for _f in _files:
                if _f.endswith(('.h', '.hpp', '.hxx', '.hh')):
                    _header_files.append(os.path.join(_root, _f))
        if _header_files and _symbol_mapping:
            process_header_files(_header_files, _symbol_mapping)
        else:
            print("Nothing to do (no headers or empty map).")
        sys.exit(0)

    if len(sys.argv) < 3:
        print("AOCL Symbol Renaming Script - Intelligent Case-Aware Prefixing")
        print("=" * 65)
        print("\nUsage: python rename_engine_linux.py <package_path> <prefix> [options]")
        print("\nOptions:")
        print("  --create-so             Create shared libraries from renamed static libraries")
        print("  --so-libs 'libs'        Additional libraries (e.g., '-lgfortran -lm -lquadmath')")
        print("  --compiler <path>       Compiler to use (default: gcc)")
        print("  --linker-flags 'flags'  Linker flags to pass")
        print("\nExamples:")
        print("  python rename_engine_linux.py /path/to/package AOCL_")
        print("  python rename_engine_linux.py /path/to/package AOCL_ --create-so --so-libs '-lgfortran -lm'")
        print("\nNote: Windows platform is not supported.")
        sys.exit(1)

    # Main package processing mode
    package_path = sys.argv[1]
    prefix = sys.argv[2]
    create_so = "--create-so" in sys.argv[3:]
    
    # Parse --so-libs argument
    so_libs = None
    if "--so-libs" in sys.argv[3:]:
        so_libs_idx = sys.argv.index("--so-libs")
        if so_libs_idx + 1 < len(sys.argv):
            # Collect all arguments until the next option (starting with --).
            # Each collected token is whitespace-split so callers may pass either
            #   --so-libs -lgfortran -lm
            # or a single quoted string:
            #   --so-libs '-lgfortran -lm -fopenmp'
            so_libs = []
            for i in range(so_libs_idx + 1, len(sys.argv)):
                arg = sys.argv[i]
                if arg.startswith("--"):
                    break
                so_libs.extend(arg.split())
            if not so_libs:
                print("Error: --so-libs requires at least one library")
                sys.exit(1)
        else:
            print("Error: --so-libs requires a value")
            sys.exit(1)
    
    # Parse --compiler argument
    compiler = 'gcc'  # default
    if "--compiler" in sys.argv[3:]:
        compiler_idx = sys.argv.index("--compiler")
        if compiler_idx + 1 < len(sys.argv):
            compiler = sys.argv[compiler_idx + 1]
        else:
            print("Error: --compiler requires a value")
            sys.exit(1)
    
    # Parse --linker-flags argument
    linker_flags = None
    if "--linker-flags" in sys.argv[3:]:
        linker_flags_idx = sys.argv.index("--linker-flags")
        if linker_flags_idx + 1 < len(sys.argv):
            linker_flags = sys.argv[linker_flags_idx + 1]
        else:
            print("Error: --linker-flags requires a value")
            sys.exit(1)
    
    if not os.path.exists(package_path):
        print(f"Error: Package path does not exist: {package_path}")
        sys.exit(1)
    
    if not os.path.isdir(package_path):
        print(f"Error: Package path is not a directory: {package_path}")
        sys.exit(1)
    
    try:
        symbol_mapping = rename_symbols_package(package_path, prefix, create_so=create_so, so_libs=so_libs, compiler=compiler, linker_flags=linker_flags)
        print(f"\nPackage symbol renaming completed successfully!")
        if symbol_mapping:
            print(f"Total symbols renamed: {len(symbol_mapping)}")
            print(f"\nYour AOCL package has been successfully updated with {prefix} prefix!")
            print(f"Libraries processed in: {os.path.join(package_path, 'lib')}")
            print(f"Headers processed in: {os.path.join(package_path, 'include')}")
            print(f"\nYou can now link against the renamed symbols using:")
            print(f"   gcc your_program.c -L{os.path.join(package_path, 'lib')} -laocl -lgfortran -lm -lquadmath")
        else:
            print("Warning: No symbols were renamed")
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)
