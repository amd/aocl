# AOCL Build-It-Yourself

AOCL now offers the capability to compile individual libraries and
consolidate them into a unified binary. With the Build-It-Yourself
feature, you can choose one or more AOCL libraries and merge them into a
single library by configuring the appropriate CMake options. This
unified binary is assigned a default name: `libaocl.so`/ `libaocl.a` for
Linux or `aocl.dll`/ `aocl.lib` for Windows. The base name (`aocl`) can
be customized with the `-DAOCL_SINGLE_LIBRARY_NAME=<name>` option. This
approach simplifies integration by eliminating dependencies on library
linking order and preventing API duplication, ensuring smooth and 
efficient incorporation of multiple AOCL libraries.

**Note**

Currently, Build-It-Yourself supports selection of AOCL-BLAS,
AOCL-Utils, AOCL-LAPACK, AOCL-Sparse, AOCL-LibM, AOCL-Compression,
AOCL-Cryptography, AOCL-Data-Analytics, AOCL-LibMem, AOCL-FFTZ,
OpenRNG, and AOCL-DLP libraries.

Additionally, we provide all AOCL library sources as git submodules in 
the `submodules` branch of this repository. This enables offline development 
and ensures consistent versioning across all components, making it easier to 
build and work with the complete AOCL ecosystem without external dependencies.

## Table of Contents

- [AOCL Build-It-Yourself](#aocl-build-it-yourself)
  - [Table of Contents](#table-of-contents)
  - [Project structure](#project-structure)
  - [Working with AOCL Library Sources via Git Submodules](#working-with-aocl-library-sources-via-git-submodules)
  - [Configure Build-It-Yourself](#configure-build-it-yourself)
    - [Linux Prerequisites](#linux-prerequisites)
    - [Windows Prerequisites](#windows-prerequisites)
    - [Clone the Repository](#clone-the-repository)
    - [Configure the Build Options](#configure-the-build-options)
    - [Build the Unified Binary](#build-the-unified-binary)
  - [Examples of Configuration and Build Commands using CMake Presets](#examples-of-configuration-and-build-commands-using-cmake-presets)
    - [Introduction](#introduction)
    - [On Linux](#on-linux)
      - [Single-Thread AOCL](#single-thread-aocl)
      - [Multi-Thread AOCL](#multi-thread-aocl)
    - [On Windows](#on-windows)
  - [Verifying AOCL Installation](#verifying-aocl-installation)
  - [AOCL Manifest](#aocl-manifest)
  - [Testing](#testing)
  - [Symbol Renaming Feature](#symbol-renaming-feature)
    - [Overview](#overview)
      - [C++ Wrapper and Namespace Renaming](#c-wrapper-and-namespace-renaming)
    - [Usage](#usage)
    - [Examples](#examples)
  - [CMake Variables Reference](#cmake-variables-reference)
    - [CMake Options to Select Libraries](#cmake-options-to-select-libraries)
    - [CMake Options for Library Configuration](#cmake-options-for-library-configuration)
    - [CMake Options for Output Library Naming](#cmake-options-for-output-library-naming)
    - [CMake Options for AMD Architecture-Specific Optimizations](#cmake-options-for-amd-architecture-specific-optimizations)
    - [CMake Options for Build Performance](#cmake-options-for-build-performance)
    - [CMake Options to Set Library Source Path](#cmake-options-to-set-library-source-path)
    - [CMake Options to Set GIT Repository and Tag/Branch](#cmake-options-to-set-git-repository-and-tagbranch)
  - [Known Issues](#known-issues)

## Project Structure

The repository is organized as follows:

```text
aocl/
├── CMakeLists.txt      Top-level CMake script that drives the unified build
├── CMakePresets.json   Presets for the supported platforms and compilers
├── commands.txt        Reference build/test commands (including symbol renaming)
├── LICENSE.txt         Consolidated license
├── NOTICES.txt         Third-party notices
├── README.md           This file
├── cmake/              Target-based build modules (per-component scripts + helpers)
├── presets/            Preset fragments included by CMakePresets.json
├── submodules/         AOCL library sources, provided as git submodules
├── symbol_rename/      Symbol-renaming engine (CMake driver + PowerShell/Python)
└── test/               Test sources and their CMake configuration
```

`build/` and `install_package/` are generated at build time (the build tree and
the install output, respectively) and are not part of the committed sources.

**`cmake/`** — one build script per component (`aocl_blas.cmake`,
`aocl_lapack.cmake`, `aocl_sparse.cmake`, `aocl_crypto.cmake`, `aocl_libm.cmake`,
`aocl_compression.cmake`, `aocl_da.cmake`, `aocl_libmem.cmake`, `aocl_utils.cmake`,
`aocl_fftz.cmake`, `aocl_openrng.cmake`, `aocl_dlp.cmake`) that builds the
component in-tree and folds its object files into the unified library, plus the
shared helpers:

- `aocl_options.cmake` — centralized build-options layer.
- `aocl_targets_common.cmake` — common target and staging helpers.
- `aocl_unified.cmake` — assembles the final unified `libaocl`.
- `aocl_gen_def.cmake` — generates the Windows export `.def` file.
- `aocl_gen_manifest.cmake` — embeds the build manifest into the library.

**`symbol_rename/`** — the optional symbol-renaming feature:

- `rename_symbols.cmake` — common CMake driver.
- `rename_symbols_windows.cmake` / `rename_symbols_linux.cmake` — per-platform engines.
- `rename_engine_windows.ps1` (PowerShell) / `rename_engine_linux.py` (Python) —
  perform the actual symbol and header rewriting.

**`test/`** — built when configured with `-DENABLE_TESTS=ON`:

- `CMakeLists.txt` — builds the test executables (registered with CTest).
- `test_aocl_symbols.c` / `test_aocl_symbols.h` — C tests for original and renamed symbols.
- `test_aocl_cpp.cpp` — C++ API tests (original and renamed modes).
- `test_aocl_cpp_templates.cpp` — C++ template-interface tests for AOCL-DA and AOCL-Sparse.
- `mix_libraries.F90` — Fortran test that exercises multiple libraries.
- `test_rename_symbols_cpp.py` — Python unit tests for the symbol/header rewrite logic.

## Working with AOCL Library Sources via Git Submodules

For easier access to all AOCL library sources, we have included the AOCL library sources 
as git submodules under the `submodules` branch of the repository:

``` console
$ git clone --recurse-submodules https://github.com/AMD-AOCL/aocl.git -b submodules
$ cd aocl/submodules  # Navigate to AOCL library sources
```
or
``` console
$ git clone --recurse-submodules git@github.com:AMD-AOCL/aocl.git -b submodules
$ cd aocl/submodules  # Navigate to AOCL library sources
```

The git submodules include: AOCL-BLAS, AOCL-Compression, AOCL-Cryptography, AOCL-DA, AOCL-DLP, 
AOCL-FFTZ, AOCL-LAPACK, AOCL-LibM, AOCL-LibMem, AOCL-ScaLAPACK, AOCL-Sparse, AOCL-Utils, and OpenRNG.

Alternatively, only selected submodules can be downloaded. The following table shows the mapping 
between AOCL library names and their corresponding submodule names:

| AOCL Library Name    | Submodule Name                  |
|-----------------------------|--------------------------|
| **AOCL-BLAS**        | `submodules/blis`               |
| **AOCL-Compression** | `submodules/aocl-compression`   |
| **AOCL-Cryptography**| `submodules/aocl-crypto`        |
| **AOCL-DA**          | `submodules/aocl-data-analytics`|
| **AOCL-DLP**         | `submodules/aocl-dlp`           |
| **AOCL-FFTZ**        | `submodules/aocl-fftz`          |
| **AOCL-LAPACK**      | `submodules/libflame`           |
| **AOCL-LibM**        | `submodules/aocl-libm`          |
| **AOCL-LibMem**      | `submodules/aocl-libmem`        |
| **AOCL-ScaLAPACK**   | `submodules/aocl-scalapack`     |
| **AOCL-Sparse**      | `submodules/aocl-sparse`        |
| **AOCL-Utils**       | `submodules/aocl-utils`         |
| **OpenRNG**          | `submodules/openrng`            |

**Example 1: Download only AOCL-BLAS, AOCL-LAPACK, and AOCL-Utils**
``` console
$ git clone https://github.com/AMD-AOCL/aocl.git -b submodules
$ cd aocl
$ git submodule init
$ git submodule update submodules/blis submodules/libflame submodules/aocl-utils
```

**Example 2: Download only AOCL-Sparse and AOCL-Compression**
``` console
$ git clone https://github.com/AMD-AOCL/aocl.git -b submodules
$ cd aocl
$ git submodule init
$ git submodule update submodules/aocl-sparse submodules/aocl-compression
```

**Note:** AOCL-Utils (`submodules/aocl-utils`) is required as a dependency for all AOCL libraries except AOCL-BLAS. 
When downloading selective submodules, ensure that `submodules/aocl-utils` is included unless you are only building AOCL-BLAS.

This approach provides:
- All AOCL library sources locally available
- Consistent versioning across all components
- Simplified build process without external dependencies
- Offline development capability


## Configure Build-It-Yourself

This section explains how to configure the CMake options and the
procedure to build the unified AOCL binary on both Linux and Windows
platforms. Note that the procedure to configure is the same for both OSs
but the only difference is in the prerequisites for each OS.

The following sub-sections describe the process:

1.  Meeting the prerequisites
2.  Cloning the repository
3.  Configuring the build options
4.  Building the unified binary

### Linux Prerequisites

The following dependencies must be met for installing AOCL on Linux:

-   Target CPU with support for FMA, AVX2 or higher

-   Git

-   Python

-   CMake

-   GCC, g++, and Gfortran

-   AOCC

-   GNU Make (default generator) or Ninja (required only for the Ninja-based
    presets)

-   OpenSSL for AOCL-Cryptography:

    -   Define the environment variable `OPENSSL_INSTALL_DIR` to point
        to OpenSSL installation:

    ``` bash
    $ export OPENSSL_INSTALL_DIR=/home/user/openssl
    ```

-   Boost (header-only, version >= 1.66) for AOCL-Data-Analytics. Only the
    Boost headers are required; no compiled Boost libraries are needed.

    -   Define the environment variable `BOOST_ROOT` to point
        to the Boost installation:

    ``` bash
    $ export BOOST_ROOT=/home/user/boost
    ```

**Note**

To build the AOCL-Cryptography library, the OpenSSL `libcrypto`
development library is required. Set the `OPENSSL_INSTALL_DIR`
environment variable to the path where OpenSSL is installed. Ensure this
directory includes the `include` folder (with `include/openssl/`) and
either `lib` or `lib64`. Within the `lib` or `lib64` folder, verify that
the `libcrypto.so` library is present.

### Windows Prerequisites

The following dependencies must be met for building AOCL on Windows:

-   Target CPU with support for FMA, AVX2 or higher

-   LLVM

-   CMake

-   Microsoft Visual Studio IDE

-   Microsoft Visual Studio tools:

    -   Python development
    -   Desktop development with C++: C++ Clang-Cl for v142 build
        tool(x64/x86)

-   Intel oneAPI (Base and HPC Toolkit): provides the `ifx` Fortran compiler
    and the OpenMP runtime (`libiomp5md`) used on Windows. Required for
    AOCL-LAPACK and AOCL-Data-Analytics (which include Fortran sources) and for
    multithreaded builds. Set the `oneAPI_ROOT` environment variable to the
    toolkit root; the Windows presets reference `ifx` at
    `%oneAPI_ROOT%/compiler/latest/bin/ifx.exe` and the OpenMP runtime at
    `%oneAPI_ROOT%/compiler/latest/lib/libiomp5md.lib`.

-   Ninja (required only for the Ninja-based presets, for example
    `aocl-win-ninja-*`).

-   OpenSSL for AOCL-Cryptography:

    -   Define the environment variable `OPENSSL_INSTALL_DIR` to point
        to OpenSSL installation:

    ``` console
    $ set OPENSSL_INSTALL_DIR=C:/Program Files/OpenSSL-Win64
    ```
-   Boost (header-only, version >= 1.66) for AOCL-Data-Analytics. Only the
    Boost headers are required; set the `BOOST_ROOT` environment variable to
    the Boost installation.

**Note**

To build the AOCL-Cryptography library, the OpenSSL `libcrypto` import
library is required. Set the `OPENSSL_INSTALL_DIR` environment variable
to the directory where OpenSSL is installed. Make sure this directory
includes the `include` and `lib` (or `lib64`) folders. Within the `lib`
or `lib64` folder, ensure that the `libcrypto.lib` import library is
present. (The Windows crypto build also links the system `bcrypt`
library, which requires no additional setup.)

For more information on validated versions of compiler/LLVM, CMake and
Python, OpenSSL, and Boost libraries refer to `Validation Matrix` chapter in 
AOCL userguide document.

To set up and use Build-It-Yourself, you must clone the repository,
configure the build options, and build the unified binary.

### Clone the Repository

Clone the repository together with the bundled AOCL library sources (git
submodules). See
[Working with AOCL Library Sources via Git Submodules](#working-with-aocl-library-sources-via-git-submodules)
for the full clone commands and for fetching only selected library sources.

``` console
$ git clone --recurse-submodules https://github.com/AMD-AOCL/aocl.git -b submodules
$ cd aocl
```

### Configure the Build Options

There are multiple CMake options you can configure. The following
sections explain the CMake options to:

1.  Include or exclude individual AOCL libraries (see
    [CMake Options to Select Libraries](#cmake-options-to-select-libraries)).
2.  Provide the source code for the selected libraries by using one of
    the following options:
    1.  Setting the path of the AOCL libraries source code (see
        [CMake Options to Set Library Source Path](#cmake-options-to-set-library-source-path))
    2.  Setting the GIT repository and tag or branch name (see
        [CMake Options to Set GIT Repository and Tag/Branch](#cmake-options-to-set-git-repository-and-tagbranch))
3.  Static or Shared Library:
    1.  Static Library `-DBUILD_SHARED_LIBS=OFF`
    2.  Shared Library `-DBUILD_SHARED_LIBS=ON` (default)
4.  Select Data Type (LP64 or ILP64):
    1.  LP64 `-DENABLE_ILP64=OFF` (default)
    2.  ILP64 `-DENABLE_ILP64=ON`
5.  Enable or disable threading:
    1.  Multithreading `-DENABLE_MULTITHREADING=ON`
    2.  Single threading `-DENABLE_MULTITHREADING=OFF` (default)
6.  Link Desired OpenMP library using
    `-DOpenMP_libomp_LIBRARY=<path to OpenMP library>` when,
    `-DENABLE_MULTITHREADING=ON`.
7.  Optionally set a custom base name for the unified library using
    `-DAOCL_SINGLE_LIBRARY_NAME=<name>` (default `aocl`).

Here is an example of a configuration command:

**Linux**

``` console
$ cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF
-DENABLE_ILP64=OFF -DENABLE_AOCL_BLAS=ON -DENABLE_AOCL_UTILS=ON 
-DENABLE_AOCL_LAPACK=ON -DENABLE_MULTITHREADING=ON -DOpenMP_libomp_LIBRARY=""
-DCMAKE_INSTALL_PREFIX=$PWD/install_package
```

**Windows**

``` console
$ cmake -S . -B build -G "Visual Studio 17 2022" -DCMAKE_BUILD_TYPE=Release
-DBUILD_SHARED_LIBS=OFF -DENABLE_ILP64=OFF -DENABLE_AOCL_BLAS=ON 
-DENABLE_AOCL_UTILS=ON -DENABLE_AOCL_LAPACK=ON -DENABLE_MULTITHREADING=ON -TClangCl
-DCMAKE_INSTALL_PREFIX=%CD%/install_package -DCMAKE_CONFIGURATION_TYPES=Release
```

### Build the Unified Binary

Use the following command to build the unified binary:

``` console
$ cmake --build build --config Release --target install
```

## Examples of Configuration and Build Commands using CMake Presets

### Introduction

The AOCL project provides a set of CMake presets to simplify the
configuration and build process for different platforms and compilers.
Some of these presets are:

1.   **aocl-linux-make-lp-ga-gcc-config**: Linux with GNU Make and GCC
2.   **aocl-linux-make-ilp-ga-gcc-config**: Linux with GNU Make and GCC
    (ILP64)
3.   **aocl-linux-make-lp-ga-aocc-config**: Linux with GNU Make and AOCC
4.   **aocl-linux-make-ilp-ga-aocc-config**: Linux with GNU Make and AOCC
    (ILP64)
5.   **aocl-win-msvc-lp-ga-config**: Windows with Visual Studio and
    Clang/LLVM
6.   **aocl-win-msvc-ilp-ga-config**: Windows with Visual Studio and
    Clang/LLVM (ILP64)
7.   **aocl-win-ninja-lp-ga-config**: Windows with Ninja and Clang/LLVM
8.   **aocl-win-ninja-ilp-ga-config**: Windows with Ninja and Clang/LLVM
    (ILP64)

Details of **aocl-linux-make-lp-ga-gcc-config** are given here.

The `aocl-linux-make-lp-ga-gcc-config` preset is a convenient and
efficient way to build AOCL on Linux platforms with GCC. It provides a
stable, production-ready configuration while allowing flexibility for
customization based on specific requirements.

-   How is the Name Derived?

    -   **aocl**: Refers to AMD Optimized Libraries.
    -   **linux**: Indicates that the preset is for Linux platforms.
    -   **make**: Specifies the use of the GNU Make build system.
    -   **lp**: Refers to the LP64 data model, which is the default for
        most Linux systems.
    -   **ga**: Stands for General Availability Release, indicating that
        this preset is stable and production-ready.
    -   **gcc**: Specifies the use of the GCC compiler.

-   Default Configuration: By default, this preset builds a shared
    multithreaded library. It can be customized to build static or
    single-threaded libraries by modifying the relevant CMake variables.

    -   **CMAKE_BUILD_TYPE**: `Release` (default) Specifies that the build
        is optimized for performance.
    -   **BUILD_SHARED_LIBS**: `ON` Indicates that shared libraries are
        built by default.
    -   **ENABLE_ILP64**: `OFF` Configures the build to use the LP64
        data model.
    -   **ENABLE_MULTITHREADING**: `ON` Enables multithreading support
        by default.
    -   **CMAKE_C_COMPILER**: `gcc` Specifies GCC as the C compiler.
    -   **CMAKE_CXX_COMPILER**: `g++` Specifies G++ as the C++ compiler.
    -   **CMAKE_Fortran_COMPILER**: `gfortran` Specifies GFortran as the
        Fortran compiler.

-   Required Environment Variables: Before running this preset, ensure
    the following environment variables are set:

    1.  **OPENSSL_INSTALL_DIR**: Points to the directory where OpenSSL
        is installed. This is required for building the
        AOCL-Cryptography library. Ensure this directory contains the
        `include` folder and either the `lib` or `lib64` folder with
        the `libcrypto.so` library.

    2.  **ONEAPI_ROOT / oneAPI_ROOT**: Specifies the root directory of
        the Intel oneAPI toolkit. Use **ONEAPI_ROOT** for Linux and
        **oneAPI_ROOT** for Windows. This is **mandatory for Windows**
        and **optional for Linux**. It is required if you want to use
        the Intel OpenMP runtime library.

        -   **Linux**: The library is typically located at:
            `$env{ONEAPI_ROOT}/compiler/latest/lib/libiomp5.so`.
        -   **Windows**: The library is typically located at:
            `$env{oneAPI_ROOT}/compiler/latest/lib/libiomp5md.lib`.

        Ensure that the appropriate environment variable (`ONEAPI_ROOT`
        or `oneAPI_ROOT`) is set to the correct path where the oneAPI
        toolkit is installed.

-   Example Command to Use This Preset: To configure the build using
    this preset, run the following command:

    ``` bash
    $ cmake --preset aocl-linux-make-lp-ga-gcc-config --fresh
    ```

    This command will set up the build environment with the predefined
    configuration for this preset.

-   Customization Options: You can customize the build by overriding the
    default CMake variables. For example:

    -   To build a static library, set `-DBUILD_SHARED_LIBS=OFF`.
    -   To disable multithreading, set `-DENABLE_MULTITHREADING=OFF`.

    For more customization options, refer to
    [Configure the Build Options](#configure-the-build-options).

### On Linux

The following sections provide examples of configuration and build
commands on Linux using the CMake build system.

**Note**

Use the `-DOpenMP_libomp_LIBRARY` option to link the desired
OpenMP library.

#### Single-Thread AOCL

Complete the following steps to build and install a single-thread AOCL:

1.  Configure the library as required:

    ``` bash
    # CMake commands

    # GCC (Default) and LP64 
    $ cmake --preset aocl-linux-make-lp-ga-gcc-config -DENABLE_MULTITHREADING=OFF --fresh 

    # GCC and ILP64
    $ cmake --preset aocl-linux-make-ilp-ga-gcc-config -DENABLE_MULTITHREADING=OFF --fresh 

    # AOCC and LP64 
    $ cmake --preset aocl-linux-make-lp-ga-aocc-config -DENABLE_MULTITHREADING=OFF --fresh 

    # AOCC and ILP64
    $ cmake --preset aocl-linux-make-ilp-ga-aocc-config -DENABLE_MULTITHREADING=OFF --fresh 
    ```

2.  Build the unified binary and install using the command:

    ``` bash
    $ cmake --build build --config Release -j --target install
    ```

#### Multi-Thread AOCL

Complete the following steps to install a multi-thread AOCL:

1.  Configure the library as required:

    ``` bash
    # CMake commands

    # GCC (Default) and LP64 
    $ cmake --preset aocl-linux-make-lp-ga-gcc-config --fresh 

    # GCC and ILP64
    $ cmake --preset aocl-linux-make-ilp-ga-gcc-config --fresh 

    # AOCC and LP64 
    $ cmake --preset aocl-linux-make-lp-ga-aocc-config --fresh 

    # AOCC and ILP64
    $ cmake --preset aocl-linux-make-ilp-ga-aocc-config --fresh 

    # GCC (Default) and LP64 with Desired OpenMP library Path
    $ cmake --preset aocl-linux-make-lp-ga-gcc-config --fresh -DOpenMP_libomp_LIBRARY=<path to OpenMP library>
    ```

2.  Build the unified binary and install using the command:

    ``` bash
    $ cmake --build build --config Release -j --target install
    ```

### On Windows

**Configure the Project in Command Prompt**

``` console
# CMake commands using Visual Studio 17 2022 Generator
"C:\\Program Files\\Microsoft Visual Studio\\2022\\Community\\VC\\Auxiliary\\Build\\vcvarsall.bat"  x64

# Clang/LLVM (Default) and LP64 
$ cmake --preset aocl-win-msvc-lp-ga-config --fresh 

# Clang/LLVM and ILP64
$ cmake --preset aocl-win-msvc-ilp-ga-config --fresh 

# Clang/LLVM (Default) and LP64 with Desired OpenMP library Path
$ cmake --preset aocl-win-msvc-lp-ga-config --fresh -DOpenMP_libomp_LIBRARY=<path to OpenMP library>
```

``` console
# CMake commands using Ninja Generator

$ "C:\\Program Files\\Microsoft Visual Studio\\2022\\Community\\VC\\Auxiliary\\Build\\vcvarsall.bat"  x64
$ set PATH="C:\\Program Files\\Microsoft Visual Studio\\2022\\Community\\Common7\\IDE\\CommonExtensions\\Microsoft\\CMake\\Ninja";%PATH%

# Clang/LLVM (Default) and LP64 
$ cmake --preset aocl-win-ninja-lp-ga-config --fresh 

# Clang/LLVM and ILP64
$ cmake --preset aocl-win-ninja-ilp-ga-config --fresh 

# Clang/LLVM (Default) and LP64 with Desired OpenMP library Path
$ cmake --preset aocl-win-ninja-lp-ga-config --fresh -DOpenMP_libomp_LIBRARY=<path to OpenMP library>
```

**Build the Project in Command Prompt**

``` console
$ cmake --build build --config Release --target install
```

## Verifying AOCL Installation

The AOCL package will be installed in the `install_package` directory
which is created inside the AOCL source directory.

There are two subfolders within the `install_package` folder: `lib` and
`include`.

-   The `include` folder contains the header files required for using
    the AOCL libraries in applications.
-   The `lib` folder contains the compiled binaries:
    -   On Linux: `libaocl.so` and `libaocl.a`.
    -   On Windows: `aocl.dll` and `aocl.lib`.

When symbol renaming is enabled, the renamed libraries are installed under
`install_package/renamed/lib/` (see
[Symbol Renaming Feature](#symbol-renaming-feature)). If a custom
`-DAOCL_SINGLE_LIBRARY_NAME` was set, the binaries are named accordingly.

## AOCL Manifest

Every unified AOCL binary is **self-describing**: at build time (after all
components install, so their versions can be harvested) the build generates a
small manifest that records exactly how the library was configured and which
component versions it contains. The manifest is:

- **Embedded** directly into the unified library — on Linux/ELF it lives in a
  dedicated `.aocl_manifest` section of `libaocl.so` and `libaocl.a`; on Windows
  it is embedded inside `aocl.dll` / `aocl.lib` and is discoverable as printable
  strings. An accessor `const char *aocl_get_manifest(void);` is exported so it
  can also be read at runtime.
- **Shipped as a plain-text sidecar** at `install_package/lib/aocl_manifest.txt`,
  which is the easiest way to inspect it without any tooling.

When symbol renaming is enabled, the manifest embedded in the renamed libraries
under `install_package/renamed/lib/` additionally records the applied prefix in
the `symbol_prefix:` field.

### Manifest Contents

The manifest is delimited by `AOCL-MANIFEST-BEGIN` / `AOCL-MANIFEST-END` and
contains the following fields:

| Field | Description |
| --- | --- |
| `library` | Unified library base name (e.g. `libaocl` on Linux, `aocl` on Windows, or a custom `-DAOCL_SINGLE_LIBRARY_NAME`). |
| `build_date` | UTC build timestamp. |
| `linkage` | `static` or `shared`. |
| `integer_size` | `lp64` (32-bit ints) or `ilp64` (64-bit ints). |
| `threading` | Threading model (e.g. `single`, `openmp`). |
| `threading_library` | The threading runtime linked (e.g. the OpenMP library), when applicable. |
| `architecture` | Target architecture family (e.g. `amdzen`). |
| `symbol_prefix` | The symbol-rename prefix — present **only** when the library was built with `-DSYMBOL_RENAME_PREFIX`. |
| `build_type` | CMake build type (e.g. `Release`). |
| `compiler` | Compiler used for the build. |
| `component_count` | Number of AOCL components merged into the unified library. |
| `components` | A list of `- name:` / `version:` entries, one per included component (AOCL-Utils, AOCL-BLAS, AOCL-LAPACK, AOCL-Sparse, AOCL-DA, AOCL-LibM, AOCL-Compression, AOCL-Crypto, AOCL-OpenRNG, AOCL-FFTZ, AOCL-DLP, …). |

### Inspecting the Manifest in a Binary

The most portable option is simply to read the installed text sidecar:

```bash
cat install_package/lib/aocl_manifest.txt          # Linux
type install_package\lib\aocl_manifest.txt         # Windows
```

To read the manifest **directly out of a binary**:

**On Linux** — dump the dedicated ELF section with `readelf` (works for the
shared library):

```bash
readelf -p .aocl_manifest install_package/lib/libaocl.so
```

For the static archive (or as a generic fallback that works for both), extract
the manifest block with `strings`:

```bash
strings -n 4 install_package/lib/libaocl.a | grep -A60 AOCL-MANIFEST-BEGIN
```

**On Windows** — the manifest is stored as printable strings inside the binary,
so extract it with `llvm-strings` and filter for the manifest fields with
`findstr` (each manifest field is emitted on its own line):

```bat
"C:\Program Files\LLVM\bin\llvm-strings.exe" -n 4 "install_package\lib\aocl.dll" ^
  | findstr /b /c:"AOCL-MANIFEST" /c:"library:" /c:"build_date:" /c:"linkage:" ^
    /c:"integer_size:" /c:"threading:" /c:"threading_library:" /c:"architecture:" ^
    /c:"symbol_prefix:" /c:"build_type:" /c:"compiler:" /c:"component_count:" ^
    /c:"  - name:" /c:"    version:"
```

> The same commands work on the renamed binaries under
> `install_package/renamed/lib/` — there the manifest also reports the
> `symbol_prefix:` that was applied.

## Testing

The AOCL Build-It-Yourself project includes comprehensive test executables to validate library functionality. 
Tests can be enabled by setting `-DENABLE_TESTS=ON` during CMake configuration.

**Build with Tests:**
```bash
cmake --preset aocl-linux-make-lp-ga-gcc-config \
  -DENABLE_TESTS=ON

cd build
cmake --build . --target install -j 10
cmake --build . --target test_original_symbols -j 10
./test/test_original_symbols
```

**Test Coverage:**
- Test functions covering 10 AOCL libraries
- Tests include: BLAS, LAPACK, Sparse, LibM, Crypto, Compression, Data Analytics, LibMem, Utils, OpenRNG
- Validates library functionality and API correctness

**Symbol Renaming Tests:**

When symbol renaming is enabled (with `-DSYMBOL_RENAME_PREFIX=<prefix>`), an additional test executable 
`test_renamed_symbols` is built to validate renamed symbols:

```bash
cmake --preset aocl-linux-make-lp-ga-gcc-config \
  -DENABLE_TESTS=ON \
  -DENABLE_AOCL_LIBMEM=OFF \
  -DSYMBOL_RENAME_PREFIX=AOCL_

cd build
cmake --build . --target install -j 10
cmake --build . --target test_original_symbols test_renamed_symbols -j 10
./test/test_original_symbols      # Tests original symbols
./test/test_renamed_symbols       # Tests renamed symbols with prefix
```

**Test executables:** In addition to the C symbol test (`test_original_symbols`), the suite builds C++ API tests 
(`test_cpp_original_symbols`, from `test_aocl_cpp.cpp`) and C++ template-interface tests 
(`test_cpp_templates_original`, from `test_aocl_cpp_templates.cpp`) when the relevant libraries are enabled, plus a 
Fortran mixed-library test (`mix_libraries`). When symbol renaming is enabled (`-DSYMBOL_RENAME_PREFIX=<prefix>`), a 
renamed counterpart of each is also built (`test_renamed_symbols`, `test_cpp_renamed_symbols`, 
`test_cpp_templates_renamed`, `mix_libraries_renamed`) that links the renamed libraries under `install_package/renamed/lib/`. All tests are 
registered with CTest, so running `ctest` from the `build` directory executes the full suite.

In addition to runtime tests, C++ symbol/header rewrite behavior is validated by unit tests in:

- `test/test_rename_symbols_cpp.py`

These tests verify C++ mangled symbol rewriting, namespace fallback updates, API family rewrite behavior, and C++ wrapper identifier renaming in generated headers.

For detailed build commands and troubleshooting, see `commands.txt` in the project root.

## Symbol Renaming Feature

### Overview

AOCL Build-It-Yourself now supports automatic symbol renaming with custom prefixes. This feature allows multiple versions 
of AOCL libraries to coexist in the same application or system without symbol conflicts. For example, you can have both 
AOCL 5.1 and AOCL 5.2 installed simultaneously by using different prefixes (e.g., `AOCL51_` and `AOCL52_`).

**Key Features:**
- **Custom Prefix**: Add any prefix to all exported symbols (e.g., `AOCL_`, `AOCL51_`, `MYLIB_`)
- **Case-Aware Renaming**: Automatically applies correct case for different symbol types
  - Symbols beginning with uppercase letters (e.g., `DGEMM_` → `AOCL_DGEMM_`, `LAPACKE_dgetrf` → `AOCL_LAPACKE_dgetrf`)
  - Symbols beginning with lowercase letters (e.g., `cblas_dgemm` → `aocl_cblas_dgemm`)
- **Automatic Process**: Symbol renaming happens automatically during installation
- **Testing Support**: Built-in test executables to validate both original and renamed symbols

### C++ Wrapper and Namespace Renaming

Recent updates address C++ header-level renaming gaps that were not always covered by binary symbol replacement alone.

**What is now handled:**

- C++ namespace fallback rewrites in wrapper headers:
    - `namespace blis` → `<prefix>blis` (for example, `aocl_blis` with prefix `aocl_`, or `aoclblis` with prefix `aocl`)
    - `namespace libflame` → `<prefix>libflame` (for example, `aocl_libflame` with prefix `aocl_`, or `aocllibflame` with prefix `aocl`)
- C++ wrapper identifier rewrites in selected wrapper headers:
    - `blis.hh` (for wrapper APIs such as `rotg`, `gemm`, etc.)
    - `libflame_interface.hh` (for wrapper APIs such as `potrf`, `getrf`, etc.)
- API-family header rewrites for declarations/wrappers not present as concrete binary symbols:
    - `cblas_*`, `lapacke_*`, `blis_*`, `bli_*`, `da_*`, `aoclsparse_*`

**Safety rules applied during header rewrites:**

- Function-like identifiers are rewritten only when they are callable tokens.
- Type/callback-like identifiers (for example, DA callback typedef names such as `*_t_*`) are not rewritten.
- `std::` and C++ ABI/runtime symbols are excluded from mangled-symbol renaming.
- Mangled C++ prefix token preserves caller intent for trailing underscore (for example, prefix `aocl` produces `aoclfoo`, while `AOCL_` produces `AOCL_foo`).


### Usage

**Important:** Symbol renaming is **not compatible with AOCL-LibMem**. LibMem uses IFUNC (indirect functions) 
for runtime CPU dispatch, which requires standard C library names (memcpy, memset, etc.) and cannot be renamed. 
If you enable both LibMem and symbol renaming, the build will fail with an error. Because the GA presets 
enable LibMem by default, pass `-DENABLE_AOCL_LIBMEM=OFF` whenever you set `-DSYMBOL_RENAME_PREFIX` (as shown 
in the examples below).

To enable symbol renaming, add the `-DSYMBOL_RENAME_PREFIX=<prefix>` option when configuring CMake:

```bash
cmake --preset aocl-linux-make-lp-ga-gcc-config \
  -DENABLE_TESTS=ON \
  -DENABLE_AOCL_LIBMEM=OFF \
  -DSYMBOL_RENAME_PREFIX=AOCL_
```

**Configuration Options:**
- **With Symbol Renaming**: `-DSYMBOL_RENAME_PREFIX=AOCL_` (or any custom prefix)
- **Without Symbol Renaming**: Omit the option or use `-DSYMBOL_RENAME_PREFIX=""`

**Build Process:**
```bash
cd build
cmake --build . --target install -j 10
```

**Installation Structure:**
- Original libraries: `install_package/lib/`
- Renamed libraries: `install_package/renamed/lib/`

### Examples

**1. Default AOCL_ Prefix:**
```bash
cmake --preset aocl-linux-make-lp-ga-gcc-config -DENABLE_AOCL_LIBMEM=OFF -DSYMBOL_RENAME_PREFIX=AOCL_
```
Result: `DGEMM_` → `AOCL_DGEMM_`, `cblas_dgemm` → `aocl_cblas_dgemm`

**2. Multi-Version Deployment:**
```bash
# Build AOCL 5.1 with prefix
cmake -DSYMBOL_RENAME_PREFIX=AOCL51_ ...

# Build AOCL 5.2 with different prefix
cmake -DSYMBOL_RENAME_PREFIX=AOCL52_ ...
```
Result: Both versions can coexist in the same application

**3. Custom Company Prefix:**
```bash
cmake --preset aocl-linux-make-lp-ga-gcc-config -DENABLE_AOCL_LIBMEM=OFF -DSYMBOL_RENAME_PREFIX=MYCOMPANY_
```
Result: `DGEMM_` → `MYCOMPANY_DGEMM_`, `cblas_dgemm` → `mycompany_cblas_dgemm`

## CMake Variables Reference

This section provides a detailed reference for the CMake variables used
to configure the Build-It-Yourself AOCL project. These variables allow
customization of the build process, including selecting libraries and
specifying source paths. Use these options to tailor the unified AOCL
binary to specific requirements.

### CMake Options to Select Libraries

The following table lists the CMake variables used to include or exclude
individual AOCL libraries.

| CMake Variable or Option  | Usage |
|---------------------------|---------------------------------------------------------------|
| **ENABLE_AOCL_UTILS**     | `-DENABLE_AOCL_UTILS=ON` (default) or `-DENABLE_AOCL_UTILS=OFF` to exclude from the library. |
| **ENABLE_AOCL_BLAS**      | `-DENABLE_AOCL_BLAS=OFF` (default) or `-DENABLE_AOCL_BLAS=ON` to include in the library. |
| **ENABLE_AOCL_LAPACK**    | `-DENABLE_AOCL_LAPACK=OFF` (default) or `-DENABLE_AOCL_LAPACK=ON` to include in the library. |
| **ENABLE_AOCL_SPARSE**    | `-DENABLE_AOCL_SPARSE=OFF` (default) or `-DENABLE_AOCL_SPARSE=ON` to include in the library. |
| **ENABLE_AOCL_CRYPTO**    | `-DENABLE_AOCL_CRYPTO=OFF` (default) or `-DENABLE_AOCL_CRYPTO=ON` to include in the library. |
| **ENABLE_AOCL_LIBM**      | `-DENABLE_AOCL_LIBM=OFF` (default) or `-DENABLE_AOCL_LIBM=ON` to include in the library. |
| **ENABLE_AOCL_COMPRESSION** | `-DENABLE_AOCL_COMPRESSION=OFF` (default) or `-DENABLE_AOCL_COMPRESSION=ON` to include in the library. |
| **ENABLE_AOCL_DA**        | `-DENABLE_AOCL_DA=OFF` (default) or `-DENABLE_AOCL_DA=ON` to include in the library. |
| **ENABLE_AOCL_LIBMEM**    | `-DENABLE_AOCL_LIBMEM=OFF` (default) or `-DENABLE_AOCL_LIBMEM=ON` to include in the library. |
| **ENABLE_AOCL_FFTZ**      | `-DENABLE_AOCL_FFTZ=OFF` (default) or `-DENABLE_AOCL_FFTZ=ON` to include AOCL-FFTZ in the library. |
| **ENABLE_AOCL_OPENRNG**   | `-DENABLE_AOCL_OPENRNG=OFF` (default) or `-DENABLE_AOCL_OPENRNG=ON` to include OpenRNG in the library. Auto-enables AOCL-LibM, which OpenRNG's AOCL flavour depends on. |
| **ENABLE_AOCL_DLP**       | `-DENABLE_AOCL_DLP=OFF` (default) or `-DENABLE_AOCL_DLP=ON` to include AOCL-DLP in the library. AOCL-DLP is a dependency of AOCL-DA on non-Windows platforms and is auto-enabled with AOCL-DA there. |

### CMake Options for Library Configuration

The following table lists additional CMake variables used to configure how selected AOCL libraries integrate and interact with each other.

| CMake Variable or Option  | Usage |
|---------------------------|---------------------------------------------------------------|
| **ENABLE_AOCL_LAPACK_BLAS_COUPLING**      | `-DENABLE_AOCL_LAPACK_BLAS_COUPLING=OFF` (default) or `-DENABLE_AOCL_LAPACK_BLAS_COUPLING=ON` to enable tight coupling between AOCL-LAPACK and AOCL-BLAS library. This option controls whether AOCL-LAPACK should be tightly integrated with AOCL-BLAS implementation. **Note:** This is different from `ENABLE_AOCL_BLAS`, which controls whether to include AOCL-BLAS into the unified library. |

### CMake Options for Output Library Naming

The following table lists the CMake variable used to set the name of the unified AOCL library.

| CMake Variable or Option  | Usage |
|---------------------------|---------------------------------------------------------------|
| **AOCL_SINGLE_LIBRARY_NAME** | `-DAOCL_SINGLE_LIBRARY_NAME=<name>` sets the base name of the unified library (default `aocl`); this value is also used as the CMake project name. The produced binary is named after it: `<name>.dll` and `<name>.lib` on Windows, and `lib<name>.so` and `lib<name>.a` on Linux. When symbol renaming is enabled, the renamed umbrella library under `install_package/renamed/lib/` uses the same base name. |

### CMake Options for AMD Architecture-Specific Optimizations

The following table lists the CMake variable used to enable ISA-specific optimizations for AMD processors.

| CMake Variable or Option  | Usage |
|---------------------------|---------------------------------------------------------------|
| **AMD_CONFIG**            | `-DAMD_CONFIG=<value>` to enable architecture-specific optimizations. Supported values: `zen`, `zen2`, `zen3`, `zen4`, `zen5`, `amdzen`. If not specified (empty), defaults to `amdzen` for generic AMD builds. |

**AMD_CONFIG Impact on Libraries:**

- **AOCL-BLAS (BLIS)**: Maps directly to `BLIS_CONFIG_FAMILY` configuration.
- **AOCL-LAPACK (LibFlame)**: 
  - `zen`, `zen2`, `zen3` → AVX2-STRICT optimizations
  - `zen4`, `zen5` → AVX512-STRICT optimizations
  - Default: AVX2
- **AOCL-LibM**: 
  - `zen` → Static dispatch with AVX2
  - `zen2` → Static dispatch with ZEN2
  - `zen3` → Static dispatch with ZEN3
  - `zen4` → Static dispatch with ZEN4
  - `zen5` → Static dispatch with ZEN5
  - Default: Dynamic dispatch (runtime detection)
- **AOCL-DA**:
    - `zen`, `zen2` → `znver2`
    - `zen3` → `znver3`
    - `zen4` → `znver4`
    - `zen5` → `znver5`
    - `amdzen` → `dynamic`
    - Default: `dynamic`
- **AOCL-Sparse**:
    - `zen`, `zen2`, `zen3` → `OFF` (AVX512 code paths disabled at build time)
    - `zen4`, `zen5`, `amdzen` → `ON` (AVX512 code paths enabled at build time)
    - Default: `ON`
    - Runtime dispatch remains automatic and can be guided using `AOCL_ENABLE_INSTRUCTIONS`

**Examples:**

```bash
# Build with Zen 4 optimizations (AVX512 for LAPACK and LibM)
$ cmake --preset aocl-linux-make-lp-ga-gcc-config -DAMD_CONFIG=zen4 --fresh

# Build with Zen 2 optimizations (AVX2 for LAPACK, static dispatch for LibM)
$ cmake --preset aocl-linux-make-lp-ga-gcc-config -DAMD_CONFIG=zen2 --fresh

# Build with generic AMD optimizations (dynamic dispatch)
$ cmake --preset aocl-linux-make-lp-ga-gcc-config -DAMD_CONFIG=amdzen --fresh
```

### CMake Options for Build Performance

The unified AOCL build compiles every enabled component in-tree (via
FetchContent + `add_subdirectory`), so build parallelism is controlled by the
standard CMake build-tool options rather than a project-specific variable. Pass
`-j` / `--parallel` (optionally with a core count) to `cmake --build`:

```bash
# Use all available cores (best on machines with enough RAM per core)
$ cmake --build build --config Release --target install -j

# Cap the job count on memory-constrained machines (see the note below)
$ cmake --build build --config Release --target install -j <N>
```

**Note:** Build parallelism is limited by *available memory*, not by core count.
On high-core-count machines (for example, 96- or 128-core servers) with ample
RAM, use all cores (`-j`) for the fastest build -- dropping to a small fixed
number such as `-j 8` would leave most of the machine idle. The large
translation units in AOCL-BLAS/LAPACK/DA only cause trouble when the number of
concurrent jobs outpaces available RAM, so keep the job count at roughly
`min(cores, free_GB / 2)`. See
[Out-of-memory (OOM) during a fully parallel build](#out-of-memory-oom-during-a-fully-parallel-build)
for a ready-to-use command that computes a memory-safe job count.


### CMake Options to Set Library Source Path

The following table lists CMake variables to specify the path of AOCL
library sources. These variables are useful when local copies of the
repositories are available, particularly in environments without
internet access.

| CMake Variable or Option  | Usage |
|---------------------------|---------------------------------------------------------------|
| **UTILS_PATH**           | `-DUTILS_PATH=<Directory Path where AOCL-Utils is present>`. |
| **BLAS_PATH**            | `-DBLAS_PATH=<Directory Path where AOCL-BLAS is present>`. |
| **LAPACK_PATH**          | `-DLAPACK_PATH=<Directory Path where AOCL-LAPACK is present>`. |
| **SPARSE_PATH**          | `-DSPARSE_PATH=<Directory Path where AOCL-Sparse is present>`. |
| **CRYPTO_PATH**          | `-DCRYPTO_PATH=<Directory Path where AOCL-Cryptography is present>`. |
| **LIBM_PATH**            | `-DLIBM_PATH=<Directory Path where AOCL-LibM is present>`. |
| **COMPRESSION_PATH**     | `-DCOMPRESSION_PATH=<Directory Path where AOCL-Compression is present>`. |
| **DA_PATH**              | `-DDA_PATH=<Directory Path where AOCL-Data-Analytics is present>`. |
| **LIBMEM_PATH**          | `-DLIBMEM_PATH=<Directory Path where AOCL-LibMem is present>`. |
| **FFTZ_PATH**            | `-DFFTZ_PATH=<Directory Path where AOCL-FFTZ is present>`. |
| **OPENRNG_PATH**         | `-DOPENRNG_PATH=<Directory Path where OpenRNG is present>`. |
| **DLP_PATH**             | `-DDLP_PATH=<Directory Path where AOCL-DLP is present>`. |

### CMake Options to Set GIT Repository and Tag/Branch

The following table lists CMake variables to specify the GIT repository
and tag or branch name for cloning individual AOCL libraries. If the
source code path is not provided, CMake uses the specified GIT
repository and tag or branch. This is useful for building source code
from the `dev` branch of individual libraries. If neither the source
code path nor the GIT repository and tag are provided, CMake defaults to
the repository and branch/tag for the AOCL stable public release.

| CMake Variable or Option    | Default Value                                      | Usage |
|-----------------------------|----------------------------------------------------|-----------------------------------------------------------|
| **UTILS_GIT_REPOSITORY**    | <https://github.com/amd/aocl-utils.git>            | `-DUTILS_GIT_REPOSITORY=<AOCL-Utils Repository URL>` |
| **UTILS_GIT_TAG**           | `main`                                             | `-DUTILS_GIT_TAG=<AOCL-Utils Git Tag or Branch Name>` |
| **BLAS_GIT_REPOSITORY**     | <https://github.com/amd/blis.git>                  | `-DBLAS_GIT_REPOSITORY=<AOCL-BLAS Repository URL>` |
| **BLAS_GIT_TAG**            | `master`                                           | `-DBLAS_GIT_TAG=<AOCL-BLAS Git Tag or Branch Name>` |
| **LAPACK_GIT_REPOSITORY**   | <https://github.com/amd/libflame.git>              | `-DLAPACK_GIT_REPOSITORY=<AOCL-LAPACK Repository URL>` |
| **LAPACK_GIT_TAG**          | `master`                                           | `-DLAPACK_GIT_TAG=<AOCL-LAPACK Git Tag or Branch Name>` |
| **SPARSE_GIT_REPOSITORY**   | <https://github.com/amd/aocl-sparse.git>           | `-DSPARSE_GIT_REPOSITORY=<AOCL-Sparse Repository URL>` |
| **SPARSE_GIT_TAG**          | `master`                                           | `-DSPARSE_GIT_TAG=<AOCL-Sparse Git Tag or Branch Name>` |
| **CRYPTO_GIT_REPOSITORY**   | <https://github.com/amd/aocl-crypto.git>           | `-DCRYPTO_GIT_REPOSITORY=<AOCL-Cryptography Repository URL>` |
| **CRYPTO_GIT_TAG**          | `main`                                             | `-DCRYPTO_GIT_TAG=<AOCL-Cryptography Git Tag or Branch Name>` |
| **LIBM_GIT_REPOSITORY**     | <https://github.com/amd/aocl-libm-ose.git>         | `-DLIBM_GIT_REPOSITORY=<AOCL-LibM Repository URL>` |
| **LIBM_GIT_TAG**            | `master`                                           | `-DLIBM_GIT_TAG=<AOCL-LibM Git Tag or Branch Name>` |
| **COMPRESSION_GIT_REPOSITORY** | <https://github.com/amd/aocl-compression.git>   | `-DCOMPRESSION_GIT_REPOSITORY=<AOCL-Compression Repository URL>` |
| **COMPRESSION_GIT_TAG**     | `amd-main`                                         | `-DCOMPRESSION_GIT_TAG=<AOCL-Compression Git Tag or Branch Name>` |
| **DA_GIT_REPOSITORY**       | <https://github.com/amd/aocl-data-analytics.git>   | `-DDA_GIT_REPOSITORY=<AOCL-Data-Analytics Repository URL>` |
| **DA_GIT_TAG**              | `main`                                             | `-DDA_GIT_TAG=<AOCL-Data-Analytics Git Tag or Branch Name>` |
| **LIBMEM_GIT_REPOSITORY**   | <https://github.com/amd/aocl-libmem.git>           | `-DLIBMEM_GIT_REPOSITORY=<AOCL-LibMem Repository URL>` |
| **LIBMEM_GIT_TAG**          | `main`                                             | `-DLIBMEM_GIT_TAG=<AOCL-LibMem Git Tag or Branch Name>` |
| **FFTZ_GIT_REPOSITORY**     | <https://github.com/amd/aocl-fftz.git>             | `-DFFTZ_GIT_REPOSITORY=<AOCL-FFTZ Repository URL>` |
| **FFTZ_GIT_TAG**            | `amd-main`                                         | `-DFFTZ_GIT_TAG=<AOCL-FFTZ Git Tag or Branch Name>` |
| **OPENRNG_GIT_REPOSITORY**  | <https://github.com/amd/openrng.git>               | `-DOPENRNG_GIT_REPOSITORY=<OpenRNG Repository URL>` |
| **OPENRNG_GIT_TAG**         | `main`                                             | `-DOPENRNG_GIT_TAG=<OpenRNG Git Tag or Branch Name>` |
| **DLP_GIT_REPOSITORY**      | <https://github.com/amd/aocl-dlp.git>              | `-DDLP_GIT_REPOSITORY=<AOCL-DLP Repository URL>` |
| **DLP_GIT_TAG**             | `master`                                           | `-DDLP_GIT_TAG=<AOCL-DLP Git Tag or Branch Name>` |

## Known Issues

### Out-of-memory (OOM) during a fully parallel build

Building with unbounded parallelism -- `cmake --build build -j` (with no job
count) or `make -j` -- starts one compile job per available CPU core. Some AOCL
components (notably AOCL-BLAS/BLIS, AOCL-LAPACK/libflame, and
AOCL-Data-Analytics) contain large translation units with high peak compiler
memory, so on machines with many cores relative to RAM the build can exhaust
memory and fail with an out-of-memory (OOM) error -- for example, the compiler
is "Killed" (signal 9) or the Linux OOM killer terminates `cc1plus` / `clang`.

**Workaround:** the limiting resource is **memory, not cores** -- so rather than
dropping to a small fixed number like `-j 8` (which would badly under-utilize a
96- or 128-core server), size the job count to the machine and cap it only when
RAM is the bottleneck. A practical rule of thumb is:

```text
jobs = min(number_of_cores, free_RAM_GB / 2)
```

That is, allow roughly one compile job per ~2 GB of available RAM, but never more
than the core count. For example:

| Machine | Memory allows (~free_GB / 2) | Recommended jobs |
| --- | --- | --- |
| 128 cores / 512 GB RAM | ~256 | `-j` (all 128 cores) |
| 96 cores / 128 GB RAM  | ~64  | `-j 64` |
| 64 cores / 64 GB RAM   | ~32  | `-j 32` |
| 32 cores / 32 GB RAM   | ~16  | `-j 16` |

On Linux you can compute and apply a memory-safe job count automatically:

```bash
cores=$(nproc)
memgb=$(awk '/MemAvailable/{printf "%d", $2/1048576}' /proc/meminfo)
jobs=$(( memgb/2 < cores ? memgb/2 : cores )); (( jobs < 1 )) && jobs=1
echo "Building with -j $jobs (cores=$cores, MemAvailable=${memgb} GB)"
cmake --build build --config Release --target install -j "$jobs"
```

Only lower the count further (for example `-j 4`, `-j 2`, or `-j 1` in the worst
case) if the build still hits OOM under heavy memory pressure. See also
[CMake Options for Build Performance](#cmake-options-for-build-performance).
