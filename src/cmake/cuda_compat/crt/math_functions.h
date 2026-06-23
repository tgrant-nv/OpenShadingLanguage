// Copyright Contributors to the Open Shading Language project.
// SPDX-License-Identifier: BSD-3-Clause

/*
 * Compatibility overlay for CUDA 13.x headers used by Clang's CUDA wrapper.
 *
 * See math_functions.hpp in this directory for the matching definition-side
 * workaround. This header keeps CUDA declarations visible, then clears the
 * rsqrt exception-specifier macro before the implementation header is parsed.
 */
#include_next <crt/math_functions.h>

#if defined(__clang__) && defined(__CUDA__)
#    undef _NV_RSQRT_SPECIFIER
#    define _NV_RSQRT_SPECIFIER
#endif
