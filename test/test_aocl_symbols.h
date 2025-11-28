// Copyright (C) 2025-2026, Advanced Micro Devices, Inc. All rights reserved.

#ifndef TEST_AOCL_SYMBOLS_H
#define TEST_AOCL_SYMBOLS_H

#ifdef __cplusplus
extern "C" {
#endif

// Function to test BLAS GEMM (all precisions: S, D, C, Z)
void test_gemm(void);

// Function to test BLAS TRSM (all precisions: S, D, C, Z)
void test_trsm(void);

// Function to test BLAS GEMV (all precisions: S, D, C, Z)
void test_gemv(void);

// Function to test BLAS AXPBY (all precisions: S, D, C, Z)
void test_axpby(void);

// Function to test symbol renaming
void test_symbol_renaming(void);

#ifdef __cplusplus
}
#endif

#endif // TEST_AOCL_SYMBOLS_H
