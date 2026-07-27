# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
# ---------------------------------------------------------------------------
# rename_engine_windows.ps1
#
# Windows symbol-rename ENGINE (PowerShell) - the Windows counterpart of
# rename_engine_linux.py. Invoked by the CMake driver (rename_symbols.cmake)
# via rename_symbols_windows.cmake in the following modes:
#
#   -Mode map      Read symbols (llvm-nm) and write the "<old> <new>" objcopy
#                  redefine-syms map (Itanium + MSVC mangling + Option-A type
#                  tags) plus the aocl_type_tags.txt sidecar.
#                  Params: -LibFile -LlvmNm -OutMap -Prefix [-IncludeDir]
#
#   -Mode headers  Rewrite the (already-copied) renamed headers in place using
#                  the combined map: plain-C + C++ namespace/function + CBLAS/
#                  OpenRNG enums + AOCL-vs-AOCL enum/type coexistence.
#                  Params: -MapFile -IncludeDir -UpperPrefix
#
#   -Mode data     List an import library's DATA-only exports (symbols present
#                  only as __imp_<sym> with no plain code entry) to -Out, one per
#                  line. Used by create_dll_windows to re-export data symbols.
#                  Params: -LlvmNm -ImportLib -Out
#
#   -Mode parobjcopy  Run llvm-objcopy --redefine-syms=<map> over many library
#                  files in parallel (one job per core).
#                  Params: -Objcopy -MapFile -LibsFile [-RemoveDrectve] [-MaxConcurrency]
#
# CMake orchestrates (loop, objcopy, DLL re-link, prune); this script does the
# regex-heavy work, exactly as rename_engine_linux.py does on Linux.
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('map', 'headers', 'data', 'parobjcopy')][string]$Mode,
    # -Mode map
    [string]$LibFile,
    [string]$LlvmNm,
    [string]$OutMap,
    [string]$Prefix,
    [string]$IncludeDir = "",
    # -Mode headers
    [string]$MapFile,
    [string]$UpperPrefix,
    # -Mode data   (extract an import lib's DATA-only exports)
    [string]$ImportLib,
    [string]$Out,
    # -Mode parobjcopy  (parallel llvm-objcopy --redefine-syms over many libs)
    [string]$Objcopy,
    [string]$LibsFile,
    [switch]$RemoveDrectve,
    [int]$MaxConcurrency = 0
)

if ($Mode -eq 'map') {
$ErrorActionPreference = 'Stop'
$sw = [Diagnostics.Stopwatch]::StartNew()

if (-not (Test-Path $LibFile)) {
    Write-Error "Library file not found: $LibFile"
    exit 1
}
if (-not (Test-Path $LlvmNm)) {
    Write-Error "llvm-nm not found: $LlvmNm"
    exit 1
}

# Normalise prefix token (strip non-identifier chars)
$tok = ($Prefix -replace '[^A-Za-z0-9_]', '')
if ([string]::IsNullOrEmpty($tok)) {
    Write-Error "Prefix '$Prefix' resolves to empty identifier token"
    exit 1
}

# -- ABI / std exclusion patterns (mirror rename_symbols.cmake) --
$abiExcludes = @(
    '^__gxx_personality_v0$', '^__cxa_', '^_Unwind_',
    '^__stack_chk_(fail|guard)$', '^__tls_get_addr$', '^__dso_handle$',
    '^__libc_', '^__pthread_',
    '^DW\.ref\.', '^\.(L|local)', '^a\.',
    '^_GLOBAL_OFFSET_TABLE_$',
    '^_init$', '^_fini$', '^__gmon_start__$'
)
$msvcAbiExcludes = @(
    '^\?\?_R', '^\?\?_7', '^\?\?_8', '^\?\?_9', '^\?\?_C@',
    '^\?\?2@', '^\?\?3@', '^\?\?_E', '^\?\?_G',
    '^__real@', '^__xmm@', '^__ymm@',
    '^__imp_', '^_CRT_', '^__security_', '^__GSHandler', '^__std_'
)
$itaniumStdExcludes = @(
    '^_ZSt', '^_ZNSt', '^_ZTS[Ss]t', '^_ZTI[Ss]t', '^_ZTV[Ss]t', '^_ZTT[Ss]t'
)

# -- Standard C/POSIX/math library symbols that must NEVER be renamed --
# Mirrors STDLIB_SYMBOL_EXCLUDES in rename_symbols.py. BLIS emits these as
# weak/COMDAT defined symbols from BLIS_INLINE functions (e.g. bli_round calls
# round(); BLIS sup paths call printf()), so llvm-nm lists them as renameable.
# If they enter the map they get prefixed both in the binary AND in the header
# text rewrite (rename_headers consumes this map), producing undeclared
# `aocl_round` / `aocl_printf` references in renamed/include/blis.h that break
# any consumer including the header directly. Keep this exact-match (the .lib
# symbols are bare lowercase names on x64 Windows -- no leading underscore).
$stdlibExcludeSet = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@(
        # <math.h>
        'abs','labs','llabs','div','ldiv','lldiv',
        'fabs','fabsf','fabsl','fmin','fminf','fminl','fmax','fmaxf','fmaxl',
        'sqrt','sqrtf','sqrtl','cbrt','cbrtf','cbrtl','hypot','hypotf','hypotl',
        'pow','powf','powl','exp','expf','expl','exp2','exp2f','expm1','expm1f',
        'log','logf','logl','log2','log2f','log10','log10f','log1p','log1pf',
        'sin','sinf','sinl','cos','cosf','cosl','tan','tanf','tanl',
        'asin','asinf','acos','acosf','atan','atanf','atan2','atan2f',
        'sinh','sinhf','cosh','coshf','tanh','tanhf',
        'asinh','acosh','atanh','erf','erff','erfc','erfcf','tgamma','lgamma',
        'floor','floorf','floorl','ceil','ceilf','ceill',
        'round','roundf','roundl','lround','lroundf','llround','llroundf',
        'rint','rintf','lrint','llrint','nearbyint','nearbyintf',
        'trunc','truncf','truncl','fmod','fmodf','fmodl','remainder','remainderf',
        'fma','fmaf','fmal','frexp','frexpf','ldexp','ldexpf','modf','modff',
        'scalbn','scalbnf','scalbln','copysign','copysignf','copysignl',
        'nextafter','nextafterf','fdim','fdimf','signbit',
        'isnan','isinf','isfinite','isnormal','fpclassify',
        # <stdio.h>
        'printf','fprintf','sprintf','snprintf','vprintf','vfprintf','vsprintf',
        'vsnprintf','scanf','fscanf','sscanf','puts','fputs','putchar','putc',
        'fputc','getchar','getc','fgetc','gets','fgets','fopen','freopen',
        'fclose','fread','fwrite','fflush','fseek','ftell','rewind','fsetpos',
        'fgetpos','setvbuf','setbuf','perror','remove','rename','tmpfile','tmpnam',
        # <stdlib.h>
        'malloc','calloc','realloc','free','aligned_alloc','posix_memalign',
        'atoi','atol','atoll','atof','strtol','strtoll','strtoul','strtoull',
        'strtod','strtof','qsort','bsearch','rand','srand','exit','_Exit',
        'abort','atexit','getenv','system','mblen','mbtowc','wctomb',
        # <string.h>
        'memcpy','memmove','memset','memcmp','memchr','strlen','strnlen',
        'strcpy','strncpy','strcat','strncat','strcmp','strncmp','strcoll',
        'strchr','strrchr','strstr','strspn','strcspn','strpbrk','strtok',
        'strdup','strndup','strerror',
        # <ctype.h>
        'isalnum','isalpha','isblank','iscntrl','isdigit','isgraph','islower',
        'isprint','ispunct','isspace','isupper','isxdigit','tolower','toupper'
    ),
    [System.StringComparer]::Ordinal
)

# Compile to .NET Regex objects for speed
$abiRx        = $abiExcludes        | ForEach-Object { [regex]::new($_, 'Compiled') }
$msvcAbiRx    = $msvcAbiExcludes    | ForEach-Object { [regex]::new($_, 'Compiled') }
$itaniumStdRx = $itaniumStdExcludes | ForEach-Object { [regex]::new($_, 'Compiled') }

# Pre-compiled regexes for the fast paths
$rxItanium     = [regex]::new('^_Z',        'Compiled')
$rxMsvc        = [regex]::new('^\?',        'Compiled')
$rxStdInside   = [regex]::new('@std@@[A-Z0-9]', 'Compiled')

# Itanium <length><identifier> after N + optional CV-quals
$rxItaniumNested = [regex]::new(
    '^(_Z(?:Z?N|TVN|TIN|TSN|TTN|TCN|GVN|GRN|GVZ.*?N)[rVKRO]*)(\d+)([A-Za-z_][A-Za-z0-9_]*)',
    'Compiled')

# -- Option A: embedded AOCL type-tag renaming inside mangled C++ symbols --
# Mirrors rename_symbols.py's _prefix_mangled_type_components so C++ template &
# overload symbols match the renamed headers (whose enum/struct/typedef tags are
# prefixed). Type tags are collected from the ORIGINAL public headers ($IncludeDir).
$typeEnumNever = [System.Collections.Generic.HashSet[string]]::new([string[]]@(
    'int','char','short','long','float','double','void','unsigned','signed',
    'const','volatile','static','extern','struct','union','enum','typedef',
    'return','sizeof','size_t','ssize_t','ptrdiff_t','intptr_t','uintptr_t',
    'wchar_t','bool','_Bool','_Complex','FILE','va_list','true','false','NULL','nullptr',
    'int8_t','int16_t','int32_t','int64_t','uint8_t','uint16_t','uint32_t','uint64_t'))
$structAttrKw = @('alignas','_Alignas','__attribute__','__declspec','packed','aligned')
function Keep-Tag([string]$n) {
    # Only long, distinctive AOCL tags: they alone appear as source-names in
    # mangled symbols; short typedef-to-builtin names resolve to builtin codes.
    if ($n.Length -lt 8) { return $false }
    if ($typeEnumNever.Contains($n) -or $structAttrKw -contains $n) { return $false }
    if ($n.StartsWith('__')) { return $false }
    if ($n -cmatch '^_[A-Z]') { return $false }
    return ($n -match '^[A-Za-z_][A-Za-z0-9_]*$')
}
function IsAocl-Header([string]$path) {
    $p = $path.Replace('\','/').ToLowerInvariant(); $b = [IO.Path]::GetFileName($p)
    if (@('cblas.h','cblas.hh','lapacke.h','lapack.h','openrng.h') -contains $b) { return $false }
    if ($p.Contains('/alcp/') -or $b.StartsWith('alcp') -or $b.StartsWith('rng')) { return $true }
    foreach ($m in @('aoclda','aocl_da','aoclsparse','aocl_compression','amdlibm','aoclutils','aocl_libmem','libmem')) {
        if ($b.Contains($m)) { return $true }
    }
    return $false
}
$aoclTags = [System.Collections.Generic.HashSet[string]]::new()
if ($IncludeDir -and (Test-Path $IncludeDir)) {
    $rxEnum = [regex]::new('\benum\b\s*(\w+)?\s*\{([^{}]*)\}\s*(\w+)?', ([System.Text.RegularExpressions.RegexOptions]'Compiled, Singleline'))
    $rxEC   = [regex]::new('([A-Za-z_]\w*)\s*(?:=[^,]*)?(?:,|$)', ([System.Text.RegularExpressions.RegexOptions]'Compiled, Singleline'))
    $rxTd   = [regex]::new('\btypedef\s+(?:struct|union)\b([^{;]*?)\{(?:[^{}]|\{[^{}]*\})*\}\s*(\w+)\s*;', ([System.Text.RegularExpressions.RegexOptions]'Compiled, Singleline'))
    $rxTdS  = [regex]::new('\btypedef\s+[^;{}]+?\b([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*;', 'Compiled')
    $rxTag  = [regex]::new('\b(?:struct|union)\s+(?:(?:alignas|_Alignas|__attribute__|__declspec|packed|aligned)\s+)*([A-Za-z_]\w*)', 'Compiled')
    Get-ChildItem -Path $IncludeDir -Recurse -File -Include '*.h','*.hpp','*.hxx','*.hh' -EA SilentlyContinue | ForEach-Object {
        if (-not (IsAocl-Header $_.FullName)) { return }
        $raw = [IO.File]::ReadAllText($_.FullName)
        $txt = [regex]::Replace($raw, '/\*.*?\*/', ' ', [System.Text.RegularExpressions.RegexOptions]::Singleline)
        $txt = [regex]::Replace($txt, '//[^\r\n]*', ' ')
        $txtNp = [regex]::Replace($txt, '\([^()]*\)', ' '); $txtNp = [regex]::Replace($txtNp, '\([^()]*\)', ' ')
        foreach ($m in $rxEnum.Matches($txt)) {
            if ($m.Groups[1].Success) { [void]$aoclTags.Add($m.Groups[1].Value) }
            if ($m.Groups[3].Success) { [void]$aoclTags.Add($m.Groups[3].Value) }
            foreach ($cm in $rxEC.Matches($m.Groups[2].Value)) { [void]$aoclTags.Add($cm.Groups[1].Value) }
        }
        foreach ($m in $rxTd.Matches($txt))  { [void]$aoclTags.Add($m.Groups[2].Value) }
        foreach ($m in $rxTdS.Matches($txt)) { [void]$aoclTags.Add($m.Groups[1].Value) }
        foreach ($m in $rxTag.Matches($txtNp)) { [void]$aoclTags.Add($m.Groups[1].Value) }
    }
}
$aoclTagList = @($aoclTags | Where-Object { Keep-Tag $_ } | Sort-Object { $_.Length } -Descending)
$itaniumTypeRx = $null; $itaniumTypeLookup = @{}
$msvcTypeRx = $null
if ($aoclTagList.Count -gt 0) {
    foreach ($t in $aoclTagList) { $itaniumTypeLookup["$($t.Length)$t"] = $t }
    $itAlt = ($aoclTagList | ForEach-Object { [regex]::Escape("$($_.Length)$_") }) -join '|'
    $itaniumTypeRx = [regex]::new('(?<![0-9])(' + $itAlt + ')', 'Compiled')
    # MSVC: a user type name segment is `<intro><name>@` where intro = W<digit>
    # (enum) / U|V|T (struct/class/union) / @ (nested scope). Anchor precisely.
    $msvcAlt = ($aoclTagList | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $msvcTypeRx = [regex]::new('(?<=W[0-9]|[UVT@])(' + $msvcAlt + ')(?=@)', 'Compiled')
}
Write-Host ("[ps-map] AOCL type tags for mangled C++ type rename: {0}" -f $aoclTagList.Count)

# Sidecar for the cmake fallback (_prefix_msvc_types in rename_symbols.cmake):
# expose the exact same authoritative tag set so the pure-CMake / create_dll_windows
# fallback renames identical embedded type components (zero-duplication parity).
try {
    $tagSidecar = Join-Path ([IO.Path]::GetDirectoryName($OutMap)) 'aocl_type_tags.txt'
    [IO.File]::WriteAllLines($tagSidecar, $aoclTagList)
} catch { }

function Prefix-ItaniumTypes([string]$sym) {
    if (-not $itaniumTypeRx) { return $sym }
    return $itaniumTypeRx.Replace($sym, {
        param($m)
        $name = $script:itaniumTypeLookup[$m.Groups[1].Value]
        $new  = $script:tok + $name
        return "$($new.Length)$new"
    })
}
function Prefix-MsvcTypes([string]$sym) {
    if (-not $msvcTypeRx) { return $sym }
    return $msvcTypeRx.Replace($sym, { param($m) $script:tok + $m.Groups[1].Value })
}

function Is-OutermostStd([string]$sym) {
    # True only when the OUTERMOST namespace/scope of an MSVC-mangled symbol is
    # `std` (i.e. the symbol genuinely belongs to std::). This must NOT fire when
    # `std` merely appears inside a template argument or a parameter type such as
    # `std::complex<float>` (e.g. ??$kt_trsv_l@...V?$complex@M@std@@H...), which
    # are real AOCL template instantiations that DO need renaming. The old loose
    # regex `@std@@[A-Z0-9]` matched the `@std@@H` of a complex<float> parameter
    # and wrongly skipped those symbols, leaving them unrenamed.
    if (-not $sym.StartsWith('?')) { return $false }
    if     ($sym.StartsWith('??$')) { $opLen = 3 }
    elseif ($sym.Length -ge 4 -and $sym[0] -eq '?' -and $sym[1] -eq '?' -and $sym[2] -eq '_') { $opLen = 4 }
    elseif ($sym.StartsWith('??')) { $opLen = 3 }
    elseif ($sym.StartsWith('?'))  { $opLen = 1 }
    else { return $false }
    if ($sym.Length -le $opLen) { return $false }
    $isTemplate = $sym.StartsWith('??$')
    $depth = 0; $term = -1; $firstAt0 = -1; $lastAt0 = -1
    $i = $opLen; $n = $sym.Length
    while ($i -lt $n) {
        $c = $sym[$i]
        if ($c -eq '?' -and ($i + 1) -lt $n -and $sym[$i + 1] -eq '$') { $depth++; $i += 2; continue }
        if ($c -eq '@' -and ($i + 1) -lt $n -and $sym[$i + 1] -eq '@') {
            if ($depth -eq 0) { $term = $i; break }
            $depth--; $i += 2; continue
        }
        if ($c -eq '@' -and $depth -eq 0) { if ($firstAt0 -lt 0) { $firstAt0 = $i }; $lastAt0 = $i }
        $i++
    }
    if ($term -lt 0) { return $false }
    if ($firstAt0 -lt 0) { return $false }                       # no scope
    if ($isTemplate -and ($firstAt0 -eq $lastAt0)) { return $false } # global template, no scope
    $seg = $sym.Substring($lastAt0 + 1, $term - $lastAt0 - 1)    # outermost scope segment
    return ($seg -eq 'std')
}

function Should-Skip([string]$sym) {
    if ($sym.Length -lt 2) { return $true }
    if ($stdlibExcludeSet.Contains($sym)) { return $true }
    if ($sym.Contains('std::')) { return $true }
    foreach ($r in $itaniumStdRx) { if ($r.IsMatch($sym)) { return $true } }
    foreach ($r in $abiRx)        { if ($r.IsMatch($sym)) { return $true } }
    if ($sym.StartsWith('?')) {
        foreach ($r in $msvcAbiRx) { if ($r.IsMatch($sym)) { return $true } }
        if (Is-OutermostStd $sym) { return $true }
    }
    return $false
}

function Rename-Itanium([string]$sym) {
    $m = $rxItaniumNested.Match($sym)
    if (-not $m.Success) { return (Prefix-ItaniumTypes $sym) }
    $head      = $m.Groups[1].Value
    $origLen   = [int]$m.Groups[2].Value
    $firstComp = $m.Groups[3].Value
    if ($firstComp.Length -ne $origLen) {
        # Identifier was shorter than declared length (digits ate into name);
        # fall back to using the declared length as a slice of the rest.
        $afterDigits = $head.Length + $m.Groups[2].Length
        if ($afterDigits + $origLen -gt $sym.Length) { return (Prefix-ItaniumTypes $sym) }
        $firstComp = $sym.Substring($afterDigits, $origLen)
    }
    if ($firstComp.StartsWith($tok)) { return (Prefix-ItaniumTypes $sym) }
    $newComp = $tok + $firstComp
    $tailStart = $head.Length + $m.Groups[2].Length + $origLen
    $tail = $sym.Substring($tailStart)
    return (Prefix-ItaniumTypes ('{0}{1}{2}{3}' -f $head, $newComp.Length, $newComp, $tail))
}

function Rename-Msvc([string]$sym) {
    # Symmetric-with-Itanium policy: inject the prefix at the OUTERMOST
    # scope identifier (the @-segment immediately before the first `@@`
    # terminator), or at the function/operator name itself if the symbol
    # has no enclosing scope. This mirrors the Linux/Itanium behaviour
    # implemented by `_replace_first_nested_component` in rename_symbols.py
    # so that, after rename, the same fully-qualified C++ name appears on
    # both platforms -- e.g. ::AOCL_alcp::utils::CpuId::cpuIsZen3() rather
    # than ::alcp::utils::CpuId::AOCL_cpuIsZen3() (the previous Windows
    # form).
    #
    # Examples:
    #   ?cpuIsZen3@CpuId@utils@alcp@@SA_NXZ
    #     -> ?cpuIsZen3@CpuId@utils@AOCL_alcp@@SA_NXZ
    #   ??0X86Cpu@Au@@QEAA@I@Z
    #     -> ??0X86Cpu@AOCL_Au@@QEAA@I@Z
    #   ?foo@@YAXH@Z      (free function, no scope)
    #     -> ?AOCL_foo@@YAXH@Z
    #
    # Backref preservation: MSVC parameter back-references (`0..9`) refer
    # to encoded names by slot index, not by content. Replacing a name
    # in-place with a longer prefixed string keeps the slot order intact,
    # so existing back-references continue to resolve correctly.

    if ($sym.Length -lt 3) { return $sym }

    # Determine length of the leading operator-prefix marker.
    if     ($sym.StartsWith('??$')) { $opLen = 3 }                                           # ??$ template
    elseif ($sym.Length -ge 4 -and $sym[0] -eq '?' -and $sym[1] -eq '?' -and $sym[2] -eq '_') { $opLen = 4 }  # ??_X
    elseif ($sym.StartsWith('??')) { $opLen = 3 }                                            # ??<digit/letter>
    elseif ($sym.StartsWith('?'))  { $opLen = 1 }                                            # ?
    else { return $sym }

    if ($sym.Length -le $opLen) { return $sym }

    $isTemplate = $sym.StartsWith('??$')

    # Depth-aware scan: '?$' opens a nested template-id (depth++), its '@@' closes it (depth--).
    # Name-section terminator = first '@@' at depth 0; only depth-0 '@' are scope separators.
    $depth    = 0
    $term     = -1
    $firstAt0 = -1
    $lastAt0  = -1
    $i = $opLen
    $n = $sym.Length
    while ($i -lt $n) {
        $c = $sym[$i]
        if ($c -eq '?' -and ($i + 1) -lt $n -and $sym[$i + 1] -eq '$') {
            $depth++; $i += 2; continue
        }
        if ($c -eq '@' -and ($i + 1) -lt $n -and $sym[$i + 1] -eq '@') {
            if ($depth -eq 0) { $term = $i; break }
            $depth--; $i += 2; continue
        }
        if ($c -eq '@' -and $depth -eq 0) {
            if ($firstAt0 -lt 0) { $firstAt0 = $i }
            $lastAt0 = $i
        }
        $i++
    }
    if ($term -lt 0) { return (Prefix-MsvcTypes $sym) }

    if ($firstAt0 -lt 0) {
        # No depth-0 '@' before terminator: free function/data (no scope) -> prefix the name.
        $injectAt = $opLen
    }
    elseif ($isTemplate -and ($firstAt0 -eq $lastAt0)) {
        # Global template: the single depth-0 '@' is the name/args separator and
        # there is NO enclosing scope (e.g. ??$da_handle_init@M@@...) -> prefix
        # the function name. (A scoped template has a 2nd depth-0 '@'.)
        $injectAt = $opLen
    }
    else {
        # Scoped (namespaced) symbol, template OR not: prefix the OUTERMOST scope
        # (after the last depth-0 '@'), mirroring the Linux namespace rename so
        # e.g. aoclsparse::trsv<T> -> av1_aoclsparse::trsv<T> (not aoclsparse::av1_trsv).
        $injectAt = $lastAt0 + 1
    }

    $tail = $sym.Substring($injectAt)
    if ($tail.StartsWith($tok)) { return (Prefix-MsvcTypes $sym) }
    return (Prefix-MsvcTypes ($sym.Substring(0, $injectAt) + $tok + $tail))
}

function Rename-PlainC([string]$sym) {
    # Case-aware prefixing -- mirrors `_get_intelligent_prefix` in
    # rename_symbols.cmake. Both implementations MUST agree, otherwise the
    # rename map (objcopy input) and the .def export list (CMake-generated
    # by the same logic) disagree, producing undefined symbols at link time.
    #
    # Algorithm:
    #   1. Strip trailing '_' from the prefix to get the "clean" token.
    #   2. Strip leading '_' chars from the symbol; preserve them in output.
    #   3. Detect the case of the remainder:
    #        - all uppercase -> uppercase prefix
    #        - all lowercase -> lowercase prefix
    #        - mixed         -> uppercase prefix
    #   4. Rebuild as <leading_underscores><cased_prefix>[trailing_us]<rest>
    if ($sym.Length -lt 2) { return $sym }

    $cleanPrefix     = $script:Prefix -replace '_+$', ''
    $trailingUs      = if ($script:Prefix -match '(_+)$') { $Matches[1] } else { '' }

    $i = 0
    while ($i -lt $sym.Length -and $sym[$i] -eq '_') { $i++ }
    if ($i -eq $sym.Length) { return $sym }
    $leading = $sym.Substring(0, $i)
    $rest    = $sym.Substring($i)

    $upper = $rest.ToUpperInvariant()
    $lower = $rest.ToLowerInvariant()
    if ($rest -ceq $upper) {
        $pfx = $cleanPrefix.ToUpperInvariant()
    }
    elseif ($rest -ceq $lower) {
        $pfx = $cleanPrefix.ToLowerInvariant()
    }
    else {
        $pfx = $cleanPrefix.ToUpperInvariant()
    }

    # Preserve the full trailing-underscore run (so `myprefix__` stays `myprefix__`).
    $resultPrefix = "$leading$pfx$trailingUs"
    return "$resultPrefix$rest"
}

function Compute-NewSym([string]$sym) {
    if (Should-Skip $sym) { return $null }
    if ($rxItanium.IsMatch($sym)) { $new = Rename-Itanium $sym }
    elseif ($rxMsvc.IsMatch($sym)) { $new = Rename-Msvc $sym }
    else { $new = Rename-PlainC $sym }
    if ($new -eq $sym) { return $null }
    return $new
}

# -- 1. Run llvm-nm and parse output --
Write-Host "[ps-map] Running llvm-nm on $LibFile"
$nmOut = & $LlvmNm --no-sort $LibFile 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Error "llvm-nm failed (exit $LASTEXITCODE)"
    exit 1
}

# Parse:  [hexaddr] <type> <name>
# Type letter set: TDRBWVtdrbwv (matches CMake script)
$rxLine = [regex]::new('^[0-9a-fA-F]* ([TDRBWVtdrbwv]) (.+)$', 'Compiled')
$seen = New-Object 'System.Collections.Generic.HashSet[string]'
$symbols = New-Object 'System.Collections.Generic.List[string]'
foreach ($line in $nmOut) {
    $m = $rxLine.Match($line)
    if ($m.Success) {
        $name = $m.Groups[2].Value.Trim()
        if ($seen.Add($name)) { $symbols.Add($name) | Out-Null }
    }
}
Write-Host "[ps-map] Total symbols (deduped): $($symbols.Count)"

# -- 2. Compute renames and write map file --
$count = 0
$writer = [System.IO.StreamWriter]::new($OutMap, $false, [System.Text.Encoding]::ASCII)
try {
    foreach ($sym in $symbols) {
        $new = Compute-NewSym $sym
        if ($new) {
            $writer.WriteLine("$sym $new")
            $count++
        }
    }
}
finally { $writer.Dispose() }

$sw.Stop()
Write-Host ("[ps-map] Symbols to rename : {0}" -f $count)
Write-Host ("[ps-map] Map written      : {0}" -f $OutMap)
Write-Host ("[ps-map] Elapsed          : {0:N1}s" -f $sw.Elapsed.TotalSeconds)
exit 0

    exit 0
}
elseif ($Mode -eq 'headers') {
$mapFile     = $MapFile
$incDir      = $IncludeDir
$upperPrefix = $UpperPrefix

$map  = New-Object 'System.Collections.Generic.Dictionary[string,string]'
$rxId = [regex]::new('^[A-Za-z_][A-Za-z0-9_]*$', 'Compiled')

# Extract the C++ namespace / global-function identifier that the binary rename
# prefixed for one MSVC-mangled pair, so the header renames the SAME identifier
# and a caller's mangled call matches the renamed library symbol. Mirrors the
# Rename-Msvc inject-point logic in rename_engine_windows.ps1 (-Mode map). Returns @(old,new)
# or $null. (Embedded TYPE tags are handled by the enum/type pass below.)
function Get-MsvcNameRename([string]$old, [string]$new) {
    if (-not $old.StartsWith('?')) { return $null }
    if     ($old.StartsWith('??$')) { $opLen = 3; $isTmpl = $true }
    elseif ($old.Length -ge 4 -and $old[2] -eq '_') { $opLen = 4; $isTmpl = $false }
    elseif ($old.StartsWith('??')) { $opLen = 3; $isTmpl = $false }
    elseif ($old.StartsWith('?'))  { $opLen = 1; $isTmpl = $false }
    else { return $null }
    if ($old.Length -le $opLen) { return $null }
    $depth = 0; $term = -1; $firstAt0 = -1; $lastAt0 = -1; $i = $opLen; $n = $old.Length
    while ($i -lt $n) {
        $c = $old[$i]
        if ($c -eq '?' -and ($i+1) -lt $n -and $old[$i+1] -eq '$') { $depth++; $i += 2; continue }
        if ($c -eq '@' -and ($i+1) -lt $n -and $old[$i+1] -eq '@') { if ($depth -eq 0) { $term = $i; break }; $depth--; $i += 2; continue }
        if ($c -eq '@' -and $depth -eq 0) { if ($firstAt0 -lt 0) { $firstAt0 = $i }; $lastAt0 = $i }
        $i++
    }
    if ($term -lt 0) { return $null }
    if     ($firstAt0 -lt 0) { $injectAt = $opLen }
    elseif ($isTmpl -and ($firstAt0 -eq $lastAt0)) { $injectAt = $opLen }
    else   { $injectAt = $lastAt0 + 1 }
    $endOld = $old.IndexOf('@', $injectAt)
    $endNew = $new.IndexOf('@', $injectAt)
    if ($endOld -lt 0 -or $endNew -lt 0) { return $null }
    $oi = $old.Substring($injectAt, $endOld - $injectAt)
    $ni = $new.Substring($injectAt, $endNew - $injectAt)
    if ($oi -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { return $null }
    if ($ni -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { return $null }
    if ($oi -ceq $ni) { return $null }
    return @($oi, $ni)
}

# 1) Plain-C identifiers + C++ namespace/global-function identifiers from the map.
$cppNameCount = 0
foreach ($line in [System.IO.File]::ReadLines($mapFile)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $sp = $line.IndexOf(' ')
    if ($sp -lt 1) { continue }
    $old = $line.Substring(0, $sp)
    $new = $line.Substring($sp + 1)
    if ($rxId.IsMatch($old)) {
        if (-not $map.ContainsKey($old)) { $map[$old] = $new }
    }
    elseif ($old.StartsWith('?')) {
        $r = Get-MsvcNameRename $old $new
        if ($r -and -not $map.ContainsKey($r[0])) { $map[$r[0]] = $r[1]; $cppNameCount++ }
    }
}
Write-Host ("Plain-C symbols for header rewrite: {0}" -f $map.Count)
Write-Host ("C++ namespace/function identifiers for header rewrite: {0}" -f $cppNameCount)

# 2) CBLAS enum types and enumerator constants (compile-time only,
#    never appear in the binary symbol map). Mirrors the Python rename's
#    apply_cblas_enum_renames(): mixed-case enumerators get the UPPER
#    prefix without an extra underscore.
$cblasEnumTypes = @(
    'CBLAS_ORDER','CBLAS_LAYOUT','CBLAS_TRANSPOSE',
    'CBLAS_UPLO','CBLAS_DIAG','CBLAS_SIDE',
    'CBLAS_IDENTIFIER','CBLAS_STORAGE'
)
$cblasEnumerators = @(
    'CblasRowMajor','CblasColMajor',
    'CblasNoTrans','CblasTrans','CblasConjTrans',
    'CblasUpper','CblasLower',
    'CblasNonUnit','CblasUnit',
    'CblasLeft','CblasRight',
    'CblasForward','CblasBackward',
    'CblasConjNoTrans','CblasPacked',
    'CblasAMatrix','CblasBMatrix'
)
$lapackLayoutMacros = @('LAPACK_ROW_MAJOR','LAPACK_COL_MAJOR')

foreach ($n in $cblasEnumTypes + $cblasEnumerators + $lapackLayoutMacros) {
    if (-not $map.ContainsKey($n)) { $map[$n] = ($upperPrefix + $n) }
}

# 3) OpenRNG VSL_* macros and a couple of typedefs.
$openrngMacros = @(
    'VSL_BRNG_ARS5','VSL_BRNG_DABSTRACT','VSL_BRNG_IABSTRACT',
    'VSL_BRNG_MCG31','VSL_BRNG_MCG59','VSL_BRNG_MRG32K3A',
    'VSL_BRNG_MT19937','VSL_BRNG_MT2203','VSL_BRNG_NIEDERR',
    'VSL_BRNG_NONDETERM','VSL_BRNG_PHILOX4X32X10','VSL_BRNG_R250',
    'VSL_BRNG_SABSTRACT','VSL_BRNG_SFMT19937','VSL_BRNG_SOBOL','VSL_BRNG_WH',
    'VSL_STATUS_OK','VSL_ERROR_OK',
    'VSL_ERROR_BADARGS','VSL_ERROR_FEATURE_NOT_IMPLEMENTED',
    'VSL_ERROR_MEM_FAILURE','VSL_ERROR_NULL_PTR',
    'VSL_RNG_ERROR_BAD_MEM_FORMAT','VSL_RNG_ERROR_BAD_STREAM',
    'VSL_RNG_ERROR_BRNG_NOT_SUPPORTED','VSL_RNG_ERROR_BRNGS_INCOMPATIBLE',
    'VSL_RNG_ERROR_FILE_CLOSE','VSL_RNG_ERROR_FILE_OPEN',
    'VSL_RNG_ERROR_FILE_READ','VSL_RNG_ERROR_FILE_WRITE',
    'VSL_RNG_ERROR_INVALID_BRNG_INDEX',
    'VSL_RNG_ERROR_LEAPFROG_UNSUPPORTED',
    'VSL_RNG_ERROR_NONDETERM_NOT_SUPPORTED',
    'VSL_RNG_ERROR_SKIPAHEADEX_UNSUPPORTED',
    'VSL_RNG_ERROR_SKIPAHEAD_UNSUPPORTED',
    'VSL_DISTR_MULTINOMIAL_BAD_PROBABILITY_ARRAY',
    'VSL_MATRIX_STORAGE_DIAGONAL','VSL_MATRIX_STORAGE_FULL',
    'VSL_MATRIX_STORAGE_PACKED',
    'VSL_QRNG_OVERRIDE_1ST_DIM_INIT',
    'VSL_USER_DIRECTION_NUMBERS','VSL_USER_INIT_DIRECTION_NUMBERS',
    'VSL_USER_PRIMITIVE_POLYMS','VSL_USER_QRNG_INITIAL_VALUES',
    'VSL_RNG_METHOD_BERNOULLI_ICDF','VSL_RNG_METHOD_BINOMIAL_BTPE',
    'VSL_RNG_METHOD_CAUCHY_ICDF',
    'VSL_RNG_METHOD_EXPONENTIAL_ICDF',
    'VSL_RNG_METHOD_EXPONENTIAL_ICDF_ACCURATE',
    'VSL_RNG_METHOD_GAMMA_GNORM','VSL_RNG_METHOD_GAMMA_GNORM_ACCURATE',
    'VSL_RNG_METHOD_GAUSSIAN_BOXMULLER',
    'VSL_RNG_METHOD_GAUSSIAN_BOXMULLER2',
    'VSL_RNG_METHOD_GAUSSIAN_ICDF',
    'VSL_RNG_METHOD_GAUSSIANMV_BOXMULLER',
    'VSL_RNG_METHOD_GAUSSIANMV_BOXMULLER2',
    'VSL_RNG_METHOD_GAUSSIANMV_ICDF',
    'VSL_RNG_METHOD_GEOMETRIC_ICDF',
    'VSL_RNG_METHOD_GUMBEL_ICDF','VSL_RNG_METHOD_LAPLACE_ICDF',
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
    'VSL_RNG_METHOD_WEIBULL_ICDF_ACCURATE'
)
foreach ($n in $openrngMacros) {
    if (-not $map.ContainsKey($n)) { $map[$n] = ($upperPrefix + $n) }
}

# OpenRNG typedef names that may collide with other vendors' VSL headers.
$openrngTypedefs = @('VSLBRngProperties','VSLStreamStatePtr')
foreach ($n in $openrngTypedefs) {
    if (-not $map.ContainsKey($n)) { $map[$n] = ($upperPrefix + $n) }
    # Leading-underscore tag form: keep the underscore at the front
    # (e.g. _VSLBRngProperties -> _AOCL_VSLBRngProperties).
    $tag = '_' + $n
    if (-not $map.ContainsKey($tag)) { $map[$tag] = ('_' + $upperPrefix + $n) }
}

# Bug #1: Fortran routines called by inline wrappers (e.g. sgbrfsx_) that a lib declares but
# doesn't export are absent from the map; add such 'lowercase_(' tokens with the lowercase prefix.
$lowerPrefix = $upperPrefix.ToLowerInvariant()
$rxFortran   = [regex]::new('(?<![A-Za-z0-9_])([a-z][a-z0-9]{2,}_)\s*\(', 'Compiled')
$headers = Get-ChildItem -Path $incDir -Recurse -File -Include '*.h','*.hpp','*.hxx','*.hh'
$fortranAdded = 0
foreach ($hdr in $headers) {
    $txt = [System.IO.File]::ReadAllText($hdr.FullName)
    foreach ($fm in $rxFortran.Matches($txt)) {
        $name = $fm.Groups[1].Value
        if ($name.EndsWith('__')) { continue }         # double-underscore: not a Fortran export form
        if ($map.ContainsKey($name)) { continue }
        $map[$name] = ($lowerPrefix + $name)
        $fortranAdded++
    }
}
Write-Host ("Fortran interface symbols added: {0}" -f $fortranAdded)

# -- AOCL-vs-AOCL coexistence: prefix AOCL-specific library enums, enum --
# constants, typedef names and struct/union tags (DA/Sparse/Compression/Crypto/
# LibM). These do NOT collide with MKL (the CBLAS/OpenRNG passes skip them) but
# ARE identical between two renamed AOCL builds, so two renamed header sets can't
# be included in one TU without prefixing them. Restricted to AOCL-lib headers
# (parity with the Linux Python rename's apply_aocl_lib_type_enum_renames).
$aoclMarkers = @('aoclda','aocl_da','aoclsparse','aocl_compression','amdlibm','aoclutils','aocl_libmem','libmem')
$typeEnumNever = [System.Collections.Generic.HashSet[string]]::new([string[]]@(
    'int','char','short','long','float','double','void','unsigned','signed',
    'const','volatile','static','extern','struct','union','enum','typedef',
    'return','sizeof','size_t','ssize_t','ptrdiff_t','intptr_t','uintptr_t',
    'wchar_t','bool','_Bool','_Complex','FILE','va_list','true','false','NULL','nullptr',
    'int8_t','int16_t','int32_t','int64_t','uint8_t','uint16_t','uint32_t','uint64_t'))
$typeEnumCommon = [System.Collections.Generic.HashSet[string]]::new([string[]]@(
    'on','off','yes','no','none','all','any','min','max','low','high',
    'end','len','size','data','type','mode','base','zero','one','two',
    'in','out','up','down','left','right','top','get','set','add','new'))

function Test-KeepTypeEnum([string]$n) {
    if ([string]::IsNullOrEmpty($n)) { return $false }
    if ($typeEnumNever.Contains($n) -or $typeEnumCommon.Contains($n)) { return $false }
    if ($structAttrKw -contains $n) { return $false }   # alignas/aligned/packed etc.
    if ($n.StartsWith('__') -or $n.Length -le 1) { return $false }
    if ($n -cmatch '^_[A-Z]') { return $false }   # reserved impl types: _Fcomplex/_Complex/_Bool
    if ($n -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { return $false }
    if ($n.Contains('_')) { return $true }
    if (($n -ceq $n.ToUpperInvariant()) -and $n.Length -ge 2) { return $true }
    return ($n.Length -ge 5)
}

function Test-IsAoclLibHeader([string]$path) {
    $p = $path.Replace('\','/').ToLowerInvariant()
    $base = [System.IO.Path]::GetFileName($p)
    if (@('cblas.h','cblas.hh','lapacke.h','lapack.h','openrng.h') -contains $base) { return $false }
    if ($p.Contains('/alcp/') -or $base.StartsWith('alcp') -or $base.StartsWith('rng')) { return $true }
    foreach ($m in $aoclMarkers) { if ($base.Contains($m)) { return $true } }
    return $false
}

# Attribute keywords that may sit between struct/union and the tag name.
$structAttrKw = @('alignas','_Alignas','__attribute__','__declspec','packed','aligned')
function Strip-CComments([string]$s) {
    # Remove /* */ and // so doc-comment braces (LaTeX \text{...}) and trailing
    # enumerators are handled and comment identifiers aren't mis-collected.
    $s = [regex]::Replace($s, '/\*.*?\*/', ' ', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $s = [regex]::Replace($s, '//[^\r\n]*', ' ')
    return $s
}
function Get-LastTagIdent([string]$pre) {
    $pre = [regex]::Replace($pre, '\([^()]*\)', ' ')
    $pre = [regex]::Replace($pre, '\([^()]*\)', ' ')
    $ids = [regex]::Matches($pre, '[A-Za-z_]\w*')
    for ($i = $ids.Count - 1; $i -ge 0; $i--) {
        if ($structAttrKw -notcontains $ids[$i].Value) { return $ids[$i].Value }
    }
    return $null
}

$rxEnum      = [regex]::new('\benum\b\s*(\w+)?\s*\{([^{}]*)\}\s*(\w+)?', ([System.Text.RegularExpressions.RegexOptions]'Compiled, Singleline'))
$rxEnumConst = [regex]::new('([A-Za-z_]\w*)\s*(?:=[^,]*)?(?:,|$)', ([System.Text.RegularExpressions.RegexOptions]'Compiled, Singleline'))
$rxTdStruct  = [regex]::new('\btypedef\s+(?:struct|union)\b([^{;]*?)\{(?:[^{}]|\{[^{}]*\})*\}\s*(\w+)\s*;', ([System.Text.RegularExpressions.RegexOptions]'Compiled, Singleline'))
$rxTdSimple  = [regex]::new('\btypedef\s+[^;{}]+?\b([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*;', 'Compiled')
$rxTag       = [regex]::new('\b(?:struct|union)\s+(?:(?:alignas|_Alignas|__attribute__|__declspec|packed|aligned)\s+)*([A-Za-z_]\w*)', 'Compiled')

$aoclNames = [System.Collections.Generic.HashSet[string]]::new()
foreach ($hdr in $headers) {
    if (-not (Test-IsAoclLibHeader $hdr.FullName)) { continue }
    $raw = [System.IO.File]::ReadAllText($hdr.FullName)
    $txt = Strip-CComments $raw
    $txtNp = [regex]::Replace($txt, '\([^()]*\)', ' ')
    $txtNp = [regex]::Replace($txtNp, '\([^()]*\)', ' ')
    foreach ($m in $rxEnum.Matches($txt)) {
        if ($m.Groups[1].Success) { [void]$aoclNames.Add($m.Groups[1].Value) }
        if ($m.Groups[3].Success) { [void]$aoclNames.Add($m.Groups[3].Value) }
        foreach ($cm in $rxEnumConst.Matches($m.Groups[2].Value)) {
            [void]$aoclNames.Add($cm.Groups[1].Value)
        }
    }
    foreach ($m in $rxTdStruct.Matches($txt)) {
        $tag = Get-LastTagIdent $m.Groups[1].Value
        if ($tag) { [void]$aoclNames.Add($tag) }
        [void]$aoclNames.Add($m.Groups[2].Value)
    }
    foreach ($m in $rxTdSimple.Matches($txt)) { [void]$aoclNames.Add($m.Groups[1].Value) }
    foreach ($m in $rxTag.Matches($txtNp))    { [void]$aoclNames.Add($m.Groups[1].Value) }
}

$aoclMap = New-Object 'System.Collections.Generic.Dictionary[string,string]'
foreach ($n in $aoclNames) {
    if (-not (Test-KeepTypeEnum $n)) { continue }
    if ($n.StartsWith($lowerPrefix) -or $map.ContainsKey($n)) { continue }
    $aoclMap[$n] = ($lowerPrefix + $n)
}
Write-Host ("AOCL-lib enum/type identifiers for coexistence: {0}" -f $aoclMap.Count)

# Bug #3: version inline-wrapper namespaces so the wrapper API is prefixed too. ONLY namespaces
# with NO exported mangled symbols are safe (else header/binary scope mismatch, e.g. Au::/alcp::).
$wrapperNamespaces = @('libflame')
foreach ($ns in $wrapperNamespaces) {
    if (-not $map.ContainsKey($ns)) { $map[$ns] = ($lowerPrefix + $ns) }
}

# Bug #4: match comments and string/char literals as PROTECTED regions and rewrite only
# identifiers outside them (previously names inside // /* */ "..." '...' were renamed too).
# Bug #5: #include directives are PROTECTED too -- an include path token is not a
# symbol. Without this, a library-namespace token in the map (e.g. `alcp`) rewrote
# `#include <alcp/macros.h>` into `#include <coexbalcp/macros.h>`, a path that does
# not exist, breaking the renamed headers. The whole directive line is consumed as
# one protected region so neither <...> nor "..." path components are renamed.
$rxScan = [regex]::new(
    '(//[^\r\n]*)' +                 # 1: line comment
    '|(/\*.*?\*/)' +                 # 2: block comment (Singleline: '.' spans newlines)
    '|(\#[ \t]*include\b[^\r\n]*)' + # 3: #include directive (path tokens protected)
    '|("(?:\\.|[^"\\])*")' +         # 4: string literal
    "|('(?:\\.|[^'\\])*')" +         # 5: char literal
    '|([A-Za-z_][A-Za-z0-9_]*)',     # 6: identifier (only these are rewritten)
    ([System.Text.RegularExpressions.RegexOptions]'Compiled, Singleline'))
$aoclActive = $false
$evaluator = {
    param($m)
    if ($m.Groups[6].Success) {
        $v = $null
        if ($map.TryGetValue($m.Value, [ref]$v)) { return $v }
        if ($aoclActive -and $aoclMap.TryGetValue($m.Value, [ref]$v)) { return $v }
    }
    return $m.Value
}

$updated = 0
Write-Host ("Processing headers    : {0}" -f $headers.Count)
foreach ($hdr in $headers) {
    $content = [System.IO.File]::ReadAllText($hdr.FullName)
    $aoclActive = (Test-IsAoclLibHeader $hdr.FullName)
    $new = $rxScan.Replace($content, $evaluator)
    if ($new -ne $content) {
        [System.IO.File]::WriteAllText($hdr.FullName, $new)
        $updated++
    }
}
Write-Host ("Headers updated: {0} / {1}" -f $updated, $headers.Count)

    exit 0
}
elseif ($Mode -eq 'data') {
    # Extract an import library's DATA-only exports (used by create_dll_windows
    # in rename_symbols_windows.cmake). In an import lib a CODE export appears as
    # both <sym> and __imp_<sym>, but a DATA export appears ONLY as __imp_<sym>
    # (no plain code entry). Emit the data-only base names, one per line, to $Out.
    $ErrorActionPreference = 'Stop'
    if (-not (Test-Path $LlvmNm))    { Write-Error "llvm-nm not found: $LlvmNm"; exit 1 }
    if (-not (Test-Path $ImportLib)) { Write-Error "import lib not found: $ImportLib"; exit 1 }
    $code = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $imp  = [System.Collections.Generic.List[string]]::new()
    # llvm-nm --extern-only lines: "<addr> <type> <name>". Undefined ("U") lines
    # have no address and are skipped by the regex.
    & $LlvmNm --extern-only $ImportLib 2>$null | ForEach-Object {
        if ($_ -match '^[0-9A-Fa-f]* [A-Za-z] (\S+)$') {
            $n = $Matches[1]
            if ($n.StartsWith('__imp_')) { $imp.Add($n.Substring(6)) }
            else { [void]$code.Add($n) }
        }
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $data = [System.Collections.Generic.List[string]]::new()
    foreach ($d in $imp) { if (-not $code.Contains($d) -and $seen.Add($d)) { $data.Add($d) } }
    [System.IO.File]::WriteAllLines($Out, $data)
    Write-Host ("data-only exports: {0}" -f $data.Count)
    exit 0
}
elseif ($Mode -eq 'parobjcopy') {
    # Run llvm-objcopy --redefine-syms=<map> over many library files in parallel
    # (one job per core). Used by rename_symbols.cmake's deferred-objcopy batch;
    # each objcopy rewrites a 30+ MB archive with a 100k+ entry map (~1 min), so
    # serial over many libs dominates rename time. Start-Job / Wait-Job are used
    # for robustness against Start-Process redirection quirks.
    $ErrorActionPreference = 'Stop'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    if (-not (Test-Path $Objcopy))  { Write-Error "objcopy not found: $Objcopy"; exit 1 }
    if (-not (Test-Path $MapFile))  { Write-Error "map file not found: $MapFile"; exit 1 }
    if (-not (Test-Path $LibsFile)) { Write-Error "libs file not found: $LibsFile"; exit 1 }
    $Libs = @(Get-Content $LibsFile | Where-Object { $_.Trim() -ne '' })
    if ($Libs.Count -eq 0) { Write-Error "no libraries listed in $LibsFile"; exit 1 }
    if ($MaxConcurrency -le 0) { $MaxConcurrency = [Environment]::ProcessorCount }
    Write-Host ("[par-objcopy] Libs={0}  MaxConcurrency={1}" -f $Libs.Count, $MaxConcurrency)
    $extraArgs = @('--redefine-syms=' + $MapFile)
    if ($RemoveDrectve) { $extraArgs += @('--remove-section', '.drectve') }
    $worker = {
        param($Tool, $Lib, $ExtraArgs)
        $allArgs = $ExtraArgs + @($Lib)
        $out = & $Tool @allArgs 2>&1
        [pscustomobject]@{ Lib = $Lib; ExitCode = $LASTEXITCODE; Output = ($out | Out-String).Trim() }
    }
    $pending = [System.Collections.Generic.Queue[string]]::new()
    foreach ($l in $Libs) { $pending.Enqueue($l) }
    $jobs    = [System.Collections.Generic.List[object]]::new()
    $results = [System.Collections.Generic.List[object]]::new()
    while ($pending.Count -gt 0 -or $jobs.Count -gt 0) {
        while ($jobs.Count -lt $MaxConcurrency -and $pending.Count -gt 0) {
            $lib = $pending.Dequeue()
            Write-Host ("[par-objcopy]   start  {0}" -f (Split-Path $lib -Leaf))
            $job = Start-Job -ScriptBlock $worker -ArgumentList $Objcopy, $lib, $extraArgs
            $jobs.Add($job) | Out-Null
        }
        $null = Wait-Job -Job $jobs -Any
        $doneJobs = @($jobs | Where-Object { $_.State -in 'Completed','Failed','Stopped' })
        foreach ($j in $doneJobs) {
            $r = Receive-Job -Job $j -ErrorAction SilentlyContinue
            if ($null -eq $r) { $r = [pscustomobject]@{ Lib = '<unknown>'; ExitCode = -1; Output = '<no result>' } }
            if ($r.ExitCode -eq 0) {
                Write-Host ("[par-objcopy]   done   {0}" -f (Split-Path $r.Lib -Leaf))
            } else {
                Write-Host ("[par-objcopy]   FAIL   {0}  rc={1}" -f (Split-Path $r.Lib -Leaf), $r.ExitCode)
                if ($r.Output) { Write-Host ("    " + $r.Output) }
            }
            $results.Add($r) | Out-Null
            Remove-Job -Job $j -Force
            $jobs.Remove($j) | Out-Null
        }
    }
    $sw.Stop()
    $failed = @($results | Where-Object { $_.ExitCode -ne 0 })
    Write-Host ("[par-objcopy] Elapsed: {0:N1}s  Failed: {1}/{2}" -f $sw.Elapsed.TotalSeconds, $failed.Count, $results.Count)
    if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
}
