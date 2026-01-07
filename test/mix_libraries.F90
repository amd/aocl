! Copyright (C) 2025, Advanced Micro Devices, Inc. All rights reserved.

      PROGRAM mix_libraries

!$      Use omp_lib
      Implicit None

      Character :: transa, transb
      Integer :: M, N, K, ntest, i, j, lda, ldb, ldc, np, me, nt, ntquery

      Double Precision, allocatable :: a(:,:), b(:,:), c(:,:)
      Double Precision :: alpha, beta
      LOGICAL            NOTRANA, NOTRANB

      LOGICAL            LSAME
      EXTERNAL           LSAME

      Integer   bli_thread_get_num_threads
      External  bli_thread_get_num_threads
      External  dgemm

#ifdef USE_RENAMED_SYMBOLS
#ifndef RENAMED_PREFIX
#error "USE_RENAMED_SYMBOLS is defined but RENAMED_PREFIX is not set!"
#endif

      Integer   renamed_bli_thread_get_num_threads
      External  renamed_bli_thread_get_num_threads
      External  renamed_dgemm
#endif

      transa = 'n'
      transb = 't'
      m = 240
      n = 240
      k = 30
      alpha = -1.0D0
      beta = 1.0D0
      ntest = 1

      NOTRANA = LSAME( TRANSA, 'N' )
      NOTRANB = LSAME( TRANSB, 'N' )

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
      ntquery = bli_thread_get_num_threads()
      print*,'  before ntquery = ', ntquery
      CALL dgemm(transa, transb, m, n, k, alpha, a, lda, b, ldb, beta, c, ldc)
      ntquery = bli_thread_get_num_threads()
      print*,'  after  ntquery = ', ntquery

      print*,''
      print*,'Testing renamed BLAS symbols'
      nt = 1
!$    nt = omp_get_max_threads()

#ifdef USE_RENAMED_SYMBOLS
      print*,'Calling renamed dgemm, omp_get_max_threads = ', nt
      ntquery = renamed_bli_thread_get_num_threads()
      print*,'  before ntquery = ', ntquery
      CALL renamed_dgemm(transa, transb, m, n, k, alpha, a, lda, b, ldb, beta, c, ldc)
      ntquery = renamed_bli_thread_get_num_threads()
      print*,'  after  ntquery = ', ntquery
#else
      print*,'Skipping (USE_RENAMED_SYMBOLS not defined)'
#endif

      print*,''
      print*,'Test completed successfully!'

      END PROGRAM mix_libraries
