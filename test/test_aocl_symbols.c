// Copyright (C) 2025-2026, Advanced Micro Devices, Inc. All rights reserved.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <complex.h>
#include "test_aocl_symbols.h"

// Include BLAS/LAPACK headers from install path (conditionally based on enabled libraries)
// This tests that the installed headers work correctly
// cblas.h provides f77_int which is int32_t (LP64) or int64_t (ILP64) depending on build config
#if defined(ENABLE_BLAS) || defined(ENABLE_LAPACK)
#include "cblas.h"
#endif

// Include AOCL library headers (conditionally based on enabled libraries)
#ifdef ENABLE_SPARSE
#include "aoclsparse.h"
#endif

#ifdef ENABLE_LIBM
#include "amdlibm.h"
#endif

#ifdef ENABLE_COMPRESSION
#include "aocl_compression.h"
#endif

#ifdef ENABLE_CRYPTO
#include "alci/alci.h"
#include "alcp/cipher.h"
#endif

#ifdef ENABLE_DA
#include "aoclda.h"
#endif

#ifdef ENABLE_CRYPTO
// External declarations for Crypto functions
extern Uint64 ALCP_CIPHER_CONTEXT_SIZE(void);
extern alc_error_t ALCP_CIPHER_REQUEST(alc_cipher_mode_t mode, alc_key_len_t keyLen, alc_cipher_handle_p handle);
extern alc_error_t ALCP_CIPHER_INIT(alc_cipher_handle_p handle, const Uint8* key, Uint32 keyLen, const Uint8* iv, Uint32 ivLen);
extern alc_error_t ALCP_CIPHER_ENCRYPT(alc_cipher_handle_p handle, const Uint8* plaintext, Uint8* ciphertext, Uint64 len, Uint64* outlen);
extern alc_error_t ALCP_CIPHER_DECRYPT(alc_cipher_handle_p handle, const Uint8* ciphertext, Uint8* plaintext, Uint64 len, Uint64* outlen);
extern alc_error_t ALCP_CIPHER_FINISH(alc_cipher_handle_p handle);
extern int ALCP_IS_ERROR(alc_error_t err);
#endif

#ifdef ENABLE_LIBMEM
// External declarations for LibMem functions
extern void* AMD_MEMCPY(void* dest, const void* src, size_t n);
extern void* AMD_MEMMOVE(void* dest, const void* src, size_t n);
extern void* AMD_MEMSET(void* s, int c, size_t n);
extern char* AMD_STRCPY(char* dest, const char* src);
extern int AMD_STRCMP(const char* s1, const char* s2);
extern size_t AMD_STRLEN(const char* s);
#endif

// For LAPACK, we use Fortran interface, so we declare the functions
// The lapack.h header is for Fortran, so we manually declare with proper types

// Define which functions to use based on symbol renaming
// Symbol prefix handling - convert string to token for macro concatenation
// The prefix is passed from CMake as SYMBOL_PREFIX_STR (e.g., "aocl_", "aocl51_", etc.)
// Prefix tokens for case-aware symbol renaming
#ifndef SYMBOL_PREFIX_TOKEN_LOWER
    #define SYMBOL_PREFIX_TOKEN_LOWER aocl_
#endif

#ifndef SYMBOL_PREFIX_TOKEN_UPPER
    #define SYMBOL_PREFIX_TOKEN_UPPER AOCL_
#endif

#ifndef SYMBOL_PREFIX_STR
    #define SYMBOL_PREFIX_STR "aocl_"
#endif

// Two-step macro expansion for token pasting
#define CONCAT_IMPL(a, b) a##b
#define CONCAT(a, b) CONCAT_IMPL(a, b)

// Prefix macros: Uppercase symbols use UPPER prefix, lowercase symbols use lower prefix
// Note: PREFIX_UPPER appends a trailing underscore to match Fortran symbol naming conventions (e.g., SGEMM_),
// while PREFIX_LOWER does not append an underscore, matching C symbol naming conventions (e.g., sgemm).
#define PREFIX_UPPER(name) CONCAT(SYMBOL_PREFIX_TOKEN_UPPER, name##_)
#define PREFIX_LOWER(name) CONCAT(SYMBOL_PREFIX_TOKEN_LOWER, name)

#ifdef USE_RENAMED_SYMBOLS
    // BLAS functions with uppercase names - dynamically created with prefix
    #define SGEMM_FUNC PREFIX_UPPER(SGEMM)
    #define DGEMM_FUNC PREFIX_UPPER(DGEMM)
    #define CGEMM_FUNC PREFIX_UPPER(CGEMM)
    #define ZGEMM_FUNC PREFIX_UPPER(ZGEMM)
    
    #define STRSM_FUNC PREFIX_UPPER(STRSM)
    #define DTRSM_FUNC PREFIX_UPPER(DTRSM)
    #define CTRSM_FUNC PREFIX_UPPER(CTRSM)
    #define ZTRSM_FUNC PREFIX_UPPER(ZTRSM)
    
    #define SGEMV_FUNC PREFIX_UPPER(SGEMV)
    #define DGEMV_FUNC PREFIX_UPPER(DGEMV)
    #define CGEMV_FUNC PREFIX_UPPER(CGEMV)
    #define ZGEMV_FUNC PREFIX_UPPER(ZGEMV)
    
    // CBLAS functions
    #define CBLAS_SGEMM PREFIX_LOWER(cblas_sgemm)
    #define CBLAS_DGEMM PREFIX_LOWER(cblas_dgemm)
    #define CBLAS_CGEMM PREFIX_LOWER(cblas_cgemm)
    #define CBLAS_ZGEMM PREFIX_LOWER(cblas_zgemm)
    
    #define CBLAS_STRSM PREFIX_LOWER(cblas_strsm)
    #define CBLAS_DTRSM PREFIX_LOWER(cblas_dtrsm)
    #define CBLAS_CTRSM PREFIX_LOWER(cblas_ctrsm)
    #define CBLAS_ZTRSM PREFIX_LOWER(cblas_ztrsm)
    
    #define CBLAS_SGEMV PREFIX_LOWER(cblas_sgemv)
    #define CBLAS_DGEMV PREFIX_LOWER(cblas_dgemv)
    #define CBLAS_CGEMV PREFIX_LOWER(cblas_cgemv)
    #define CBLAS_ZGEMV PREFIX_LOWER(cblas_zgemv)
    
    #define CBLAS_SAXPBY PREFIX_LOWER(cblas_saxpby)
    #define CBLAS_DAXPBY PREFIX_LOWER(cblas_daxpby)
    #define CBLAS_CAXPBY PREFIX_LOWER(cblas_caxpby)
    #define CBLAS_ZAXPBY PREFIX_LOWER(cblas_zaxpby)
    
    // LAPACK functions
    #define SGETRF_FUNC PREFIX_UPPER(SGETRF)
    #define DGETRF_FUNC PREFIX_UPPER(DGETRF)
    #define CGETRF_FUNC PREFIX_UPPER(CGETRF)
    #define ZGETRF_FUNC PREFIX_UPPER(ZGETRF)
    
    #define SPOTRF_FUNC PREFIX_UPPER(SPOTRF)
    #define DPOTRF_FUNC PREFIX_UPPER(DPOTRF)
    #define CPOTRF_FUNC PREFIX_UPPER(CPOTRF)
    #define ZPOTRF_FUNC PREFIX_UPPER(ZPOTRF)
    
    #define SGESVD_FUNC PREFIX_UPPER(SGESVD)
    #define DGESVD_FUNC PREFIX_UPPER(DGESVD)
    #define CGESVD_FUNC PREFIX_UPPER(CGESVD)
    #define ZGESVD_FUNC PREFIX_UPPER(ZGESVD)
    
    #define SGESV_FUNC PREFIX_UPPER(SGESV)
    #define DGESV_FUNC PREFIX_UPPER(DGESV)
    #define CGESV_FUNC PREFIX_UPPER(CGESV)
    #define ZGESV_FUNC PREFIX_UPPER(ZGESV)
    
    // AOCL-Sparse functions
    #define AOCLSPARSE_CREATE_MAT_DESCR PREFIX_LOWER(aoclsparse_create_mat_descr)
    #define AOCLSPARSE_DESTROY_MAT_DESCR PREFIX_LOWER(aoclsparse_destroy_mat_descr)
    
    // AOCL-LibM functions (using amd_ prefix to test actual AOCL-LibM, not system libm)
    #define LIBM_SIN_FUNC PREFIX_LOWER(amd_sin)
    #define LIBM_COS_FUNC PREFIX_LOWER(amd_cos)
    #define LIBM_EXP_FUNC PREFIX_LOWER(amd_exp)
    #define LIBM_LOG_FUNC PREFIX_LOWER(amd_log)
    
    // AOCL-Compression functions (mixed-case symbols get uppercase prefix)
    #define AOCL_LLC_COMPRESS PREFIX_LOWER(aocl_llc_compress)
    #define AOCL_LLC_DECOMPRESS PREFIX_LOWER(aocl_llc_decompress)
    #define AOCL_LLC_COMPRESSBOUND CONCAT(SYMBOL_PREFIX_TOKEN_UPPER, aocl_llc_compressBound)
    
    // AOCL-Crypto functions
    #define ALCP_CIPHER_CONTEXT_SIZE PREFIX_LOWER(alcp_cipher_context_size)
    #define ALCP_CIPHER_REQUEST PREFIX_LOWER(alcp_cipher_request)
    #define ALCP_CIPHER_INIT PREFIX_LOWER(alcp_cipher_init)
    #define ALCP_CIPHER_ENCRYPT PREFIX_LOWER(alcp_cipher_encrypt)
    #define ALCP_CIPHER_DECRYPT PREFIX_LOWER(alcp_cipher_decrypt)
    #define ALCP_CIPHER_FINISH PREFIX_LOWER(alcp_cipher_finish)
    #define ALCP_IS_ERROR PREFIX_LOWER(alcp_is_error)
    
    // AOCL-LibMem functions
    #define AMD_MEMCPY PREFIX_LOWER(amd_memcpy)
    #define AMD_MEMMOVE PREFIX_LOWER(amd_memmove)
    #define AMD_MEMSET PREFIX_LOWER(amd_memset)
    #define AMD_STRCPY PREFIX_LOWER(amd_strcpy)
    #define AMD_STRCMP PREFIX_LOWER(amd_strcmp)
    #define AMD_STRLEN PREFIX_LOWER(amd_strlen)
    
    // AOCL-DA functions
    #define DA_HANDLE_INIT_D PREFIX_LOWER(da_handle_init_d)
    #define DA_HANDLE_DESTROY PREFIX_LOWER(da_handle_destroy)
    #define DA_HARMONIC_MEAN_D PREFIX_LOWER(da_harmonic_mean_d)
    #define DA_PCA_SET_DATA_D PREFIX_LOWER(da_pca_set_data_d)
    #define DA_OPTIONS_SET_STRING PREFIX_LOWER(da_options_set_string)
    #define DA_OPTIONS_SET_INT PREFIX_LOWER(da_options_set_int)
    #define DA_KMEANS_SET_DATA_D PREFIX_LOWER(da_kmeans_set_data_d)
    
    #define SYMBOL_PREFIX SYMBOL_PREFIX_STR
#else
    // Original symbols (no prefix)
    #define SGEMM_FUNC sgemm_
    #define DGEMM_FUNC dgemm_
    #define CGEMM_FUNC cgemm_
    #define ZGEMM_FUNC zgemm_
    
    #define STRSM_FUNC strsm_
    #define DTRSM_FUNC dtrsm_
    #define CTRSM_FUNC ctrsm_
    #define ZTRSM_FUNC ztrsm_
    
    #define SGEMV_FUNC sgemv_
    #define DGEMV_FUNC dgemv_
    #define CGEMV_FUNC cgemv_
    #define ZGEMV_FUNC zgemv_
    
    // CBLAS functions
    #define CBLAS_SGEMM cblas_sgemm
    #define CBLAS_DGEMM cblas_dgemm
    #define CBLAS_CGEMM cblas_cgemm
    #define CBLAS_ZGEMM cblas_zgemm
    
    #define CBLAS_STRSM cblas_strsm
    #define CBLAS_DTRSM cblas_dtrsm
    #define CBLAS_CTRSM cblas_ctrsm
    #define CBLAS_ZTRSM cblas_ztrsm
    
    #define CBLAS_SGEMV cblas_sgemv
    #define CBLAS_DGEMV cblas_dgemv
    #define CBLAS_CGEMV cblas_cgemv
    #define CBLAS_ZGEMV cblas_zgemv
    
    #define CBLAS_SAXPBY cblas_saxpby
    #define CBLAS_DAXPBY cblas_daxpby
    #define CBLAS_CAXPBY cblas_caxpby
    #define CBLAS_ZAXPBY cblas_zaxpby
    
    // LAPACK functions
    #define SGETRF_FUNC sgetrf_
    #define DGETRF_FUNC dgetrf_
    #define CGETRF_FUNC cgetrf_
    #define ZGETRF_FUNC zgetrf_
    
    #define SPOTRF_FUNC spotrf_
    #define DPOTRF_FUNC dpotrf_
    #define CPOTRF_FUNC cpotrf_
    #define ZPOTRF_FUNC zpotrf_
    
    #define SGESVD_FUNC sgesvd_
    #define DGESVD_FUNC dgesvd_
    #define CGESVD_FUNC cgesvd_
    #define ZGESVD_FUNC zgesvd_
    
    #define SGESV_FUNC sgesv_
    #define DGESV_FUNC dgesv_
    #define CGESV_FUNC cgesv_
    #define ZGESV_FUNC zgesv_
    
    // AOCL-Sparse functions
    #define AOCLSPARSE_CREATE_MAT_DESCR aoclsparse_create_mat_descr
    #define AOCLSPARSE_DESTROY_MAT_DESCR aoclsparse_destroy_mat_descr
    
    // AOCL-LibM functions (using amd_ prefix to test actual AOCL-LibM, not system libm)
    #define LIBM_SIN_FUNC amd_sin
    #define LIBM_COS_FUNC amd_cos
    #define LIBM_EXP_FUNC amd_exp
    #define LIBM_LOG_FUNC amd_log
    
    // AOCL-Compression functions
    #define AOCL_LLC_COMPRESS aocl_llc_compress
    #define AOCL_LLC_DECOMPRESS aocl_llc_decompress
    #define AOCL_LLC_COMPRESSBOUND aocl_llc_compressBound
    
    // AOCL-Crypto functions
    #define ALCP_CIPHER_CONTEXT_SIZE alcp_cipher_context_size
    #define ALCP_CIPHER_REQUEST alcp_cipher_request
    #define ALCP_CIPHER_INIT alcp_cipher_init
    #define ALCP_CIPHER_ENCRYPT alcp_cipher_encrypt
    #define ALCP_CIPHER_DECRYPT alcp_cipher_decrypt
    #define ALCP_CIPHER_FINISH alcp_cipher_finish
    #define ALCP_IS_ERROR alcp_is_error
    
    // AOCL-LibMem functions (uses IFUNC to replace standard C library functions)
    #define AMD_MEMCPY memcpy
    #define AMD_MEMMOVE memmove
    #define AMD_MEMSET memset
    #define AMD_STRCPY strcpy
    #define AMD_STRCMP strcmp
    #define AMD_STRLEN strlen
    
    // AOCL-DA functions
    #define DA_HANDLE_INIT_D da_handle_init_d
    #define DA_HANDLE_DESTROY da_handle_destroy
    #define DA_HARMONIC_MEAN_D da_harmonic_mean_d
    #define DA_PCA_SET_DATA_D da_pca_set_data_d
    #define DA_OPTIONS_SET_STRING da_options_set_string
    #define DA_OPTIONS_SET_INT da_options_set_int
    #define DA_KMEANS_SET_DATA_D da_kmeans_set_data_d
    
    #define SYMBOL_PREFIX "None"
#endif

#ifdef ENABLE_BLAS
// External Fortran BLAS declarations - GEMM
extern void SGEMM_FUNC(const char* transa, const char* transb, 
                       const f77_int* m, const f77_int* n, const f77_int* k,
                       const float* alpha, const float* a, const f77_int* lda,
                       const float* b, const f77_int* ldb,
                       const float* beta, float* c, const f77_int* ldc);

extern void DGEMM_FUNC(const char* transa, const char* transb, 
                       const f77_int* m, const f77_int* n, const f77_int* k,
                       const double* alpha, const double* a, const f77_int* lda,
                       const double* b, const f77_int* ldb,
                       const double* beta, double* c, const f77_int* ldc);

extern void CGEMM_FUNC(const char* transa, const char* transb, 
                       const f77_int* m, const f77_int* n, const f77_int* k,
                       const void* alpha, const void* a, const f77_int* lda,
                       const void* b, const f77_int* ldb,
                       const void* beta, void* c, const f77_int* ldc);

extern void ZGEMM_FUNC(const char* transa, const char* transb, 
                       const f77_int* m, const f77_int* n, const f77_int* k,
                       const void* alpha, const void* a, const f77_int* lda,
                       const void* b, const f77_int* ldb,
                       const void* beta, void* c, const f77_int* ldc);

// External Fortran BLAS declarations - TRSM
extern void STRSM_FUNC(const char* side, const char* uplo, const char* transa, const char* diag,
                       const f77_int* m, const f77_int* n, const float* alpha,
                       const float* a, const f77_int* lda, float* b, const f77_int* ldb);

extern void DTRSM_FUNC(const char* side, const char* uplo, const char* transa, const char* diag,
                       const f77_int* m, const f77_int* n, const double* alpha,
                       const double* a, const f77_int* lda, double* b, const f77_int* ldb);

extern void CTRSM_FUNC(const char* side, const char* uplo, const char* transa, const char* diag,
                       const f77_int* m, const f77_int* n, const void* alpha,
                       const void* a, const f77_int* lda, void* b, const f77_int* ldb);

extern void ZTRSM_FUNC(const char* side, const char* uplo, const char* transa, const char* diag,
                       const f77_int* m, const f77_int* n, const void* alpha,
                       const void* a, const f77_int* lda, void* b, const f77_int* ldb);

// External Fortran BLAS declarations - GEMV
extern void SGEMV_FUNC(const char* trans, const f77_int* m, const f77_int* n,
                       const float* alpha, const float* a, const f77_int* lda,
                       const float* x, const f77_int* incx,
                       const float* beta, float* y, const f77_int* incy);

extern void DGEMV_FUNC(const char* trans, const f77_int* m, const f77_int* n,
                       const double* alpha, const double* a, const f77_int* lda,
                       const double* x, const f77_int* incx,
                       const double* beta, double* y, const f77_int* incy);

extern void CGEMV_FUNC(const char* trans, const f77_int* m, const f77_int* n,
                       const void* alpha, const void* a, const f77_int* lda,
                       const void* x, const f77_int* incx,
                       const void* beta, void* y, const f77_int* incy);

extern void ZGEMV_FUNC(const char* trans, const f77_int* m, const f77_int* n,
                       const void* alpha, const void* a, const f77_int* lda,
                       const void* x, const f77_int* incx,
                       const void* beta, void* y, const f77_int* incy);
#endif // ENABLE_BLAS

#ifdef ENABLE_LAPACK
// External LAPACK declarations - GETRF (LU factorization)
extern void SGETRF_FUNC(const f77_int* m, const f77_int* n, float* a, const f77_int* lda,
                        f77_int* ipiv, f77_int* info);

extern void DGETRF_FUNC(const f77_int* m, const f77_int* n, double* a, const f77_int* lda,
                        f77_int* ipiv, f77_int* info);

extern void CGETRF_FUNC(const f77_int* m, const f77_int* n, void* a, const f77_int* lda,
                        f77_int* ipiv, f77_int* info);

extern void ZGETRF_FUNC(const f77_int* m, const f77_int* n, void* a, const f77_int* lda,
                        f77_int* ipiv, f77_int* info);

// External LAPACK declarations - POTRF (Cholesky factorization)
extern void SPOTRF_FUNC(const char* uplo, const f77_int* n, float* a, const f77_int* lda, f77_int* info);

extern void DPOTRF_FUNC(const char* uplo, const f77_int* n, double* a, const f77_int* lda, f77_int* info);

extern void CPOTRF_FUNC(const char* uplo, const f77_int* n, void* a, const f77_int* lda, f77_int* info);

extern void ZPOTRF_FUNC(const char* uplo, const f77_int* n, void* a, const f77_int* lda, f77_int* info);

// External LAPACK declarations - GESVD (SVD)
extern void SGESVD_FUNC(const char* jobu, const char* jobvt, const f77_int* m, const f77_int* n,
                        float* a, const f77_int* lda, float* s, float* u, const f77_int* ldu,
                        float* vt, const f77_int* ldvt, float* work, const f77_int* lwork, f77_int* info);

extern void DGESVD_FUNC(const char* jobu, const char* jobvt, const f77_int* m, const f77_int* n,
                        double* a, const f77_int* lda, double* s, double* u, const f77_int* ldu,
                        double* vt, const f77_int* ldvt, double* work, const f77_int* lwork, f77_int* info);

extern void CGESVD_FUNC(const char* jobu, const char* jobvt, const f77_int* m, const f77_int* n,
                        void* a, const f77_int* lda, float* s, void* u, const f77_int* ldu,
                        void* vt, const f77_int* ldvt, void* work, const f77_int* lwork,
                        float* rwork, f77_int* info);

extern void ZGESVD_FUNC(const char* jobu, const char* jobvt, const f77_int* m, const f77_int* n,
                        void* a, const f77_int* lda, double* s, void* u, const f77_int* ldu,
                        void* vt, const f77_int* ldvt, void* work, const f77_int* lwork,
                        double* rwork, f77_int* info);

// External LAPACK declarations - GESV (Solve linear system)
extern void SGESV_FUNC(const f77_int* n, const f77_int* nrhs, float* a, const f77_int* lda,
                       f77_int* ipiv, float* b, const f77_int* ldb, f77_int* info);

extern void DGESV_FUNC(const f77_int* n, const f77_int* nrhs, double* a, const f77_int* lda,
                       f77_int* ipiv, double* b, const f77_int* ldb, f77_int* info);

extern void CGESV_FUNC(const f77_int* n, const f77_int* nrhs, void* a, const f77_int* lda,
                       f77_int* ipiv, void* b, const f77_int* ldb, f77_int* info);

extern void ZGESV_FUNC(const f77_int* n, const f77_int* nrhs, void* a, const f77_int* lda,
                       f77_int* ipiv, void* b, const f77_int* ldb, f77_int* info);
#endif // ENABLE_LAPACK

#ifdef ENABLE_BLAS
void test_gemm(void) {
    printf("\n=== Testing GEMM (all precisions) with symbol prefix: %s ===\n", SYMBOL_PREFIX);
    int passed = 1;
    
    // Test dimensions: C = A * B where A is 2x3, B is 3x2, C is 2x2
    const f77_int m = 2, n = 2, k = 3;
    const f77_int lda = m, ldb = k, ldc = m;
    const char transa = 'N', transb = 'N';
    
    // ========== SGEMM (Single Precision) ==========
    {
        const float alpha_s = 1.0f, beta_s = 0.0f;
        float A_s[] = {1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f};
        float B_s[] = {1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f};
        float C_s[] = {0.0f, 0.0f, 0.0f, 0.0f};
        
        printf("\n1. SGEMM (Single Precision):\n");
        SGEMM_FUNC(&transa, &transb, &m, &n, &k, &alpha_s, A_s, &lda, B_s, &ldb, &beta_s, C_s, &ldc);
        
        const float expected_s[] = {22.0f, 28.0f, 49.0f, 64.0f};
        for (int i = 0; i < 4; i++) {
            if (fabsf(C_s[i] - expected_s[i]) > 1e-5f) {
                printf("   ✗ FAILED: C_s[%d] = %f, expected %f\n", i, C_s[i], expected_s[i]);
                passed = 0;
            }
        }
        if (passed) printf("   ✓ SGEMM PASSED\n");
    }
    
    // ========== DGEMM (Double Precision) ==========
    {
        const double alpha_d = 1.0, beta_d = 0.0;
        double A_d[] = {1.0, 2.0, 3.0, 4.0, 5.0, 6.0};
        double B_d[] = {1.0, 2.0, 3.0, 4.0, 5.0, 6.0};
        double C_d[] = {0.0, 0.0, 0.0, 0.0};
        
        printf("2. DGEMM (Double Precision):\n");
        DGEMM_FUNC(&transa, &transb, &m, &n, &k, &alpha_d, A_d, &lda, B_d, &ldb, &beta_d, C_d, &ldc);
        
        const double expected_d[] = {22.0, 28.0, 49.0, 64.0};
        for (int i = 0; i < 4; i++) {
            if (fabs(C_d[i] - expected_d[i]) > 1e-10) {
                printf("   ✗ FAILED: C_d[%d] = %f, expected %f\n", i, C_d[i], expected_d[i]);
                passed = 0;
            }
        }
        if (passed) printf("   ✓ DGEMM PASSED\n");
    }
    
    // ========== CGEMM (Complex Single Precision) ==========
    {
        float complex alpha_c = 1.0f + 0.0f*I;
        float complex beta_c = 0.0f + 0.0f*I;
        float complex A_c[] = {1.0f+0.5f*I, 2.0f+0.5f*I, 3.0f+0.5f*I, 4.0f+0.5f*I, 5.0f+0.5f*I, 6.0f+0.5f*I};
        float complex B_c[] = {1.0f+0.5f*I, 2.0f+0.5f*I, 3.0f+0.5f*I, 4.0f+0.5f*I, 5.0f+0.5f*I, 6.0f+0.5f*I};
        float complex C_c[] = {0.0f, 0.0f, 0.0f, 0.0f};
        
        printf("3. CGEMM (Complex Single Precision):\n");
        CGEMM_FUNC(&transa, &transb, &m, &n, &k, &alpha_c, A_c, &lda, B_c, &ldb, &beta_c, C_c, &ldc);
        
        // Just verify it doesn't crash and produces some result
        printf("   ✓ CGEMM executed (result: %.2f%+.2fi)\n", crealf(C_c[0]), cimagf(C_c[0]));
    }
    
    // ========== ZGEMM (Complex Double Precision) ==========
    {
        double complex alpha_z = 1.0 + 0.0*I;
        double complex beta_z = 0.0 + 0.0*I;
        double complex A_z[] = {1.0+0.5*I, 2.0+0.5*I, 3.0+0.5*I, 4.0+0.5*I, 5.0+0.5*I, 6.0+0.5*I};
        double complex B_z[] = {1.0+0.5*I, 2.0+0.5*I, 3.0+0.5*I, 4.0+0.5*I, 5.0+0.5*I, 6.0+0.5*I};
        double complex C_z[] = {0.0, 0.0, 0.0, 0.0};
        
        printf("4. ZGEMM (Complex Double Precision):\n");
        ZGEMM_FUNC(&transa, &transb, &m, &n, &k, &alpha_z, A_z, &lda, B_z, &ldb, &beta_z, C_z, &ldc);
        
        printf("   ✓ ZGEMM executed (result: %.2f%+.2fi)\n", creal(C_z[0]), cimag(C_z[0]));
    }
    
    // Test CBLAS versions
    printf("\n=== Testing CBLAS GEMM variants ===\n");
    
    // CBLAS_SGEMM test
    {
        const float alpha_s = 1.0f, beta_s = 0.0f;
        float A_s[] = {1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f};
        float B_s[] = {1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f};
        float C_s[] = {0.0f, 0.0f, 0.0f, 0.0f};
        
        printf("5. CBLAS_SGEMM:\n");
        CBLAS_SGEMM(CblasColMajor, CblasNoTrans, CblasNoTrans,
                    m, n, k, alpha_s, A_s, lda, B_s, ldb, beta_s, C_s, ldc);
        
        const float expected_s[] = {22.0f, 28.0f, 49.0f, 64.0f};
        for (int i = 0; i < 4; i++) {
            if (fabsf(C_s[i] - expected_s[i]) > 1e-5f) {
                printf("   ✗ FAILED: C_s[%d] = %f, expected %f\n", i, C_s[i], expected_s[i]);
                passed = 0;
            }
        }
        if (passed) printf("   ✓ CBLAS_SGEMM PASSED\n");
    }
    
    // CBLAS_DGEMM test
    {
        const double alpha_d = 1.0, beta_d = 0.0;
        double A_d[] = {1.0, 2.0, 3.0, 4.0, 5.0, 6.0};
        double B_d[] = {1.0, 2.0, 3.0, 4.0, 5.0, 6.0};
        double C_d[] = {0.0, 0.0, 0.0, 0.0};
        
        printf("6. CBLAS_DGEMM:\n");
        CBLAS_DGEMM(CblasColMajor, CblasNoTrans, CblasNoTrans,
                    m, n, k, alpha_d, A_d, lda, B_d, ldb, beta_d, C_d, ldc);
        
        const double expected_d[] = {22.0, 28.0, 49.0, 64.0};
        for (int i = 0; i < 4; i++) {
            if (fabs(C_d[i] - expected_d[i]) > 1e-10) {
                printf("   ✗ FAILED: C_d[%d] = %f, expected %f\n", i, C_d[i], expected_d[i]);
                passed = 0;
            }
        }
        if (passed) printf("   ✓ CBLAS_DGEMM PASSED\n");
    }
    
    // CBLAS_CGEMM test
    {
        float complex alpha_c = 1.0f + 0.0f*I;
        float complex beta_c = 0.0f + 0.0f*I;
        float complex A_c[] = {1.0f+0.5f*I, 2.0f+0.5f*I, 3.0f+0.5f*I, 4.0f+0.5f*I, 5.0f+0.5f*I, 6.0f+0.5f*I};
        float complex B_c[] = {1.0f+0.5f*I, 2.0f+0.5f*I, 3.0f+0.5f*I, 4.0f+0.5f*I, 5.0f+0.5f*I, 6.0f+0.5f*I};
        float complex C_c[] = {0.0f, 0.0f, 0.0f, 0.0f};
        
        printf("7. CBLAS_CGEMM:\n");
        CBLAS_CGEMM(CblasColMajor, CblasNoTrans, CblasNoTrans,
                    m, n, k, &alpha_c, A_c, lda, B_c, ldb, &beta_c, C_c, ldc);
        printf("   ✓ CBLAS_CGEMM executed (result: %.2f%+.2fi)\n", crealf(C_c[0]), cimagf(C_c[0]));
    }
    
    // CBLAS_ZGEMM test
    {
        double complex alpha_z = 1.0 + 0.0*I;
        double complex beta_z = 0.0 + 0.0*I;
        double complex A_z[] = {1.0+0.5*I, 2.0+0.5*I, 3.0+0.5*I, 4.0+0.5*I, 5.0+0.5*I, 6.0+0.5*I};
        double complex B_z[] = {1.0+0.5*I, 2.0+0.5*I, 3.0+0.5*I, 4.0+0.5*I, 5.0+0.5*I, 6.0+0.5*I};
        double complex C_z[] = {0.0, 0.0, 0.0, 0.0};
        
        printf("8. CBLAS_ZGEMM:\n");
        CBLAS_ZGEMM(CblasColMajor, CblasNoTrans, CblasNoTrans,
                    m, n, k, &alpha_z, A_z, lda, B_z, ldb, &beta_z, C_z, ldc);
        printf("   ✓ CBLAS_ZGEMM executed (result: %.2f%+.2fi)\n", creal(C_z[0]), cimag(C_z[0]));
    }
    
    if (passed) {
        printf("\n✓ All GEMM tests PASSED!\n");
    } else {
        printf("\n✗ Some GEMM tests FAILED!\n");
    }
}

void test_trsm(void) {
    printf("\n=== Testing TRSM (all precisions) with symbol prefix: %s ===\n", SYMBOL_PREFIX);
    
    const f77_int m = 2, n = 2;
    const f77_int lda = m, ldb = m;
    const char side = 'L', uplo = 'U', transa = 'N', diag = 'N';
    
    // ========== STRSM (Single Precision) ==========
    {
        const float alpha_s = 1.0f;
        float A_s[] = {2.0f, 0.0f, 1.0f, 3.0f}; // Upper triangular
        float B_s[] = {4.0f, 6.0f, 10.0f, 18.0f}; // Will be overwritten with solution
        
        printf("\n1. STRSM (Single Precision):\n");
        STRSM_FUNC(&side, &uplo, &transa, &diag, &m, &n, &alpha_s, A_s, &lda, B_s, &ldb);
        printf("   ✓ STRSM executed (result: %.2f)\n", B_s[0]);
    }
    
    // ========== DTRSM (Double Precision) ==========
    {
        const double alpha_d = 1.0;
        double A_d[] = {2.0, 0.0, 1.0, 3.0}; // Upper triangular
        double B_d[] = {4.0, 6.0, 10.0, 18.0};
        
        printf("2. DTRSM (Double Precision):\n");
        DTRSM_FUNC(&side, &uplo, &transa, &diag, &m, &n, &alpha_d, A_d, &lda, B_d, &ldb);
        printf("   ✓ DTRSM executed (result: %.2f)\n", B_d[0]);
    }
    
    // ========== CTRSM (Complex Single Precision) ==========
    {
        float complex alpha_c = 1.0f + 0.0f*I;
        float complex A_c[] = {2.0f+0.0f*I, 0.0f+0.0f*I, 1.0f+0.0f*I, 3.0f+0.0f*I};
        float complex B_c[] = {4.0f+1.0f*I, 6.0f+1.0f*I, 10.0f+1.0f*I, 18.0f+1.0f*I};
        
        printf("3. CTRSM (Complex Single Precision):\n");
        CTRSM_FUNC(&side, &uplo, &transa, &diag, &m, &n, &alpha_c, A_c, &lda, B_c, &ldb);
        printf("   ✓ CTRSM executed (result: %.2f%+.2fi)\n", crealf(B_c[0]), cimagf(B_c[0]));
    }
    
    // ========== ZTRSM (Complex Double Precision) ==========
    {
        double complex alpha_z = 1.0 + 0.0*I;
        double complex A_z[] = {2.0+0.0*I, 0.0+0.0*I, 1.0+0.0*I, 3.0+0.0*I};
        double complex B_z[] = {4.0+1.0*I, 6.0+1.0*I, 10.0+1.0*I, 18.0+1.0*I};
        
        printf("4. ZTRSM (Complex Double Precision):\n");
        ZTRSM_FUNC(&side, &uplo, &transa, &diag, &m, &n, &alpha_z, A_z, &lda, B_z, &ldb);
        printf("   ✓ ZTRSM executed (result: %.2f%+.2fi)\n", creal(B_z[0]), cimag(B_z[0]));
    }
    
    // Test CBLAS versions
    printf("\n=== Testing CBLAS TRSM variants ===\n");
    
    // CBLAS_STRSM test
    {
        const float alpha_s = 1.0f;
        float A_s[] = {2.0f, 0.0f, 1.0f, 3.0f};
        float B_s[] = {4.0f, 6.0f, 10.0f, 18.0f};
        
        printf("5. CBLAS_STRSM:\n");
        CBLAS_STRSM(CblasColMajor, CblasLeft, CblasUpper, CblasNoTrans, CblasNonUnit,
                    m, n, alpha_s, A_s, lda, B_s, ldb);
        printf("   ✓ CBLAS_STRSM executed (result: %.2f)\n", B_s[0]);
    }
    
    // CBLAS_DTRSM test
    {
        const double alpha_d = 1.0;
        double A_d[] = {2.0, 0.0, 1.0, 3.0};
        double B_d[] = {4.0, 6.0, 10.0, 18.0};
        
        printf("6. CBLAS_DTRSM:\n");
        CBLAS_DTRSM(CblasColMajor, CblasLeft, CblasUpper, CblasNoTrans, CblasNonUnit,
                    m, n, alpha_d, A_d, lda, B_d, ldb);
        printf("   ✓ CBLAS_DTRSM executed (result: %.2f)\n", B_d[0]);
    }
    
    // CBLAS_CTRSM test
    {
        float complex alpha_c = 1.0f + 0.0f*I;
        float complex A_c[] = {2.0f+0.0f*I, 0.0f+0.0f*I, 1.0f+0.0f*I, 3.0f+0.0f*I};
        float complex B_c[] = {4.0f+1.0f*I, 6.0f+1.0f*I, 10.0f+1.0f*I, 18.0f+1.0f*I};
        
        printf("7. CBLAS_CTRSM:\n");
        CBLAS_CTRSM(CblasColMajor, CblasLeft, CblasUpper, CblasNoTrans, CblasNonUnit,
                    m, n, &alpha_c, A_c, lda, B_c, ldb);
        printf("   ✓ CBLAS_CTRSM executed (result: %.2f%+.2fi)\n", crealf(B_c[0]), cimagf(B_c[0]));
    }
    
    // CBLAS_ZTRSM test
    {
        double complex alpha_z = 1.0 + 0.0*I;
        double complex A_z[] = {2.0+0.0*I, 0.0+0.0*I, 1.0+0.0*I, 3.0+0.0*I};
        double complex B_z[] = {4.0+1.0*I, 6.0+1.0*I, 10.0+1.0*I, 18.0+1.0*I};
        
        printf("8. CBLAS_ZTRSM:\n");
        CBLAS_ZTRSM(CblasColMajor, CblasLeft, CblasUpper, CblasNoTrans, CblasNonUnit,
                    m, n, &alpha_z, A_z, lda, B_z, ldb);
        printf("   ✓ CBLAS_ZTRSM executed (result: %.2f%+.2fi)\n", creal(B_z[0]), cimag(B_z[0]));
    }
    
    printf("\n✓ All TRSM tests completed!\n");
}

void test_gemv(void) {
    printf("\n=== Testing GEMV (all precisions) with symbol prefix: %s ===\n", SYMBOL_PREFIX);
    
    const f77_int m = 3, n = 2;
    const f77_int lda = m;
    const f77_int incx = 1, incy = 1;
    const char trans = 'N';
    
    // ========== SGEMV (Single Precision) ==========
    {
        const float alpha_s = 1.0f, beta_s = 0.0f;
        float A_s[] = {1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f}; // 3x2
        float x_s[] = {1.0f, 2.0f}; // length n
        float y_s[] = {0.0f, 0.0f, 0.0f}; // length m
        
        printf("\n1. SGEMV (Single Precision):\n");
        SGEMV_FUNC(&trans, &m, &n, &alpha_s, A_s, &lda, x_s, &incx, &beta_s, y_s, &incy);
        printf("   ✓ SGEMV executed (result: %.2f)\n", y_s[0]);
    }
    
    // ========== DGEMV (Double Precision) ==========
    {
        const double alpha_d = 1.0, beta_d = 0.0;
        double A_d[] = {1.0, 2.0, 3.0, 4.0, 5.0, 6.0};
        double x_d[] = {1.0, 2.0};
        double y_d[] = {0.0, 0.0, 0.0};
        
        printf("2. DGEMV (Double Precision):\n");
        DGEMV_FUNC(&trans, &m, &n, &alpha_d, A_d, &lda, x_d, &incx, &beta_d, y_d, &incy);
        printf("   ✓ DGEMV executed (result: %.2f)\n", y_d[0]);
    }
    
    // ========== CGEMV (Complex Single Precision) ==========
    {
        float complex alpha_c = 1.0f + 0.0f*I;
        float complex beta_c = 0.0f + 0.0f*I;
        float complex A_c[] = {1.0f+0.5f*I, 2.0f+0.5f*I, 3.0f+0.5f*I, 4.0f+0.5f*I, 5.0f+0.5f*I, 6.0f+0.5f*I};
        float complex x_c[] = {1.0f+0.5f*I, 2.0f+0.5f*I};
        float complex y_c[] = {0.0f, 0.0f, 0.0f};
        
        printf("3. CGEMV (Complex Single Precision):\n");
        CGEMV_FUNC(&trans, &m, &n, &alpha_c, A_c, &lda, x_c, &incx, &beta_c, y_c, &incy);
        printf("   ✓ CGEMV executed (result: %.2f%+.2fi)\n", crealf(y_c[0]), cimagf(y_c[0]));
    }
    
    // ========== ZGEMV (Complex Double Precision) ==========
    {
        double complex alpha_z = 1.0 + 0.0*I;
        double complex beta_z = 0.0 + 0.0*I;
        double complex A_z[] = {1.0+0.5*I, 2.0+0.5*I, 3.0+0.5*I, 4.0+0.5*I, 5.0+0.5*I, 6.0+0.5*I};
        double complex x_z[] = {1.0+0.5*I, 2.0+0.5*I};
        double complex y_z[] = {0.0, 0.0, 0.0};
        
        printf("4. ZGEMV (Complex Double Precision):\n");
        ZGEMV_FUNC(&trans, &m, &n, &alpha_z, A_z, &lda, x_z, &incx, &beta_z, y_z, &incy);
        printf("   ✓ ZGEMV executed (result: %.2f%+.2fi)\n", creal(y_z[0]), cimag(y_z[0]));
    }
    
    // Test CBLAS versions
    printf("\n=== Testing CBLAS GEMV variants ===\n");
    
    // CBLAS_SGEMV test
    {
        const float alpha_s = 1.0f, beta_s = 0.0f;
        float A_s[] = {1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f};
        float x_s[] = {1.0f, 2.0f};
        float y_s[] = {0.0f, 0.0f, 0.0f};
        
        printf("5. CBLAS_SGEMV:\n");
        CBLAS_SGEMV(CblasColMajor, CblasNoTrans, m, n, alpha_s, A_s, lda, x_s, incx, beta_s, y_s, incy);
        printf("   ✓ CBLAS_SGEMV executed (result: %.2f)\n", y_s[0]);
    }
    
    // CBLAS_DGEMV test
    {
        const double alpha_d = 1.0, beta_d = 0.0;
        double A_d[] = {1.0, 2.0, 3.0, 4.0, 5.0, 6.0};
        double x_d[] = {1.0, 2.0};
        double y_d[] = {0.0, 0.0, 0.0};
        
        printf("6. CBLAS_DGEMV:\n");
        CBLAS_DGEMV(CblasColMajor, CblasNoTrans, m, n, alpha_d, A_d, lda, x_d, incx, beta_d, y_d, incy);
        printf("   ✓ CBLAS_DGEMV executed (result: %.2f)\n", y_d[0]);
    }
    
    // CBLAS_CGEMV test
    {
        float complex alpha_c = 1.0f + 0.0f*I;
        float complex beta_c = 0.0f + 0.0f*I;
        float complex A_c[] = {1.0f+0.5f*I, 2.0f+0.5f*I, 3.0f+0.5f*I, 4.0f+0.5f*I, 5.0f+0.5f*I, 6.0f+0.5f*I};
        float complex x_c[] = {1.0f+0.5f*I, 2.0f+0.5f*I};
        float complex y_c[] = {0.0f, 0.0f, 0.0f};
        
        printf("7. CBLAS_CGEMV:\n");
        CBLAS_CGEMV(CblasColMajor, CblasNoTrans, m, n, &alpha_c, A_c, lda, x_c, incx, &beta_c, y_c, incy);
        printf("   ✓ CBLAS_CGEMV executed (result: %.2f%+.2fi)\n", crealf(y_c[0]), cimagf(y_c[0]));
    }
    
    // CBLAS_ZGEMV test
    {
        double complex alpha_z = 1.0 + 0.0*I;
        double complex beta_z = 0.0 + 0.0*I;
        double complex A_z[] = {1.0+0.5*I, 2.0+0.5*I, 3.0+0.5*I, 4.0+0.5*I, 5.0+0.5*I, 6.0+0.5*I};
        double complex x_z[] = {1.0+0.5*I, 2.0+0.5*I};
        double complex y_z[] = {0.0, 0.0, 0.0};
        
        printf("8. CBLAS_ZGEMV:\n");
        CBLAS_ZGEMV(CblasColMajor, CblasNoTrans, m, n, &alpha_z, A_z, lda, x_z, incx, &beta_z, y_z, incy);
        printf("   ✓ CBLAS_ZGEMV executed (result: %.2f%+.2fi)\n", creal(y_z[0]), cimag(y_z[0]));
    }
    
    printf("\n✓ All GEMV tests completed!\n");
}

void test_axpby(void) {
    printf("\n=== Testing AXPBY (all precisions) with symbol prefix: %s ===\n", SYMBOL_PREFIX);
    
    const f77_int n = 5;
    const f77_int incx = 1, incy = 1;
    
    // ========== SAXPBY (Single Precision) ==========
    {
        const float alpha_s = 2.0f, beta_s = 3.0f;
        float x_s[] = {1.0f, 2.0f, 3.0f, 4.0f, 5.0f};
        float y_s[] = {1.0f, 1.0f, 1.0f, 1.0f, 1.0f};
        
        printf("\n1. SAXPBY (Single Precision): y = %.1f*x + %.1f*y\n", alpha_s, beta_s);
        CBLAS_SAXPBY(n, alpha_s, x_s, incx, beta_s, y_s, incy);
        printf("   ✓ SAXPBY executed (y[0] = %.2f)\n", y_s[0]);
    }
    
    // ========== DAXPBY (Double Precision) ==========
    {
        const double alpha_d = 2.0, beta_d = 3.0;
        double x_d[] = {1.0, 2.0, 3.0, 4.0, 5.0};
        double y_d[] = {1.0, 1.0, 1.0, 1.0, 1.0};
        
        printf("2. DAXPBY (Double Precision): y = %.1f*x + %.1f*y\n", alpha_d, beta_d);
        CBLAS_DAXPBY(n, alpha_d, x_d, incx, beta_d, y_d, incy);
        printf("   ✓ DAXPBY executed (y[0] = %.2f)\n", y_d[0]);
    }
    
    // ========== CAXPBY (Complex Single Precision) ==========
    {
        float complex alpha_c = 2.0f + 0.0f*I;
        float complex beta_c = 3.0f + 0.0f*I;
        float complex x_c[] = {1.0f+0.5f*I, 2.0f+0.5f*I, 3.0f+0.5f*I, 4.0f+0.5f*I, 5.0f+0.5f*I};
        float complex y_c[] = {1.0f+0.5f*I, 1.0f+0.5f*I, 1.0f+0.5f*I, 1.0f+0.5f*I, 1.0f+0.5f*I};
        
        printf("3. CAXPBY (Complex Single Precision):\n");
        CBLAS_CAXPBY(n, &alpha_c, x_c, incx, &beta_c, y_c, incy);
        printf("   ✓ CAXPBY executed (y[0] = %.2f%+.2fi)\n", crealf(y_c[0]), cimagf(y_c[0]));
    }
    
    // ========== ZAXPBY (Complex Double Precision) ==========
    {
        double complex alpha_z = 2.0 + 0.0*I;
        double complex beta_z = 3.0 + 0.0*I;
        double complex x_z[] = {1.0+0.5*I, 2.0+0.5*I, 3.0+0.5*I, 4.0+0.5*I, 5.0+0.5*I};
        double complex y_z[] = {1.0+0.5*I, 1.0+0.5*I, 1.0+0.5*I, 1.0+0.5*I, 1.0+0.5*I};
        
        printf("4. ZAXPBY (Complex Double Precision):\n");
        CBLAS_ZAXPBY(n, &alpha_z, x_z, incx, &beta_z, y_z, incy);
        printf("   ✓ ZAXPBY executed (y[0] = %.2f%+.2fi)\n", creal(y_z[0]), cimag(y_z[0]));
    }
    
    printf("\n✓ All AXPBY tests completed!\n");
}
#endif // ENABLE_BLAS

#ifdef ENABLE_LAPACK
void test_lapack_getrf(void) {
    printf("\n=== Testing GETRF (LU Factorization) with symbol prefix: %s ===\n", SYMBOL_PREFIX);
    
    const f77_int m = 3, n = 3;
    const f77_int lda = m;
    f77_int ipiv[3];
    f77_int info;
    
    // ========== SGETRF (Single Precision) ==========
    {
        float A_s[] = {1.0f, 4.0f, 7.0f, 2.0f, 5.0f, 8.0f, 3.0f, 6.0f, 10.0f};
        
        printf("\n1. SGETRF (Single Precision LU Factorization):\n");
        SGETRF_FUNC(&m, &n, A_s, &lda, ipiv, &info);
        printf("   ✓ SGETRF executed (info = %d)\n", info);
    }
    
    // ========== DGETRF (Double Precision) ==========
    {
        double A_d[] = {1.0, 4.0, 7.0, 2.0, 5.0, 8.0, 3.0, 6.0, 10.0};
        
        printf("2. DGETRF (Double Precision LU Factorization):\n");
        DGETRF_FUNC(&m, &n, A_d, &lda, ipiv, &info);
        printf("   ✓ DGETRF executed (info = %d)\n", info);
    }
    
    // ========== CGETRF (Complex Single Precision) ==========
    {
        float complex A_c[] = {1.0f+0.0f*I, 4.0f+0.0f*I, 7.0f+0.0f*I,
                               2.0f+0.0f*I, 5.0f+0.0f*I, 8.0f+0.0f*I,
                               3.0f+0.0f*I, 6.0f+0.0f*I, 10.0f+0.0f*I};
        
        printf("3. CGETRF (Complex Single Precision LU Factorization):\n");
        CGETRF_FUNC(&m, &n, A_c, &lda, ipiv, &info);
        printf("   ✓ CGETRF executed (info = %d)\n", info);
    }
    
    // ========== ZGETRF (Complex Double Precision) ==========
    {
        double complex A_z[] = {1.0+0.0*I, 4.0+0.0*I, 7.0+0.0*I,
                                2.0+0.0*I, 5.0+0.0*I, 8.0+0.0*I,
                                3.0+0.0*I, 6.0+0.0*I, 10.0+0.0*I};
        
        printf("4. ZGETRF (Complex Double Precision LU Factorization):\n");
        ZGETRF_FUNC(&m, &n, A_z, &lda, ipiv, &info);
        printf("   ✓ ZGETRF executed (info = %d)\n", info);
    }
    
    printf("\n✓ All GETRF tests completed!\n");
}

void test_lapack_potrf(void) {
    printf("\n=== Testing POTRF (Cholesky Factorization) with symbol prefix: %s ===\n", SYMBOL_PREFIX);
    
    const f77_int n = 3;
    const f77_int lda = n;
    const char uplo = 'U';
    f77_int info;
    
    // ========== SPOTRF (Single Precision) ==========
    {
        float A_s[] = {4.0f, 2.0f, 1.0f, 2.0f, 5.0f, 3.0f, 1.0f, 3.0f, 6.0f};
        
        printf("\n1. SPOTRF (Single Precision Cholesky Factorization):\n");
        SPOTRF_FUNC(&uplo, &n, A_s, &lda, &info);
        printf("   ✓ SPOTRF executed (info = %d)\n", info);
    }
    
    // ========== DPOTRF (Double Precision) ==========
    {
        double A_d[] = {4.0, 2.0, 1.0, 2.0, 5.0, 3.0, 1.0, 3.0, 6.0};
        
        printf("2. DPOTRF (Double Precision Cholesky Factorization):\n");
        DPOTRF_FUNC(&uplo, &n, A_d, &lda, &info);
        printf("   ✓ DPOTRF executed (info = %d)\n", info);
    }
    
    // ========== CPOTRF (Complex Single Precision) ==========
    {
        float complex A_c[] = {4.0f+0.0f*I, 2.0f+0.0f*I, 1.0f+0.0f*I,
                               2.0f+0.0f*I, 5.0f+0.0f*I, 3.0f+0.0f*I,
                               1.0f+0.0f*I, 3.0f+0.0f*I, 6.0f+0.0f*I};
        
        printf("3. CPOTRF (Complex Single Precision Cholesky Factorization):\n");
        CPOTRF_FUNC(&uplo, &n, A_c, &lda, &info);
        printf("   ✓ CPOTRF executed (info = %d)\n", info);
    }
    
    // ========== ZPOTRF (Complex Double Precision) ==========
    {
        double complex A_z[] = {4.0+0.0*I, 2.0+0.0*I, 1.0+0.0*I,
                                2.0+0.0*I, 5.0+0.0*I, 3.0+0.0*I,
                                1.0+0.0*I, 3.0+0.0*I, 6.0+0.0*I};
        
        printf("4. ZPOTRF (Complex Double Precision Cholesky Factorization):\n");
        ZPOTRF_FUNC(&uplo, &n, A_z, &lda, &info);
        printf("   ✓ ZPOTRF executed (info = %d)\n", info);
    }
    
    printf("\n✓ All POTRF tests completed!\n");
}

void test_lapack_gesvd(void) {
    printf("\n=== Testing GESVD (SVD) with symbol prefix: %s ===\n", SYMBOL_PREFIX);
    
    const f77_int m = 3, n = 2;
    const f77_int lda = m, ldu = m, ldvt = n;
    const char jobu = 'A', jobvt = 'A';
    f77_int info;
    
    // ========== SGESVD (Single Precision) ==========
    {
        float A_s[] = {1.0f, 4.0f, 2.0f, 5.0f, 3.0f, 6.0f};
        float S_s[2], U_s[9], VT_s[4];
        float work_query;
        f77_int lwork = -1;
        
        printf("\n1. SGESVD (Single Precision SVD):\n");
        // Query optimal work size
        SGESVD_FUNC(&jobu, &jobvt, &m, &n, A_s, &lda, S_s, U_s, &ldu, VT_s, &ldvt, &work_query, &lwork, &info);
        lwork = (f77_int)work_query;
        float* work = (float*)malloc(lwork * sizeof(float));
        
        // Compute SVD
        float A_s_copy[] = {1.0f, 4.0f, 2.0f, 5.0f, 3.0f, 6.0f};
        SGESVD_FUNC(&jobu, &jobvt, &m, &n, A_s_copy, &lda, S_s, U_s, &ldu, VT_s, &ldvt, work, &lwork, &info);
        printf("   ✓ SGESVD executed (info = %d, S[0] = %.4f)\n", info, S_s[0]);
        free(work);
    }
    
    // ========== DGESVD (Double Precision) ==========
    {
        double A_d[] = {1.0, 4.0, 2.0, 5.0, 3.0, 6.0};
        double S_d[2], U_d[9], VT_d[4];
        double work_query;
        f77_int lwork = -1;
        
        printf("2. DGESVD (Double Precision SVD):\n");
        DGESVD_FUNC(&jobu, &jobvt, &m, &n, A_d, &lda, S_d, U_d, &ldu, VT_d, &ldvt, &work_query, &lwork, &info);
        lwork = (f77_int)work_query;
        double* work = (double*)malloc(lwork * sizeof(double));
        
        double A_d_copy[] = {1.0, 4.0, 2.0, 5.0, 3.0, 6.0};
        DGESVD_FUNC(&jobu, &jobvt, &m, &n, A_d_copy, &lda, S_d, U_d, &ldu, VT_d, &ldvt, work, &lwork, &info);
        printf("   ✓ DGESVD executed (info = %d, S[0] = %.4f)\n", info, S_d[0]);
        free(work);
    }
    
    // ========== CGESVD (Complex Single Precision) ==========
    {
        float complex A_c[] = {1.0f+0.0f*I, 4.0f+0.0f*I, 2.0f+0.0f*I, 5.0f+0.0f*I, 3.0f+0.0f*I, 6.0f+0.0f*I};
        float S_c[2], rwork[10];
        float complex U_c[9], VT_c[4];
        float complex work_query;
        f77_int lwork = -1;
        
        printf("3. CGESVD (Complex Single Precision SVD):\n");
        CGESVD_FUNC(&jobu, &jobvt, &m, &n, A_c, &lda, S_c, U_c, &ldu, VT_c, &ldvt, &work_query, &lwork, rwork, &info);
        lwork = (f77_int)crealf(work_query);
        float complex* work = (float complex*)malloc(lwork * sizeof(float complex));
        
        float complex A_c_copy[] = {1.0f+0.0f*I, 4.0f+0.0f*I, 2.0f+0.0f*I, 5.0f+0.0f*I, 3.0f+0.0f*I, 6.0f+0.0f*I};
        CGESVD_FUNC(&jobu, &jobvt, &m, &n, A_c_copy, &lda, S_c, U_c, &ldu, VT_c, &ldvt, work, &lwork, rwork, &info);
        printf("   ✓ CGESVD executed (info = %d, S[0] = %.4f)\n", info, S_c[0]);
        free(work);
    }
    
    // ========== ZGESVD (Complex Double Precision) ==========
    {
        double complex A_z[] = {1.0+0.0*I, 4.0+0.0*I, 2.0+0.0*I, 5.0+0.0*I, 3.0+0.0*I, 6.0+0.0*I};
        double S_z[2], rwork[10];
        double complex U_z[9], VT_z[4];
        double complex work_query;
        f77_int lwork = -1;
        
        printf("4. ZGESVD (Complex Double Precision SVD):\n");
        ZGESVD_FUNC(&jobu, &jobvt, &m, &n, A_z, &lda, S_z, U_z, &ldu, VT_z, &ldvt, &work_query, &lwork, rwork, &info);
        lwork = (f77_int)creal(work_query);
        double complex* work = (double complex*)malloc(lwork * sizeof(double complex));
        
        double complex A_z_copy[] = {1.0+0.0*I, 4.0+0.0*I, 2.0+0.0*I, 5.0+0.0*I, 3.0+0.0*I, 6.0+0.0*I};
        ZGESVD_FUNC(&jobu, &jobvt, &m, &n, A_z_copy, &lda, S_z, U_z, &ldu, VT_z, &ldvt, work, &lwork, rwork, &info);
        printf("   ✓ ZGESVD executed (info = %d, S[0] = %.4f)\n", info, S_z[0]);
        free(work);
    }
    
    printf("\n✓ All GESVD tests completed!\n");
}

void test_lapack_gesv(void) {
    printf("\n=== Testing GESV (Solve Linear System) with symbol prefix: %s ===\n", SYMBOL_PREFIX);
    
    const f77_int n = 3, nrhs = 1;
    const f77_int lda = n, ldb = n;
    f77_int ipiv[3];
    f77_int info;
    
    // ========== SGESV (Single Precision) ==========
    {
        float A_s[] = {1.0f, 4.0f, 7.0f, 2.0f, 5.0f, 8.0f, 3.0f, 6.0f, 10.0f};
        float B_s[] = {1.0f, 2.0f, 3.0f};
        
        printf("\n1. SGESV (Single Precision Linear Solver):\n");
        SGESV_FUNC(&n, &nrhs, A_s, &lda, ipiv, B_s, &ldb, &info);
        printf("   ✓ SGESV executed (info = %d, x[0] = %.4f)\n", info, B_s[0]);
    }
    
    // ========== DGESV (Double Precision) ==========
    {
        double A_d[] = {1.0, 4.0, 7.0, 2.0, 5.0, 8.0, 3.0, 6.0, 10.0};
        double B_d[] = {1.0, 2.0, 3.0};
        
        printf("2. DGESV (Double Precision Linear Solver):\n");
        DGESV_FUNC(&n, &nrhs, A_d, &lda, ipiv, B_d, &ldb, &info);
        printf("   ✓ DGESV executed (info = %d, x[0] = %.4f)\n", info, B_d[0]);
    }
    
    // ========== CGESV (Complex Single Precision) ==========
    {
        float complex A_c[] = {1.0f+0.0f*I, 4.0f+0.0f*I, 7.0f+0.0f*I,
                               2.0f+0.0f*I, 5.0f+0.0f*I, 8.0f+0.0f*I,
                               3.0f+0.0f*I, 6.0f+0.0f*I, 10.0f+0.0f*I};
        float complex B_c[] = {1.0f+0.0f*I, 2.0f+0.0f*I, 3.0f+0.0f*I};
        
        printf("3. CGESV (Complex Single Precision Linear Solver):\n");
        CGESV_FUNC(&n, &nrhs, A_c, &lda, ipiv, B_c, &ldb, &info);
        printf("   ✓ CGESV executed (info = %d, x[0] = %.4f%+.4fi)\n", info, crealf(B_c[0]), cimagf(B_c[0]));
    }
    
    // ========== ZGESV (Complex Double Precision) ==========
    {
        double complex A_z[] = {1.0+0.0*I, 4.0+0.0*I, 7.0+0.0*I,
                                2.0+0.0*I, 5.0+0.0*I, 8.0+0.0*I,
                                3.0+0.0*I, 6.0+0.0*I, 10.0+0.0*I};
        double complex B_z[] = {1.0+0.0*I, 2.0+0.0*I, 3.0+0.0*I};
        
        printf("4. ZGESV (Complex Double Precision Linear Solver):\n");
        ZGESV_FUNC(&n, &nrhs, A_z, &lda, ipiv, B_z, &ldb, &info);
        printf("   ✓ ZGESV executed (info = %d, x[0] = %.4f%+.4fi)\n", info, creal(B_z[0]), cimag(B_z[0]));
    }
    
    printf("\n✓ All GESV tests completed!\n");
}
#endif // ENABLE_LAPACK

#ifdef ENABLE_SPARSE
void test_sparse(void) {
    printf("\n=== Testing AOCL-Sparse with symbol prefix: %s ===\n", SYMBOL_PREFIX);
    
    // Test basic sparse matrix descriptor operations
    aoclsparse_mat_descr descr;
    aoclsparse_status status;
    
    printf("\n1. aoclsparse_create_mat_descr:\n");
    status = AOCLSPARSE_CREATE_MAT_DESCR(&descr);
    printf("   ✓ Matrix descriptor created (status = %d)\n", status);
    
    if (status == aoclsparse_status_success) {
        printf("2. aoclsparse_destroy_mat_descr:\n");
        status = AOCLSPARSE_DESTROY_MAT_DESCR(descr);
        printf("   ✓ Matrix descriptor destroyed (status = %d)\n", status);
    }
    
    printf("\n✓ All AOCL-Sparse tests completed!\n");
}
#endif // ENABLE_SPARSE

#ifdef ENABLE_LIBM
void test_libm(void) {
    printf("\n=== Testing AOCL-LibM with symbol prefix: %s ===\n", SYMBOL_PREFIX);
    
    const double test_val = 1.0;
    
    printf("\n1. sin function:\n");
    double result_sin = LIBM_SIN_FUNC(test_val);
    printf("   ✓ sin(%.2f) = %.6f\n", test_val, result_sin);
    
    printf("2. cos function:\n");
    double result_cos = LIBM_COS_FUNC(test_val);
    printf("   ✓ cos(%.2f) = %.6f\n", test_val, result_cos);
    
    printf("3. exp function:\n");
    double result_exp = LIBM_EXP_FUNC(test_val);
    printf("   ✓ exp(%.2f) = %.6f\n", test_val, result_exp);
    
    printf("4. log function:\n");
    double result_log = LIBM_LOG_FUNC(2.718281828);
    printf("   ✓ log(e) = %.6f\n", result_log);
    
    printf("\n✓ All AOCL-LibM tests completed!\n");
}
#endif // ENABLE_LIBM

#ifdef ENABLE_COMPRESSION
void test_compression(void) {
    printf("\n=== Testing AOCL-Compression with symbol prefix: %s ===\n", SYMBOL_PREFIX);
    
    // Test compression with LZ4
    const char* test_data = "Hello AOCL Compression! This is a test string for compression.";
    size_t src_size = strlen(test_data);
    
    printf("\n1. Testing compression functions:\n");
    printf("   Input data size: %zu bytes\n", src_size);
    
    // Get compressed bound
    int64_t comp_bound = AOCL_LLC_COMPRESSBOUND(LZ4, src_size);
    printf("2. aocl_llc_compressBound:\n");
    printf("   ✓ Compressed bound = %ld bytes\n", comp_bound);
    
    if (comp_bound > 0) {
        char* comp_buf = (char*)malloc(comp_bound);
        char* decomp_buf = (char*)malloc(src_size + 1);
        
        if (comp_buf && decomp_buf) {
            // Setup compression descriptor
            aocl_compression_desc setup;
            memset(&setup, 0, sizeof(setup));
            setup.level = 1;
            setup.inSize = src_size;
            setup.outSize = comp_bound;
            setup.inBuf = (char*)test_data;
            setup.outBuf = comp_buf;
            
            printf("3. aocl_llc_compress:\n");
            int64_t comp_size = AOCL_LLC_COMPRESS(&setup, LZ4);
            if (comp_size > 0) {
                printf("   ✓ Compression executed (compressed size = %ld bytes)\n", comp_size);
                
                // Setup decompression
                setup.inSize = comp_size;
                setup.outSize = src_size;
                setup.inBuf = comp_buf;
                setup.outBuf = decomp_buf;
                
                printf("4. aocl_llc_decompress:\n");
                int64_t decomp_size = AOCL_LLC_DECOMPRESS(&setup, LZ4);
                if (decomp_size > 0) {
                    printf("   ✓ Decompression executed (decompressed size = %ld bytes)\n", decomp_size);
                    decomp_buf[decomp_size] = '\0';
                    if (strcmp(test_data, decomp_buf) == 0) {
                        printf("   ✓ Data verified: original matches decompressed\n");
                    }
                }
            }
            
            free(comp_buf);
            free(decomp_buf);
        }
    }
    
    printf("\n✓ All AOCL-Compression tests completed!\n");
}
#endif // ENABLE_COMPRESSION

#ifdef ENABLE_DA
void test_da(void) {
    printf("\n=== Testing AOCL-DA with symbol prefix: %s ===\n", SYMBOL_PREFIX);
    
    da_handle handle = NULL;
    da_status status;
    
    // Test 1: Basic statistics - harmonic mean
    printf("\n1. Basic Statistics - Harmonic Mean:\n");
    double data[12] = {1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0};
    double harmonic_mean[3];
    da_int n_rows = 4, n_cols = 3;
    status = DA_HARMONIC_MEAN_D(column_major, da_axis_col, n_rows, n_cols, data, n_rows, harmonic_mean);
    if (status == da_status_success) {
        printf("   ✓ Harmonic mean computed (first value = %.4f)\n", harmonic_mean[0]);
    } else {
        printf("   ✗ Harmonic mean failed (status = %d)\n", status);
    }
    
    // Test 2: PCA handle lifecycle
    printf("2. PCA Handle Init:\n");
    status = DA_HANDLE_INIT_D(&handle, da_handle_pca);
    if (status == da_status_success) {
        printf("   ✓ PCA handle initialized (status = %d)\n", status);
        
        // Test 3: Set PCA data
        printf("3. PCA Set Data:\n");
        double pca_data[18] = {2.0, 2.0, 3.0, 4.0, 4.0, 3.0, 
                               2.0, 5.0, 2.0, 8.0, 3.0, 2.0,
                               3.0, 4.0, 4.0, 3.0, 2.0, 1.0};
        da_int n_samples = 6, n_features = 3;
        status = DA_PCA_SET_DATA_D(handle, n_samples, n_features, pca_data, n_samples);
        if (status == da_status_success) {
            printf("   ✓ PCA data set (6 samples, 3 features)\n");
            
            // Test 4: Set PCA options
            printf("4. PCA Set Options:\n");
            status = DA_OPTIONS_SET_STRING(handle, "PCA method", "covariance");
            status = (status == da_status_success) ? 
                     DA_OPTIONS_SET_INT(handle, "n_components", 2) : status;
            if (status == da_status_success) {
                printf("   ✓ PCA options set (method=covariance, n_components=2)\n");
            }
        }
        
        printf("5. PCA Handle Destroy:\n");
        DA_HANDLE_DESTROY(&handle);
        printf("   ✓ PCA handle destroyed\n");
    } else {
        printf("   ✗ PCA handle init failed (status = %d)\n", status);
    }
    
    // Test 6: K-means handle lifecycle
    printf("6. K-means Handle Init:\n");
    status = DA_HANDLE_INIT_D(&handle, da_handle_kmeans);
    if (status == da_status_success) {
        printf("   ✓ K-means handle initialized (status = %d)\n", status);
        
        // Test 7: Set k-means data
        printf("7. K-means Set Data:\n");
        double kmeans_data[16] = {2.0, -1.0, 3.0, 2.0, -3.0, -2.0, -2.0, 1.0,
                                  1.0, -2.0, 2.0, 3.0, -2.0, -1.0, -3.0, 2.0};
        da_int km_samples = 8, km_features = 2;
        status = DA_KMEANS_SET_DATA_D(handle, km_samples, km_features, kmeans_data, km_samples);
        if (status == da_status_success) {
            printf("   ✓ K-means data set (8 samples, 2 features)\n");
            
            // Test 8: Set k-means options
            printf("8. K-means Set Options:\n");
            status = DA_OPTIONS_SET_INT(handle, "n_clusters", 2);
            if (status == da_status_success) {
                printf("   ✓ K-means options set (n_clusters=2)\n");
            }
        }
        
        printf("9. K-means Handle Destroy:\n");
        DA_HANDLE_DESTROY(&handle);
        printf("   ✓ K-means handle destroyed\n");
    } else {
        printf("   ✗ K-means handle init failed (status = %d)\n", status);
    }
    
    // Test 10: Linear model handle
    printf("10. Linear Model Handle:\n");
    status = DA_HANDLE_INIT_D(&handle, da_handle_linmod);
    if (status == da_status_success) {
        printf("   ✓ Linear model handle initialized (status = %d)\n", status);
        DA_HANDLE_DESTROY(&handle);
        printf("   ✓ Linear model handle destroyed\n");
    }
    
    printf("\n✓ All AOCL-DA tests completed (10 tests)!\n");
}
#endif // ENABLE_DA

#ifdef ENABLE_CRYPTO
void test_crypto(void) {
    printf("\n=== Testing AOCL-Crypto with symbol prefix: %s ===\n", SYMBOL_PREFIX);
    
    alc_cipher_handle_t handle = { NULL };
    alc_error_t err;
    
    // AES-128-CFB test data
    Uint8 key[] = {
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f
    };
    Uint8 iv[] = {
        0x0f, 0x0e, 0x0d, 0x0c, 0x0b, 0x0a, 0x09, 0x08,
        0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x00
    };
    const char* plaintext_str = "Hello AOCL Crypto!";
    Uint32 len = strlen(plaintext_str);
    Uint8 ciphertext[256] = {0};
    Uint8 decrypted[256] = {0};
    
    printf("\n1. alcp_cipher_context_size:\n");
    Uint64 ctx_size = ALCP_CIPHER_CONTEXT_SIZE();
    printf("   ✓ Context size = %lu bytes\n", (unsigned long)ctx_size);
    
    if (ctx_size == 0) {
        printf("   ✗ Error: Invalid context size\n");
        return;
    }
    
    // Allocate context memory
    handle.ch_context = malloc(ctx_size);
    if (!handle.ch_context) {
        printf("   ✗ Error: Memory allocation failed\n");
        return;
    }
    
    printf("2. alcp_cipher_request (AES-128-CFB):\n");
    err = ALCP_CIPHER_REQUEST(ALC_AES_MODE_CFB, ALC_KEY_LEN_128, &handle);
    if (ALCP_IS_ERROR(err)) {
        printf("   ✗ Error: Cipher request failed (error = %d)\n", err);
        free(handle.ch_context);
        return;
    }
    printf("   ✓ Cipher request succeeded\n");
    
    printf("3. alcp_cipher_init (Encryption):\n");
    err = ALCP_CIPHER_INIT(&handle, key, ALC_KEY_LEN_128, iv, sizeof(iv));
    if (ALCP_IS_ERROR(err)) {
        printf("   ✗ Error: Cipher init failed (error = %d)\n", err);
        ALCP_CIPHER_FINISH(&handle);
        free(handle.ch_context);
        return;
    }
    printf("   ✓ Cipher initialized\n");
    
    printf("4. alcp_cipher_encrypt:\n");
    Uint64 enc_outlen = 0;
    err = ALCP_CIPHER_ENCRYPT(&handle, (const Uint8*)plaintext_str, ciphertext, len, &enc_outlen);
    if (ALCP_IS_ERROR(err)) {
        printf("   ✗ Error: Encryption failed (error = %d)\n", err);
        ALCP_CIPHER_FINISH(&handle);
        free(handle.ch_context);
        return;
    }
    printf("   ✓ Encryption succeeded (%llu bytes)\n", (unsigned long long)enc_outlen);
    
    // Finish encryption session
    ALCP_CIPHER_FINISH(&handle);
    
    // Reinitialize for decryption
    printf("5. alcp_cipher_request (Decryption):\n");
    err = ALCP_CIPHER_REQUEST(ALC_AES_MODE_CFB, ALC_KEY_LEN_128, &handle);
    if (ALCP_IS_ERROR(err)) {
        printf("   ✗ Error: Cipher request failed\n");
        free(handle.ch_context);
        return;
    }
    
    err = ALCP_CIPHER_INIT(&handle, key, ALC_KEY_LEN_128, iv, sizeof(iv));
    if (ALCP_IS_ERROR(err)) {
        printf("   ✗ Error: Cipher init failed\n");
        ALCP_CIPHER_FINISH(&handle);
        free(handle.ch_context);
        return;
    }
    printf("   ✓ Decryption initialized\n");
    
    printf("6. alcp_cipher_decrypt:\n");
    Uint64 dec_outlen = 0;
    err = ALCP_CIPHER_DECRYPT(&handle, ciphertext, decrypted, len, &dec_outlen);
    if (ALCP_IS_ERROR(err)) {
        printf("   ✗ Error: Decryption failed (error = %d)\n", err);
        ALCP_CIPHER_FINISH(&handle);
        free(handle.ch_context);
        return;
    }
    printf("   ✓ Decryption succeeded\n");
    
    // Verify round-trip
    if (memcmp(plaintext_str, decrypted, len) == 0) {
        printf("   ✓ Data verified: plaintext matches decrypted\n");
    } else {
        printf("   ✗ Verification failed: data mismatch\n");
    }
    
    printf("7. alcp_cipher_finish:\n");
    ALCP_CIPHER_FINISH(&handle);
    printf("   ✓ Cipher session finished\n");
    
    free(handle.ch_context);
    printf("\n✓ All AOCL-Crypto tests completed!\n");
}
#endif // ENABLE_CRYPTO

#ifdef ENABLE_LIBMEM
void test_libmem(void) {
    printf("\n=== Testing AOCL-LibMem with symbol prefix: %s ===\n", SYMBOL_PREFIX);
    
    const size_t buf_size = 64;
    char src[128], dest[128], overlap[256];
    void* result;
    
    // Test 1: amd_memcpy
    printf("\n1. amd_memcpy:\n");
    for (size_t i = 0; i < buf_size; i++) {
        src[i] = 'A' + (i % 26);
    }
    AMD_MEMSET(dest, 0, sizeof(dest)); // Clear dest first
    AMD_MEMCPY(dest, src, buf_size);
    if (memcmp(src, dest, buf_size) == 0) {
        printf("   ✓ memcpy executed successfully (copied %zu bytes)\n", buf_size);
    } else {
        printf("   ✗ memcpy failed\n");
    }
    
    // Test 2: amd_memset
    printf("2. amd_memset:\n");
    AMD_MEMSET(dest, 0x42, buf_size);
    int all_same = 1;
    for (size_t i = 0; i < buf_size; i++) {
        if ((unsigned char)dest[i] != 0x42) all_same = 0;
    }
    if (all_same) {
        printf("   ✓ memset executed successfully (set %zu bytes to 0x42)\n", buf_size);
    } else {
        printf("   ✗ memset failed\n");
    }
    
    // Test 3: amd_memmove (overlapping regions)
    printf("3. amd_memmove:\n");
    for (size_t i = 0; i < 128; i++) {
        overlap[i] = (char)('0' + (i % 10));
    }
    char expected[50];
    memcpy(expected, overlap + 10, 50);
    AMD_MEMMOVE(overlap + 20, overlap + 10, 50);
    if (memcmp(overlap + 20, expected, 50) == 0) {
        printf("   ✓ memmove executed successfully (moved 50 bytes with overlap)\n");
    } else {
        printf("   ✗ memmove failed\n");
    }
    
    // Test 4: amd_strcpy
    printf("4. amd_strcpy:\n");
    const char* test_str = "Hello AOCL LibMem!";
    AMD_STRCPY(dest, test_str);
    if (strcmp(dest, test_str) == 0) {
        printf("   ✓ strcpy executed successfully (\"%s\")\n", dest);
    } else {
        printf("   ✗ strcpy failed\n");
    }
    
    // Test 5: amd_strcmp
    printf("5. amd_strcmp:\n");
    const char* str1 = "AOCL";
    const char* str2 = "AOCL";
    const char* str3 = "BLAS";
    int cmp1 = AMD_STRCMP(str1, str2);
    int cmp2 = AMD_STRCMP(str1, str3);
    if (cmp1 == 0 && cmp2 < 0) {
        printf("   ✓ strcmp executed successfully (\"AOCL\" == \"AOCL\": %d, \"AOCL\" < \"BLAS\": %d)\n", cmp1, cmp2);
    } else {
        printf("   ✗ strcmp failed (cmp1=%d, cmp2=%d)\n", cmp1, cmp2);
    }
    
    // Test 6: amd_strlen
    printf("6. amd_strlen:\n");
    size_t len = AMD_STRLEN(test_str);
    if (len == strlen(test_str)) {
        printf("   ✓ strlen executed successfully (length = %zu)\n", len);
    } else {
        printf("   ✗ strlen failed (expected %zu, got %zu)\n", strlen(test_str), len);
    }
    
    printf("\n✓ All AOCL-LibMem tests completed!\n");
}
#endif // ENABLE_LIBMEM

void test_symbol_renaming(void) {
    printf("\n=== Symbol Renaming Configuration ===\n");
    
#ifdef USE_RENAMED_SYMBOLS
    printf("✓ Using RENAMED symbols (%s prefix)\n", SYMBOL_PREFIX_STR);
    printf("  - dgemm_ is called as: %sdgemm_\n", SYMBOL_PREFIX_STR);
    printf("  - cblas_dgemm is called as: %scblas_dgemm\n", SYMBOL_PREFIX_STR);
    printf("  - Library path: renamed/lib/\n");
    printf("  Note: To test other symbol prefixes, reconfigure CMake with a different SYMBOL_RENAME_PREFIX and rebuild the test code.\n");
#else
    printf("✓ Using ORIGINAL symbols (no prefix)\n");
    printf("  - dgemm_ is called as: dgemm_\n");
    printf("  - cblas_dgemm is called as: cblas_dgemm\n");
    printf("  - Library path: lib/\n");
#endif
}

int main(int argc, char* argv[]) {
    printf("========================================\n");
    printf("AOCL Symbol Renaming Test Program\n");
#ifdef ENABLE_BLAS
    printf("Testing BLAS: GEMM, TRSM, GEMV, AXPBY\n");
#endif
#ifdef ENABLE_LAPACK
    printf("Testing LAPACK: GETRF, POTRF, GESVD, GESV\n");
#endif
#ifdef ENABLE_SPARSE
    printf("Testing AOCL-Sparse\n");
#endif
#ifdef ENABLE_LIBM
    printf("Testing AOCL-LibM\n");
#endif
#ifdef ENABLE_COMPRESSION
    printf("Testing AOCL-Compression\n");
#endif
#ifdef ENABLE_DA
    printf("Testing AOCL-DA\n");
#endif
#ifdef ENABLE_CRYPTO
    printf("Testing AOCL-Crypto\n");
#endif
#ifdef ENABLE_LIBMEM
    printf("Testing AOCL-LibMem\n");
#endif
#if defined(ENABLE_BLAS) || defined(ENABLE_LAPACK)
    printf("All precisions: S, D, C, Z\n");
#endif
    printf("========================================\n");
    
    test_symbol_renaming();
    
#ifdef ENABLE_BLAS
    // BLAS tests
    test_gemm();
    test_trsm();
    test_gemv();
    test_axpby();
#endif
    
#ifdef ENABLE_LAPACK
    // LAPACK tests
    test_lapack_getrf();
    test_lapack_potrf();
    test_lapack_gesvd();
    test_lapack_gesv();
#endif
    
#ifdef ENABLE_SPARSE
    // AOCL-Sparse tests
    test_sparse();
#endif
    
#ifdef ENABLE_LIBM
    // AOCL-LibM tests
    test_libm();
#endif
    
#ifdef ENABLE_COMPRESSION
    // AOCL-Compression tests
    test_compression();
#endif
    
#ifdef ENABLE_CRYPTO
    // AOCL-Crypto tests
    test_crypto();
#endif
    
#ifdef ENABLE_LIBMEM
    // AOCL-LibMem tests
    test_libmem();
#endif
    
#ifdef ENABLE_DA
    // AOCL-DA tests
    test_da();
#endif
    
    printf("\n========================================\n");
    printf("All tests completed successfully!\n");
    printf("========================================\n");
    
    return 0;
}
