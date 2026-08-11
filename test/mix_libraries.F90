! Copyright (C) 2025-2026, Advanced Micro Devices, Inc. All rights reserved.

      PROGRAM mix_libraries

!$      Use omp_lib
      Implicit None

      Character :: transa, transb
      Integer :: M, N, K, ntest, i, j, lda, ldb, ldc, np, me, nt, ntquery

      Double Precision, allocatable :: a(:,:), b(:,:), c(:,:)
      Double Precision :: alpha, beta
      LOGICAL            NOTRANA, NOTRANB

! External BLAS/BLIS names are supplied as object-like macros (so gfortran's
! traditional-cpp mode handles them; plain substitution, no ## pasting).
#define LSAME_SYM   lsame
#define DGEMM_SYM   dgemm
#define BLI_NT_SYM  bli_thread_get_num_threads

      LOGICAL            LSAME_SYM
      EXTERNAL           LSAME_SYM

      Integer   BLI_NT_SYM
      External  BLI_NT_SYM
      External  DGEMM_SYM

      transa = 'n'
      transb = 't'
      m = 240
      n = 240
      k = 30
      alpha = -1.0D0
      beta = 1.0D0
      ntest = 1

      NOTRANA = LSAME_SYM( TRANSA, 'N' )
      NOTRANB = LSAME_SYM( TRANSB, 'N' )

      if (NOTRANA) then
         lda = max(1,m)
         Allocate (a(lda,k))
         a(:,:) = 1.0D0
      else
         lda = max(1,k)
         Allocate (a(lda,m))
         a(:,:) = 1.0D0
      endif

      if (NOTRANB) then
         ldb = max(1,k)
         Allocate (b(ldb,n))
         b(:,:) = 1.0D0
      else
         ldb = max(1,n)
         Allocate (b(ldb,k))
         b(:,:) = 1.0D0
      endif

      ldc = m
      Allocate (c(ldc,n))
      c(:,:) = 1.0D0

      print*,''
      print*,'Testing original BLAS symbols'
      nt = 1
!$    nt = omp_get_max_threads()
      print*,'Calling dgemm, omp_get_max_threads = ', nt
      ntquery = BLI_NT_SYM()
      print*,'  before ntquery = ', ntquery
      CALL DGEMM_SYM(transa, transb, m, n, k, alpha, a, lda, b, ldb, beta, c, ldc)
      ntquery = BLI_NT_SYM()
      print*,'  after  ntquery = ', ntquery

      print*,''
      print*,'Test completed successfully!'

      END PROGRAM mix_libraries
