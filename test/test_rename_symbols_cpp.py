# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.

import importlib.util
import os
import re
import tempfile
import unittest


_THIS_DIR = os.path.dirname(__file__)
_RENAME_SCRIPT = os.path.abspath(os.path.join(_THIS_DIR, '..', 'symbol_rename', 'rename_engine_linux.py'))

spec = importlib.util.spec_from_file_location('rename_engine_linux', _RENAME_SCRIPT)
rename_symbols = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rename_symbols)


class TestCppMangledRenaming(unittest.TestCase):
    def test_regular_nested_name(self):
        sym = '_ZN3foo3barEv'
        self.assertEqual(
            rename_symbols.rename_mangled_symbol_with_namespace(sym, 'AOCL_'),
            '_ZN8AOCL_foo3barEv'
        )

    def test_regular_nested_name_without_trailing_underscore_prefix(self):
        sym = '_ZN3foo3barEv'
        self.assertEqual(
            rename_symbols.rename_mangled_symbol_with_namespace(sym, 'aocl'),
            '_ZN7aoclfoo3barEv'
        )

    def test_const_qualified_nested_name(self):
        sym = '_ZNK3foo3barEv'
        # Validate broad "any user prefix" behavior:
        # - preserve caller case
        # - strip non [A-Za-z0-9_]
        # - preserve trailing underscore intent (no forced underscore)
        prefixes = [
            'AOCL_', 'aocl', 'MYLIB52_', 'myLib', 'aocl-52',
            '  my-pre.fix  ', '___', '', '%%%'
        ]

        for prefix in prefixes:
            token = re.sub(r'[^A-Za-z0-9_]', '', prefix)
            with self.subTest(prefix=prefix):
                if not token:
                    # Empty normalized token -> no rewrite.
                    self.assertEqual(
                        rename_symbols.rename_mangled_symbol_with_namespace(sym, prefix),
                        sym
                    )
                    continue

                replaced = f'{token}foo'
                expected = f'_ZNK{len(replaced)}{replaced}3barEv'
                self.assertEqual(
                    rename_symbols.rename_mangled_symbol_with_namespace(sym, prefix),
                    expected
                )

    def test_local_name_nested_owner(self):
        sym = '_ZZN3foo3barEvE5local'
        self.assertEqual(
            rename_symbols.rename_mangled_symbol_with_namespace(sym, 'AOCL_'),
            '_ZZN8AOCL_foo3barEvE5local'
        )

    def test_vtable_typeinfo_and_typeinfo_name(self):
        self.assertEqual(
            rename_symbols.rename_mangled_symbol_with_namespace('_ZTVN3foo3BarE', 'AOCL_'),
            '_ZTVN8AOCL_foo3BarE'
        )
        self.assertEqual(
            rename_symbols.rename_mangled_symbol_with_namespace('_ZTIN3foo3BarE', 'AOCL_'),
            '_ZTIN8AOCL_foo3BarE'
        )
        self.assertEqual(
            rename_symbols.rename_mangled_symbol_with_namespace('_ZTSN3foo3BarE', 'AOCL_'),
            '_ZTSN8AOCL_foo3BarE'
        )
        self.assertEqual(
            rename_symbols.rename_mangled_symbol_with_namespace('_ZTTN3foo3BarE', 'AOCL_'),
            '_ZTTN8AOCL_foo3BarE'
        )

    def test_thunk_and_guard_patterns(self):
        self.assertEqual(
            rename_symbols.rename_mangled_symbol_with_namespace('_ZThn16_N3foo3barEv', 'AOCL_'),
            '_ZThn16_N8AOCL_foo3barEv'
        )
        self.assertEqual(
            rename_symbols.rename_mangled_symbol_with_namespace('_ZTv0_n24_N3foo3barEv', 'AOCL_'),
            '_ZTv0_n24_N8AOCL_foo3barEv'
        )
        self.assertEqual(
            rename_symbols.rename_mangled_symbol_with_namespace('_ZGVZN3foo3barEvE1x', 'AOCL_'),
            '_ZGVZN8AOCL_foo3barEvE1x'
        )

    def test_replace_not_wrap_preserves_substitutions(self):
        # Regression for same-depth substitution stability (NS0_ stays valid).
        sym = '_ZN4alcp5utils5CpuId12cpuHasAvx512ENS0_11Avx512FlagsE'
        self.assertEqual(
            rename_symbols.rename_mangled_symbol_with_namespace(sym, 'AOCL_52_'),
            '_ZN12AOCL_52_alcp5utils5CpuId12cpuHasAvx512ENS0_11Avx512FlagsE'
        )

    def test_std_symbols_are_not_renamed(self):
        std_syms = [
            '_ZSt4cout',
            '_ZNSt6vectorIiSaIiEE5beginEv',
            '_ZTSSt23_Sp_counted_ptr_inplaceIN4alcp6digest4Sha2IL15_alc_digest_len256EEESaIvELN9__gnu_cxx12_Lock_policyE2EE',
            '_ZTVNSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEE',
        ]
        for sym in std_syms:
            with self.subTest(sym=sym):
                self.assertTrue(rename_symbols.is_std_mangled_symbol(sym))
                self.assertEqual(rename_symbols.rename_mangled_symbol_with_namespace(sym, 'AOCL_'), sym)
                self.assertFalse(rename_symbols.should_rename_symbol(sym, 'AOCL_'))

    def test_c_symbol_prefixing_unchanged(self):
        self.assertEqual(rename_symbols.get_intelligent_prefix('cblas_dgemm', 'AOCL_'), 'aocl_')
        self.assertEqual(rename_symbols.get_intelligent_prefix('DGEMM_', 'AOCL_'), 'AOCL_')

    def test_generate_mapping_skips_noop_mangled(self):
        symbols = [
            '_ZTSFvE',            # not nested -> no-op for C++ renaming
            '_ZN3foo3barEv',      # nested -> should rename
            '_ZSt4cout',          # std -> should skip
            'dgemm_',             # C symbol -> should rename
        ]

        with tempfile.NamedTemporaryFile(mode='w+', delete=False) as tf:
            map_path = tf.name

        try:
            mapping = rename_symbols.generate_mapping(symbols, 'AOCL_', map_path)
            self.assertNotIn('_ZTSFvE', mapping)
            self.assertNotIn('_ZSt4cout', mapping)
            self.assertEqual(mapping['_ZN3foo3barEv'], '_ZN8AOCL_foo3barEv')
            self.assertEqual(mapping['dgemm_'], 'aocl_dgemm_')
        finally:
            if os.path.exists(map_path):
                os.remove(map_path)

    def test_generate_mapping_mangled_prefix_without_trailing_underscore(self):
        symbols = ['_ZN3foo3barEv']

        with tempfile.NamedTemporaryFile(mode='w+', delete=False) as tf:
            map_path = tf.name

        try:
            mapping = rename_symbols.generate_mapping(symbols, 'aocl', map_path)
            self.assertEqual(mapping['_ZN3foo3barEv'], '_ZN7aoclfoo3barEv')
        finally:
            if os.path.exists(map_path):
                os.remove(map_path)

    def test_namespace_rename_map_and_header_rewrite(self):
        symbol_mapping = {
            '_ZN4alcp5utils5CpuId12cpuHasAvx512ENS0_11Avx512FlagsE':
                '_ZN12AOCL_52_alcp5utils5CpuId12cpuHasAvx512ENS0_11Avx512FlagsE'
        }

        ns_map = rename_symbols.build_namespace_rename_map(symbol_mapping)
        self.assertEqual(ns_map, {'alcp': 'AOCL_52_alcp'})

        header_in = (
            'namespace alcp::utils {\n'
            'using namespace alcp;\n'
            'alcp::utils::CpuId x;\n'
            '} // namespace alcp::utils\n'
        )
        header_out = rename_symbols.apply_namespace_renames(header_in, ns_map)

        self.assertIn('namespace AOCL_52_alcp::utils {', header_out)
        self.assertIn('using namespace AOCL_52_alcp;', header_out)
        self.assertIn('AOCL_52_alcp::utils::CpuId x;', header_out)
        self.assertIn('} // namespace AOCL_52_alcp::utils', header_out)

    def test_api_family_prefix_map_and_header_rewrite(self):
        symbol_mapping = {
            'cblas_sgemm': 'aocl_52_cblas_sgemm',
            'lapacke_dgesv': 'aocl_52_lapacke_dgesv',
            'da_options_set_int': 'mylib_52da_options_set_int',
        }

        api_map = rename_symbols.build_api_prefix_rename_map(symbol_mapping)
        self.assertEqual(api_map.get('cblas_'), 'aocl_52_cblas_')
        self.assertEqual(api_map.get('lapacke_'), 'aocl_52_lapacke_')
        self.assertEqual(api_map.get('da_'), 'mylib_52da_')

        header_in = (
            'inline void cblas_gemm();\n'
            'inline void lapacke_foo();\n'
            'typedef da_status da_resfun_t_d(da_int n, const double *x, double *r, void *udata);\n'
            'da_status da_datastore_options_get_string(da_datastore store, const char *option, char *value, da_int lvalue);\n'
            'void user() { cblas_gemm(); lapacke_foo(); da_datastore_options_get_string(store, option, value, lvalue); }\n'
        )
        header_out = rename_symbols.apply_api_prefix_renames(header_in, api_map)

        self.assertIn('inline void aocl_52_cblas_gemm();', header_out)
        self.assertIn('inline void aocl_52_lapacke_foo();', header_out)
        self.assertIn('da_status mylib_52da_datastore_options_get_string(', header_out)
        self.assertIn('aocl_52_cblas_gemm();', header_out)
        self.assertIn('aocl_52_lapacke_foo();', header_out)
        self.assertIn('mylib_52da_datastore_options_get_string(store, option, value, lvalue);', header_out)
        # Ensure DA type names are not accidentally rewritten.
        self.assertIn('da_status', header_out)
        self.assertIn('da_datastore', header_out)
        self.assertIn('da_int', header_out)
        self.assertIn('typedef da_status da_resfun_t_d(', header_out)

    def test_api_family_rewrite_preserves_spacing_before_paren(self):
        symbol_mapping = {
            'cblas_sgemm': 'aocl_52_cblas_sgemm',
        }

        api_map = rename_symbols.build_api_prefix_rename_map(symbol_mapping)
        header_in = 'inline void cblas_gemm   (int m, int n);\n'
        header_out = rename_symbols.apply_api_prefix_renames(header_in, api_map)

        self.assertIn('aocl_52_cblas_gemm   (int m, int n);', header_out)

    def test_cpp_wrapper_namespace_and_identifier_fallback_rewrite(self):
        symbol_mapping = {
            'cblas_sgemm': 'mylib_52_cblas_sgemm',
        }

        api_map = rename_symbols.build_api_prefix_rename_map(symbol_mapping)
        self.assertEqual(api_map.get('cblas_'), 'mylib_52_cblas_')
        self.assertEqual(rename_symbols.infer_wrapper_prefix(api_map), 'mylib_52_')
        self.assertEqual(
            rename_symbols.build_cpp_namespace_fallback_map(api_map),
            {'blis': 'mylib_52_blis', 'libflame': 'mylib_52_libflame'}
        )

        with tempfile.TemporaryDirectory() as td:
            blis_header = os.path.join(td, 'blis.hh')
            with open(blis_header, 'w', encoding='utf-8') as f:
                f.write(
                    'namespace blis {\n'
                    'template<typename T>\n'
                    'inline void rotg(T *a, T *b, T *c, T *s) { mylib_52_cblas_rotg(a, b, c, s); }\n'
                    'inline void use_it(float *a, float *b, float *c, float *s) { rotg(a, b, c, s); }\n'
                    '} // namespace blis\n'
                )

            changed = rename_symbols.rename_prototypes_in_header_fast(
                blis_header,
                symbol_mapping,
                namespace_renames={},
                api_prefix_renames=api_map,
            )
            self.assertTrue(changed)

            with open(blis_header, 'r', encoding='utf-8') as f:
                updated = f.read()

            self.assertIn('namespace mylib_52_blis {', updated)
            self.assertIn('inline void mylib_52_rotg(', updated)
            self.assertIn('mylib_52_rotg(a, b, c, s);', updated)
            self.assertIn('mylib_52_cblas_rotg(a, b, c, s);', updated)
            self.assertIn('// namespace mylib_52_blis', updated)

            libflame_header = os.path.join(td, 'libflame_interface.hh')
            with open(libflame_header, 'w', encoding='utf-8') as f:
                f.write(
                    'namespace libflame {\n'
                    'inline void potrf(char* uplo) { }\n'
                    'inline void call_it(char* uplo) { potrf(uplo); }\n'
                    '} // namespace libflame\n'
                )

            changed = rename_symbols.rename_prototypes_in_header_fast(
                libflame_header,
                symbol_mapping,
                namespace_renames={},
                api_prefix_renames=api_map,
            )
            self.assertTrue(changed)

            with open(libflame_header, 'r', encoding='utf-8') as f:
                updated = f.read()

            self.assertIn('namespace mylib_52_libflame {', updated)
            self.assertIn('inline void mylib_52_potrf(', updated)
            self.assertIn('mylib_52_potrf(uplo);', updated)
            self.assertIn('// namespace mylib_52_libflame', updated)

    def test_cpp_namespace_fallback_not_derived_from_da_only_mapping(self):
        symbol_mapping = {
            'da_options_set_int': 'mylib_52da_options_set_int',
        }

        api_map = rename_symbols.build_api_prefix_rename_map(symbol_mapping)
        self.assertEqual(api_map.get('da_'), 'mylib_52da_')
        self.assertEqual(rename_symbols.build_cpp_namespace_fallback_map(api_map), {})


if __name__ == '__main__':
    unittest.main()
