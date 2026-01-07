#!/usr/bin/env python3
# Copyright (C) 2025, Advanced Micro Devices, Inc. All rights reserved.
"""
Enhanced Symbol Renaming Script with Intelligent Case-Aware Prefixing

This script renames symbols in static libraries and creates shared libraries:
- Static libraries (.a): objcopy (works perfectly)
- Shared libraries (.so): Created from renamed static libraries
- Windows libraries (.lib/.dll): llvm-objcopy (Throwing NotImplementedError)

Key Features:
Intelligent Case-Aware Prefixing:
   - UPPERCASE symbols → UPPERCASE prefix (DGEMM_ → AOCL_DGEMM_)
   - lowercase symbols → lowercase prefix (cblas_dgemm → aocl_cblas_dgemm)
   - Capitalized symbols → Capitalized prefix (CblasNoTrans → Aocl_CblasNoTrans)

Symbol Filtering:
   - Preserves C++ mangled names from renaming

Uses objcopy for symbol renaming and gcc as default compiler for creating shared libraries from renamed static libraries.
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
        base_prefix (str): The base prefix (e.g., "AOCL_")
    
    Returns:
        str: Appropriate prefix based on symbol case pattern
        
    Examples:
        get_intelligent_prefix("cblas_dgemm", "AOCL_") -> "aocl_"
        get_intelligent_prefix("DGEMM_", "AOCL_") -> "AOCL_"
        get_intelligent_prefix("CblasNoTrans", "AOCL_") -> "AOCL_"
        get_intelligent_prefix("LAPACKE_dgetrf", "AOCL_") -> "AOCL_"
        get_intelligent_prefix("_example_api", "AOCL_") -> "_aocl_"
    """
    if not symbol_name or len(symbol_name) == 0:
        return base_prefix
    
    # Remove trailing underscore from base_prefix for analysis
    clean_prefix = base_prefix.rstrip('_')
    
    # Analyze symbol naming patterns
    # Pattern 0: Starts with underscore - preserve ALL leading underscores
    # e.g., "_example_api" -> "_aocl_example_api" (Here aocl_ is a prefix)
    # e.g., "__cpuid_1" -> "__aocl_cpuid_1" (Here aocl_ is a prefix)
    if symbol_name.startswith('_'):
        # Count and preserve ALL leading underscores
        leading_underscores = len(symbol_name) - len(symbol_name.lstrip('_'))
        rest_of_symbol = symbol_name[leading_underscores:]
        
        if not rest_of_symbol:
            return base_prefix
        
        # Determine case pattern of the rest and add trailing underscore for separation
        # Format: leading_underscores + prefix + underscore + rest_of_symbol
        if rest_of_symbol.isupper():
            return '_' * leading_underscores + clean_prefix.upper() + '_'
        elif rest_of_symbol.islower():
            return '_' * leading_underscores + clean_prefix.lower() + '_'
        else:
            return '_' * leading_underscores + clean_prefix.upper() + '_'
    
    # Pattern 1: All uppercase (e.g., "DGEMM_", "SSYEV_")
    if symbol_name.isupper():
        return clean_prefix.upper() + '_'
    
    # Pattern 2: All lowercase (e.g., "cblas_dgemm", "bli_dgemm")
    elif symbol_name.islower():
        return clean_prefix.lower() + '_'
    
    # Pattern 3: Mixed-case (e.g., "CblasNoTrans", "LAPACKE_dgetrf", "getMaxValue")
    # Use uppercase prefix for all mixed-case symbols
    else:
        return clean_prefix.upper() + '_'

def analyze_symbol_case_patterns(symbols):
    """
    Analyze the case patterns in a list of symbols for debugging.
    
    Args:
        symbols (list): List of symbol names
    
    Returns:
        dict: Statistics about case patterns
    """
    patterns = {
        'all_uppercase': 0,
        'all_lowercase': 0,
        'first_upper_mixed': 0,
        'first_lower_mixed': 0,
        'contains_special': 0,
        'other': 0
    }
    
    examples = {pattern: [] for pattern in patterns.keys()}
    
    for symbol in symbols:
        if not symbol:
            continue
            
        if symbol.isupper():
            patterns['all_uppercase'] += 1
            if len(examples['all_uppercase']) < 3:
                examples['all_uppercase'].append(symbol)
        elif symbol.islower():
            patterns['all_lowercase'] += 1
            if len(examples['all_lowercase']) < 3:
                examples['all_lowercase'].append(symbol)
        elif symbol[0].isupper():
            patterns['first_upper_mixed'] += 1
            if len(examples['first_upper_mixed']) < 3:
                examples['first_upper_mixed'].append(symbol)
        elif symbol[0].islower() and any(c.isupper() for c in symbol):
            patterns['first_lower_mixed'] += 1
            if len(examples['first_lower_mixed']) < 3:
                examples['first_lower_mixed'].append(symbol)
        elif any(c.isdigit() or c in ['@', '.', '$'] for c in symbol):
            patterns['contains_special'] += 1
            if len(examples['contains_special']) < 3:
                examples['contains_special'].append(symbol)
        else:
            patterns['other'] += 1
            if len(examples['other']) < 3:
                examples['other'].append(symbol)
    
    return patterns, examples

def generate_mapping(symbols, base_prefix, map_file):
    """Generate mapping file for objcopy with intelligent case-aware prefixing."""
    mapping = {}
    seen_symbols = set()
    prefix_stats = {}
    
    # Filter and deduplicate symbols
    valid_symbols = []
    for sym in symbols:
        if sym and sym not in seen_symbols and should_rename_symbol(sym, base_prefix):
            valid_symbols.append(sym)
            seen_symbols.add(sym)
    
    print(f"Total symbols found: {len(symbols)}")
    print(f"Symbols after filtering: {len(valid_symbols)}")
    
    # Analyze case patterns for debugging (optional)
    if len(valid_symbols) > 0:
        patterns, examples = analyze_symbol_case_patterns(valid_symbols)
        for pattern, count in patterns.items():
            if count > 0:
                pattern_name = pattern.replace('_', ' ').title()
                example_list = ", ".join(examples[pattern][:2])
    
    with open(map_file, 'w') as f:
        for sym in valid_symbols:
            # Get intelligent prefix based on symbol case pattern
            intelligent_prefix = get_intelligent_prefix(sym, base_prefix)
            
            # For symbols with leading underscores, prefix already includes them
            # So we only append the rest of the symbol (without leading underscores)
            if sym.startswith('_'):
                leading_count = len(sym) - len(sym.lstrip('_'))
                new_name = f"{intelligent_prefix}{sym[leading_count:]}"
            else:
                new_name = f"{intelligent_prefix}{sym}"

            # Track prefix usage statistics
            if intelligent_prefix not in prefix_stats:
                prefix_stats[intelligent_prefix] = {'count': 0, 'examples': []}
            prefix_stats[intelligent_prefix]['count'] += 1
            if len(prefix_stats[intelligent_prefix]['examples']) < 3:
                prefix_stats[intelligent_prefix]['examples'].append(f"{sym} -> {new_name}")

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
            # Exclude 'U' (undefined, external references like libc functions)
            if symbol_type in ['T', 'D', 'R', 'B', 'W', 'V', 't', 'd', 'r', 'b', 'w', 'v']:
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
    
    # Get file size for progress indication
    file_size_mb = os.path.getsize(lib_file) / (1024 * 1024)
    
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

def get_symbols_windows(lib_file):
    """Extract symbols using dumpbin on Windows."""
    result = subprocess.run(['dumpbin', '/symbols', lib_file], capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr)
    symbols = []
    for line in result.stdout.splitlines():
        if 'External' in line:
            parts = line.strip().split()
            if len(parts) > 0:
                symbols.append(parts[-1])
    return symbols

def rename_symbols(lib_file, prefix, header_paths=None, create_so=False, so_libs=None, compiler='gcc', linker_flags=None):
    """Main function to rename symbols in libraries.
    
    Args:
        lib_file: Path to the library file
        prefix: Prefix to add to symbols
        header_paths: Paths to header files to update
        create_so: If True, create a shared library from the renamed static library
        so_libs: Additional libraries needed when creating shared library (e.g., ['-lgfortran', '-lm'])
    """
    os_type = platform.system()
    base_name = os.path.splitext(os.path.basename(lib_file))[0]
    # Use consistent map file name
    map_file = f"{base_name}_map.txt"

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
        
        symbol_mapping = generate_mapping(symbols, prefix, map_file)
        
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
        symbols = get_symbols_windows(lib_file)
        symbol_mapping = generate_mapping(symbols, prefix, map_file)
        
        if not symbol_mapping:
            print(f"No symbols to rename in {lib_file}")
            return {}
        
        subprocess.run(['llvm-objcopy', f'--redefine-syms={map_file}', lib_file], check=True)
        print(f"Renaming complete for {lib_file} with prefix '{prefix}' ({len(symbol_mapping)} symbols).")

        if lib_file.lower().endswith('.lib'):
            tmp_dir = 'tmp_objs'
            os.makedirs(tmp_dir, exist_ok=True)
            subprocess.run(['lib', f'/extract:*', lib_file, f'/out:{tmp_dir}'], check=True)
            subprocess.run(['lib', f'/out:{prefix}{base_name}.lib'] +
                           [os.path.join(tmp_dir, f) for f in os.listdir(tmp_dir)], check=True)
            print(f"New static library created: {prefix}{base_name}.lib")

        if lib_file.lower().endswith('.dll'):
            print("Warning: Internal renaming for DLL requires original .obj files and rebuild.")
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

def rename_prototypes_in_header_fast(header_path, symbol_mapping):
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
    
    # OPTIMIZATION 1: Filter to only symbols that ACTUALLY exist in this header
    # This reduces 26K symbols to typically 10-50 symbols per header!
    relevant_symbols = {old: new for old, new in symbol_mapping.items() if old in content}
    
    if not relevant_symbols:
        return False  # No symbols to replace
    
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
    
    if content == original_content:
        return False
    
    # Write renamed content
    try:
        with open(header_path, 'w', encoding='utf-8') as f:
            f.write(content)
        return True
    except:
        return False

def rename_prototypes_in_header(header_path, symbol_mapping, compiled_pattern=None):
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
    
    try:
        # Find which symbols from our mapping exist in this header
        found_symbols = find_symbols_in_header(content, symbol_mapping, compiled_pattern)
        
        if not found_symbols:
            return False
        
        # Replace each symbol using word boundary matching
        # Sort by symbol length (descending) to handle cases where one symbol is substring of another
        sorted_symbols = sorted(found_symbols.keys(), key=len, reverse=True)
        
        total_replacements = 0
        for old_symbol in sorted_symbols:
            new_symbol = symbol_mapping[old_symbol]
            
            # Use word boundary to match only complete symbol names
            pattern = r'\b' + re.escape(old_symbol) + r'\b'
            
            # Count and replace
            new_content, count = re.subn(pattern, new_symbol, content)
            
            if count > 0:
                content = new_content
                total_replacements += count
        
        if total_replacements > 0:
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
    
    print(f"Processing {len(all_header_files)} header files with {len(symbol_mapping)} symbol mappings...")
    
    # Process headers in parallel for speed!
    num_cores = max(2, multiprocessing.cpu_count() - 1)
    
    with multiprocessing.Pool(num_cores) as pool:
        # Create args for each header
        args_list = [(header, symbol_mapping) for header in all_header_files]
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
                linker_flags=linker_flags
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
    
    if len(sys.argv) < 3:
        print("AOCL Symbol Renaming Script - Intelligent Case-Aware Prefixing")
        print("=" * 65)
        print("\nUsage: python rename_symbols.py <package_path> <prefix> [options]")
        print("\nOptions:")
        print("  --create-so             Create shared libraries from renamed static libraries")
        print("  --so-libs 'libs'        Additional libraries (e.g., '-lgfortran -lm -lquadmath')")
        print("  --compiler <path>       Compiler to use (default: gcc)")
        print("  --linker-flags 'flags'  Linker flags to pass")
        print("\nExamples:")
        print("  python rename_symbols.py /path/to/package AOCL_")
        print("  python rename_symbols.py /path/to/package AOCL_ --create-so --so-libs '-lgfortran -lm'")
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
            # Collect all arguments until the next option (starting with --)
            so_libs = []
            for i in range(so_libs_idx + 1, len(sys.argv)):
                arg = sys.argv[i]
                if arg.startswith("--"):
                    break
                so_libs.append(arg)
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
