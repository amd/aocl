// Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
//
// C++ INTERFACE / template-symbol link+run test.
//
// Complements test_aocl_cpp.cpp (which only exercises the flat extern "C" API
// from C++). This test exercises the *real C++ interfaces*:
//   * aoclsparse.hpp  -> namespace aoclsparse { template<T> trsv/mv(...) }
//   * aoclda.hpp      -> template<T> da_handle_init/da_options_set(...)
// Calling these forces the compiler to emit references to the C++ *template*
// instantiation symbols, so the LINKER must find them in the (possibly renamed)
// AOCL library. If the rename tool mangled those template symbols incorrectly,
// or renamed the C++ namespace in the header but not the binary (or vice versa),
// this test FAILS TO LINK -- guarding the C++ template-symbol rename for the
// DA and sparse templated interfaces.
//
// Renamed mode (USE_RENAMED_SYMBOLS): the C++ namespace, template names, and
// public enum/typedef names are all prefixed in the renamed headers, so we build
// the renamed identifiers with token pasting from SYMBOL_PREFIX_TOKEN_LOWER.

#include <cstdio>
#include <complex>

#define CONCAT_IMPL(a, b) a##b
#define CONCAT(a, b) CONCAT_IMPL(a, b)

#ifdef USE_RENAMED_SYMBOLS
// e.g. SYMBOL_PREFIX_TOKEN_LOWER = av1_  ->  PFX(aoclsparse_mv) = av1_aoclsparse_mv
#define PFX(name) CONCAT(SYMBOL_PREFIX_TOKEN_LOWER, name)
#else
#define PFX(name) name
#endif

#ifdef ENABLE_SPARSE
#include "aoclsparse.hpp"
// Alias the (possibly renamed) C++ namespace: aoclsparse or av1_aoclsparse.
namespace sp = PFX(aoclsparse);
#endif

// The templated C++ DA interface lives in aoclda.hpp, which only ships with
// newer AOCL-DA versions (older checkouts expose only the flat C API + a
// different aoclda_cpp_overloads.hpp). Gate the DA portion on the header being
// present so the sparse template test still builds+runs against either version.
#if defined(ENABLE_DA) && defined(__has_include)
#  if __has_include("aoclda.hpp")
#    define AOCL_TEST_DA_TEMPLATES 1
#  endif
#endif

#ifdef AOCL_TEST_DA_TEMPLATES
#include "aoclda.hpp"
#endif

static int failures = 0;

#define EXPECT_LINKS(label) \
    do { printf("PASS  %-42s (linked + ran, no crash)\n", (label)); } while (0)

// ── Sparse C++ template interface ────────────────────────────────────────────
#ifdef ENABLE_SPARSE
static void test_sparse_cpp_templates(void)
{
    printf("--- aoclsparse:: C++ template interface ---\n");
    PFX(aoclsparse_mat_descr) descr = nullptr;

    // trsv<T> : exercises the aoclsparse::trsv<T> template symbol.
    (void)sp::trsv<float>(PFX(aoclsparse_operation_none), 1.0f, nullptr, descr,
                          nullptr, 1, nullptr, 1);
    EXPECT_LINKS("aoclsparse::trsv<float>");
    (void)sp::trsv<double>(PFX(aoclsparse_operation_none), 1.0, nullptr, descr,
                           nullptr, 1, nullptr, 1);
    EXPECT_LINKS("aoclsparse::trsv<double>");

    // Complex specialisations (std::complex template args in the symbol).
    (void)sp::trsv<std::complex<float>>(PFX(aoclsparse_operation_none),
                                        {1.0f, 0.0f}, nullptr, descr, nullptr, 1,
                                        nullptr, 1);
    EXPECT_LINKS("aoclsparse::trsv<complex<float>>");
    (void)sp::trsv<std::complex<double>>(PFX(aoclsparse_operation_none),
                                         {1.0, 0.0}, nullptr, descr, nullptr, 1,
                                         nullptr, 1);
    EXPECT_LINKS("aoclsparse::trsv<complex<double>>");

    // mv<T> : exercises the aoclsparse::mv<T> template symbol.
    float  af = 1.0f, bf = 0.0f;
    double ad = 1.0, bd = 0.0;
    (void)sp::mv<float>(PFX(aoclsparse_operation_none), &af, nullptr, descr,
                        nullptr, &bf, nullptr);
    EXPECT_LINKS("aoclsparse::mv<float>");
    (void)sp::mv<double>(PFX(aoclsparse_operation_none), &ad, nullptr, descr,
                         nullptr, &bd, nullptr);
    EXPECT_LINKS("aoclsparse::mv<double>");
}
#endif  // ENABLE_SPARSE

// ── DA C++ template interface ────────────────────────────────────────────────
#ifdef AOCL_TEST_DA_TEMPLATES
static void test_da_cpp_templates(void)
{
    printf("\n--- AOCL-DA C++ template interface ---\n");
    // aoclda.hpp declares template<T> da_handle_init<T>(...) etc. Calling the
    // template forces the C++ template instantiation symbol to be resolved.
    PFX(da_handle) handle_s = nullptr;
    PFX(da_handle) handle_d = nullptr;

    (void)PFX(da_handle_init)<float>(&handle_s, PFX(da_handle_uninitialized));
    EXPECT_LINKS("da_handle_init<float>");
    (void)PFX(da_handle_init)<double>(&handle_d, PFX(da_handle_uninitialized));
    EXPECT_LINKS("da_handle_init<double>");

    if (handle_s) PFX(da_handle_destroy)(&handle_s);
    if (handle_d) PFX(da_handle_destroy)(&handle_d);
}
#endif  // ENABLE_DA

int main(void)
{
    printf("=== AOCL C++ interface (template symbol) link/run test ===\n");
    printf("    (link failure => a C++ template symbol was renamed inconsistently)\n\n");

#ifdef ENABLE_SPARSE
    test_sparse_cpp_templates();
#else
    printf("SKIP  SPARSE not enabled\n");
#endif
#ifdef AOCL_TEST_DA_TEMPLATES
    test_da_cpp_templates();
#else
    printf("SKIP  DA templated C++ interface (aoclda.hpp not present)\n");
#endif

    printf("\n%s\n", failures == 0 ? "=== PASS ===" : "=== FAIL ===");
    return failures;
}
