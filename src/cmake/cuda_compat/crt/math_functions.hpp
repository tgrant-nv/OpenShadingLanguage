// Copyright Contributors to the Open Shading Language project.
// SPDX-License-Identifier: BSD-3-Clause

/*
 * Compatibility overlay for CUDA 13.x headers used by Clang's CUDA wrapper.
 *
 * CUDA 13.3 may add noexcept(true) to rsqrt definitions on newer glibc
 * versions. Clang 20's CUDA wrapper includes this header in a device-only
 * context where that exception specification is rejected, so hide the glibc
 * probe from the real CUDA header when compiling through Clang.
 */
#if defined(__clang__) && defined(__CUDA__)
#    define _NV_GLIBC_VERSION_GE_2_42_HIDDEN_BY_OSL
#    pragma push_macro("_NV_GLIBC_VERSION_GE_2_42")
#    pragma push_macro("_NV_RSQRT_SPECIFIER")
#    undef _NV_GLIBC_VERSION_GE_2_42
#    undef _NV_RSQRT_SPECIFIER
#    define _NV_RSQRT_SPECIFIER
#endif

#include_next <crt/math_functions.hpp>

#if defined(_NV_GLIBC_VERSION_GE_2_42_HIDDEN_BY_OSL)
#    pragma pop_macro("_NV_RSQRT_SPECIFIER")
#    pragma pop_macro("_NV_GLIBC_VERSION_GE_2_42")
#    undef _NV_GLIBC_VERSION_GE_2_42_HIDDEN_BY_OSL
#endif
