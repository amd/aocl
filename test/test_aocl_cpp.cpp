// Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.

#include <cstring>
#include <iostream>
#include <string>
#include <vector>

#ifdef ENABLE_DA
#include <cmath>
#endif

#ifdef ENABLE_CRYPTO
#include "alci/alci.h"
#include "alcp/cipher.h"
#endif

#ifdef ENABLE_UTILS
#include "Capi/au/cpuid/cpuid.h"
#endif

#ifdef ENABLE_DA
#include "aoclda.h"
#endif

#ifndef SYMBOL_PREFIX_TOKEN_LOWER
#define SYMBOL_PREFIX_TOKEN_LOWER aocl_
#endif

#ifndef SYMBOL_PREFIX_STR
#define SYMBOL_PREFIX_STR "aocl_"
#endif

#define CONCAT_IMPL(a, b) a##b
#define CONCAT(a, b) CONCAT_IMPL(a, b)
#define PREFIX_LOWER(name) CONCAT(SYMBOL_PREFIX_TOKEN_LOWER, name)

#ifdef USE_RENAMED_SYMBOLS
// AOCL library TYPE / ENUM-CONSTANT names the header rewrite prefixes to
// <prefix><name>. Types the rename engines leave unchanged (alc_cipher_handle_p,
// Uint8/Uint64, au_cpu_num_t, AU_CURRENT_CPU_NUM) are intentionally kept bare.
#ifdef ENABLE_CRYPTO
#define alc_error_t                PREFIX_LOWER(alc_error_t)
#define alc_cipher_mode_t          PREFIX_LOWER(alc_cipher_mode_t)
#define ALC_AES_MODE_CFB           PREFIX_LOWER(ALC_AES_MODE_CFB)
#define ALC_KEY_LEN_128            PREFIX_LOWER(ALC_KEY_LEN_128)
#endif
#ifdef ENABLE_DA
#define da_handle                  PREFIX_LOWER(da_handle)
#define da_status                  PREFIX_LOWER(da_status)
#define da_int                     PREFIX_LOWER(da_int)
#define da_status_success          PREFIX_LOWER(da_status_success)
#define da_handle_interpolation    PREFIX_LOWER(da_handle_interpolation)
#define column_major               PREFIX_LOWER(column_major)
#define da_axis_col                PREFIX_LOWER(da_axis_col)
#define interpolation_cubic_spline PREFIX_LOWER(interpolation_cubic_spline)
#endif
#ifdef ENABLE_CRYPTO
#define ALCP_CIPHER_CONTEXT_SIZE PREFIX_LOWER(alcp_cipher_context_size)
#define ALCP_CIPHER_REQUEST PREFIX_LOWER(alcp_cipher_request)
#define ALCP_CIPHER_INIT PREFIX_LOWER(alcp_cipher_init)
#define ALCP_CIPHER_ENCRYPT PREFIX_LOWER(alcp_cipher_encrypt)
#define ALCP_CIPHER_DECRYPT PREFIX_LOWER(alcp_cipher_decrypt)
#define ALCP_CIPHER_FINISH PREFIX_LOWER(alcp_cipher_finish)
#define ALCP_IS_ERROR PREFIX_LOWER(alcp_is_error)
#endif

#ifdef ENABLE_UTILS
#define AU_CPUID_IS_AMD PREFIX_LOWER(au_cpuid_is_amd)
#define AU_CPUID_GET_VENDOR PREFIX_LOWER(au_cpuid_get_vendor)
#define AU_CPUID_ARCH_IS_ZEN_FAMILY PREFIX_LOWER(au_cpuid_arch_is_zen_family)
#endif

#ifdef ENABLE_DA
#define DA_HANDLE_INIT_D PREFIX_LOWER(da_handle_init_d)
#define DA_INTERPOLATION_SELECT_MODEL_D PREFIX_LOWER(da_interpolation_select_model_d)
#define DA_INTERPOLATION_SET_SITES_UNIFORM_D PREFIX_LOWER(da_interpolation_set_sites_uniform_d)
#define DA_INTERPOLATION_SET_VALUES_D PREFIX_LOWER(da_interpolation_set_values_d)
#define DA_INTERPOLATION_INTERPOLATE_D PREFIX_LOWER(da_interpolation_interpolate_d)
#define DA_INTERPOLATION_EVALUATE_D PREFIX_LOWER(da_interpolation_evaluate_d)
#define DA_HANDLE_DESTROY PREFIX_LOWER(da_handle_destroy)
#endif

#define SYMBOL_PREFIX SYMBOL_PREFIX_STR
#else
#ifdef ENABLE_CRYPTO
#define ALCP_CIPHER_CONTEXT_SIZE alcp_cipher_context_size
#define ALCP_CIPHER_REQUEST alcp_cipher_request
#define ALCP_CIPHER_INIT alcp_cipher_init
#define ALCP_CIPHER_ENCRYPT alcp_cipher_encrypt
#define ALCP_CIPHER_DECRYPT alcp_cipher_decrypt
#define ALCP_CIPHER_FINISH alcp_cipher_finish
#define ALCP_IS_ERROR alcp_is_error
#endif

#ifdef ENABLE_UTILS
#define AU_CPUID_IS_AMD au_cpuid_is_amd
#define AU_CPUID_GET_VENDOR au_cpuid_get_vendor
#define AU_CPUID_ARCH_IS_ZEN_FAMILY au_cpuid_arch_is_zen_family
#endif

#ifdef ENABLE_DA
#define DA_HANDLE_INIT_D da_handle_init_d
#define DA_INTERPOLATION_SELECT_MODEL_D da_interpolation_select_model_d
#define DA_INTERPOLATION_SET_SITES_UNIFORM_D da_interpolation_set_sites_uniform_d
#define DA_INTERPOLATION_SET_VALUES_D da_interpolation_set_values_d
#define DA_INTERPOLATION_INTERPOLATE_D da_interpolation_interpolate_d
#define DA_INTERPOLATION_EVALUATE_D da_interpolation_evaluate_d
#define DA_HANDLE_DESTROY da_handle_destroy
#endif

#define SYMBOL_PREFIX "None"
#endif

extern "C" {
#ifdef ENABLE_CRYPTO
Uint64 ALCP_CIPHER_CONTEXT_SIZE(void);
alc_error_t ALCP_CIPHER_REQUEST(alc_cipher_mode_t mode, Uint64 keyLen, alc_cipher_handle_p handle);
alc_error_t ALCP_CIPHER_INIT(const alc_cipher_handle_p handle,
                             const Uint8* key,
                             Uint64 keyLen,
                             const Uint8* iv,
                             Uint64 ivLen);
alc_error_t ALCP_CIPHER_ENCRYPT(const alc_cipher_handle_p handle,
                                const Uint8* plaintext,
                                Uint8* ciphertext,
                                Uint64 len,
                                Uint64* outlen);
alc_error_t ALCP_CIPHER_DECRYPT(const alc_cipher_handle_p handle,
                                const Uint8* ciphertext,
                                Uint8* plaintext,
                                Uint64 len,
                                Uint64* outlen);
void ALCP_CIPHER_FINISH(const alc_cipher_handle_p handle);
Uint8 ALCP_IS_ERROR(alc_error_t err);
#endif

#ifdef ENABLE_UTILS
bool AU_CPUID_IS_AMD(au_cpu_num_t cpu_num);
void AU_CPUID_GET_VENDOR(au_cpu_num_t cpu_num, char* vend_info, size_t size);
bool AU_CPUID_ARCH_IS_ZEN_FAMILY(au_cpu_num_t cpu_num);
#endif
}

#ifdef ENABLE_UTILS
static bool test_aocl_utils_cpp()
{
    std::cout << "\n=== C++ AOCL-Utils test (prefix: " << SYMBOL_PREFIX << ") ===\n";

    const au_cpu_num_t cpu = AU_CURRENT_CPU_NUM;
    const bool is_amd = AU_CPUID_IS_AMD(cpu);
    const bool is_zen_family = AU_CPUID_ARCH_IS_ZEN_FAMILY(cpu);

    std::vector<char> vendor(128, '\0');
    AU_CPUID_GET_VENDOR(cpu, vendor.data(), vendor.size());

    std::string vendor_str(vendor.data());
    if (vendor_str.empty()) {
        std::cerr << "✗ au_cpuid_get_vendor returned empty string\n";
        return false;
    }

    std::cout << "✓ vendor info: " << vendor_str << "\n";
    std::cout << "✓ is_amd=" << (is_amd ? "true" : "false")
              << ", is_zen_family=" << (is_zen_family ? "true" : "false") << "\n";
    return true;
}
#endif

#ifdef ENABLE_CRYPTO
static bool test_aocl_crypto_cpp()
{
    std::cout << "\n=== C++ AOCL-Crypto test (prefix: " << SYMBOL_PREFIX << ") ===\n";

    const Uint8 key[] = {
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f
    };
    const Uint8 iv[] = {
        0x0f, 0x0e, 0x0d, 0x0c, 0x0b, 0x0a, 0x09, 0x08,
        0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x00
    };

    const std::string plain = "Hello AOCL Crypto C++!";
    std::vector<Uint8> cipher(plain.size(), 0);
    std::vector<Uint8> out(plain.size(), 0);

    alc_cipher_handle_t handle{ nullptr };
    const Uint64 ctx_size = ALCP_CIPHER_CONTEXT_SIZE();
    if (ctx_size == 0) {
        std::cerr << "✗ alcp_cipher_context_size returned 0\n";
        return false;
    }

    std::vector<Uint8> ctx(ctx_size, 0);
    handle.ch_context = static_cast<void*>(ctx.data());

    alc_error_t err = ALCP_CIPHER_REQUEST(ALC_AES_MODE_CFB, ALC_KEY_LEN_128, &handle);
    if (ALCP_IS_ERROR(err)) {
        std::cerr << "✗ alcp_cipher_request failed: " << err << "\n";
        return false;
    }

    err = ALCP_CIPHER_INIT(&handle, key, ALC_KEY_LEN_128, iv, sizeof(iv));
    if (ALCP_IS_ERROR(err)) {
        std::cerr << "✗ alcp_cipher_init failed: " << err << "\n";
        ALCP_CIPHER_FINISH(&handle);
        return false;
    }

    Uint64 enc_len = 0;
    err = ALCP_CIPHER_ENCRYPT(&handle,
                              reinterpret_cast<const Uint8*>(plain.data()),
                              cipher.data(),
                              static_cast<Uint64>(plain.size()),
                              &enc_len);
    if (ALCP_IS_ERROR(err)) {
        std::cerr << "✗ alcp_cipher_encrypt failed: " << err << "\n";
        ALCP_CIPHER_FINISH(&handle);
        return false;
    }
    ALCP_CIPHER_FINISH(&handle);

    err = ALCP_CIPHER_REQUEST(ALC_AES_MODE_CFB, ALC_KEY_LEN_128, &handle);
    if (ALCP_IS_ERROR(err)) {
        std::cerr << "✗ decrypt request failed: " << err << "\n";
        return false;
    }

    err = ALCP_CIPHER_INIT(&handle, key, ALC_KEY_LEN_128, iv, sizeof(iv));
    if (ALCP_IS_ERROR(err)) {
        std::cerr << "✗ decrypt init failed: " << err << "\n";
        ALCP_CIPHER_FINISH(&handle);
        return false;
    }

    Uint64 dec_len = 0;
    err = ALCP_CIPHER_DECRYPT(&handle,
                              cipher.data(),
                              out.data(),
                              static_cast<Uint64>(plain.size()),
                              &dec_len);
    ALCP_CIPHER_FINISH(&handle);
    if (ALCP_IS_ERROR(err)) {
        std::cerr << "✗ alcp_cipher_decrypt failed: " << err << "\n";
        return false;
    }

    if (enc_len != plain.size() || dec_len != plain.size()) {
        std::cerr << "✗ encrypt/decrypt size mismatch\n";
        return false;
    }

    if (std::memcmp(plain.data(), out.data(), plain.size()) != 0) {
        std::cerr << "✗ roundtrip mismatch\n";
        return false;
    }

    std::cout << "✓ AES-128-CFB roundtrip succeeded for " << plain.size() << " bytes\n";
    return true;
}
#endif

#ifdef ENABLE_DA
static bool test_aocl_da_cpp()
{
    std::cout << "\n=== C++ AOCL-DA cubic spline smoke test (prefix: " << SYMBOL_PREFIX << ") ===\n";

    da_handle handle = nullptr;
    if (DA_HANDLE_INIT_D(&handle, da_handle_interpolation) != da_status_success) {
        std::cerr << "✗ da_handle_init_d failed\n";
        return false;
    }

    bool ok = true;
    ok = ok && (DA_INTERPOLATION_SELECT_MODEL_D(handle, interpolation_cubic_spline) == da_status_success);

    const da_int n_sites = 10;
    const double x_start = 0.0;
    const double x_end = 9.0;
    ok = ok && (DA_INTERPOLATION_SET_SITES_UNIFORM_D(handle, n_sites, x_start, x_end) == da_status_success);

    std::vector<double> y(static_cast<size_t>(n_sites));
    const double step = (x_end - x_start) / static_cast<double>(n_sites - 1);
    for (da_int i = 0; i < n_sites; ++i) {
        y[static_cast<size_t>(i)] = std::sin(x_start + static_cast<double>(i) * step);
    }

    ok = ok && (DA_INTERPOLATION_SET_VALUES_D(handle, n_sites, 1, y.data(), n_sites, 0) == da_status_success);
    ok = ok && (DA_INTERPOLATION_INTERPOLATE_D(handle) == da_status_success);

    const da_int n_eval = 6;
    const double x_eval[6] = {0.5, 1.5, 2.5, 4.5, 6.5, 8.5};
    double y_eval[6] = {0.0};
    da_int order = 0;
    ok = ok && (DA_INTERPOLATION_EVALUATE_D(handle, n_eval, x_eval, y_eval, 1, &order) == da_status_success);

    DA_HANDLE_DESTROY(&handle);

    if (!ok) {
        std::cerr << "✗ AOCL-DA cubic spline flow failed\n";
        return false;
    }

    std::cout << "✓ AOCL-DA cubic spline flow completed for " << n_eval << " evaluation points\n";
    return true;
}
#endif

int main()
{
    std::cout << "========================================\n";
    std::cout << "AOCL C++ Test:";
#ifdef ENABLE_UTILS
    std::cout << " AOCL-Utils";
#endif
#ifdef ENABLE_CRYPTO
    std::cout << " AOCL-Crypto";
#endif
#ifdef ENABLE_DA
    std::cout << " AOCL-DA";
#endif
    std::cout << "\n";
    std::cout << "========================================\n";

    bool ok_utils = true;
    bool ok_crypto = true;
#ifdef ENABLE_DA
    bool ok_da = test_aocl_da_cpp();
#else
    bool ok_da = true;
#endif

#ifdef ENABLE_UTILS
    ok_utils = test_aocl_utils_cpp();
#endif
#ifdef ENABLE_CRYPTO
    ok_crypto = test_aocl_crypto_cpp();
#endif

    if (!ok_utils || !ok_crypto || !ok_da) {
        std::cerr << "\n✗ C++ test suite failed\n";
        return 1;
    }

    std::cout << "\n✓ All C++ tests passed\n";
    return 0;
}
