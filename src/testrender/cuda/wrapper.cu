// Copyright Contributors to the Open Shading Language project.
// SPDX-License-Identifier: BSD-3-Clause
// https://github.com/AcademySoftwareFoundation/OpenShadingLanguage

#include <OSL/hashes.h>
#include <optix.h>

#include <cuda_runtime.h>
#include <optix.h>

#include <OSL/oslclosure.h>

#include "rend_lib.h"
#include "util.h"

#include "../render_params.h"


extern "C" {
__device__ __constant__ RenderParams render_params;
}


extern "C" __global__ void
__anyhit__any_hit_shadow()
{
    optixTerminateRay();
}



static __device__ void
globals_from_hit(ShaderGlobals& sg)
{
    // Setup the ShaderGlobals
    const int primID           = optixGetPrimitiveIndex();
    const float3 ray_direction = optixGetWorldRayDirection();
    const float3 ray_origin    = optixGetWorldRayOrigin();
    const float t_hit          = optixGetRayTmax();
    const int shader_id        = reinterpret_cast<int*>(
        render_params.shader_ids)[primID];

    const OSL::Vec3* verts = reinterpret_cast<const OSL::Vec3*>(
        render_params.verts);
    const OSL::Vec3* normals = reinterpret_cast<const OSL::Vec3*>(
        render_params.normals);
    const OSL::Vec2* uvs = reinterpret_cast<const OSL::Vec2*>(
        render_params.uvs);
    const int3* triangles = reinterpret_cast<const int3*>(
        render_params.triangles);
    const int3* n_triangles = reinterpret_cast<const int3*>(
        render_params.normal_indices);
    const int3* uv_triangles = reinterpret_cast<const int3*>(
        render_params.uv_indices);
    const int* mesh_ids = reinterpret_cast<const int*>(
        render_params.mesh_ids);
    const float* surfacearea = reinterpret_cast<const float*>(
        render_params.surfacearea);

    // Calculate UV and its derivatives
    const float2 barycentrics = optixGetTriangleBarycentrics();
    const float b1            = barycentrics.x;
    const float b2            = barycentrics.y;
    const float b0            = 1.0f - (b1 + b2);

    const OSL::Vec2 ta = uvs[uv_triangles[primID].x];
    const OSL::Vec2 tb = uvs[uv_triangles[primID].y];
    const OSL::Vec2 tc = uvs[uv_triangles[primID].z];
    const OSL::Vec2 uv = b0 * ta + b1 * tb + b2 * tc;
    const float u      = uv.x;
    const float v      = uv.y;

    const OSL::Vec3 va = verts[triangles[primID].x];
    const OSL::Vec3 vb = verts[triangles[primID].y];
    const OSL::Vec3 vc = verts[triangles[primID].z];

    const OSL::Vec2 dt02 = ta - tc, dt12 = tb - tc;
    const OSL::Vec3 dp02 = va - vc, dp12 = vb - vc;

    OSL::Vec3 dPdu, dPdv;
    const float det = dt02.x * dt12.y - dt02.y * dt12.x;
    if (det != 0.0f) {
        float invdet = 1.0f / det;
        dPdu         = (dt12.y * dp02 - dt02.y * dp12) * invdet;
        dPdv         = (-dt12.x * dp02 + dt02.x * dp12) * invdet;
    }

    // Calculate the normals
    const OSL::Vec3 Ng = (va - vb).cross(va - vc).normalize();
    OSL::Vec3 N;
    if (n_triangles[primID].x < 0.0f) {
        N = Ng;
    } else {
        const OSL::Vec3 na = normals[n_triangles[primID].x];
        const OSL::Vec3 nb = normals[n_triangles[primID].y];
        const OSL::Vec3 nc = normals[n_triangles[primID].z];
        N                  = ((1 - u - v) * na + u * nb + v * nc).normalize();
    }

    sg.I  = ray_direction;
    sg.N  = normalize(optixTransformNormalFromObjectToWorldSpace(*(float3*)(&N)));
    sg.Ng = normalize(optixTransformNormalFromObjectToWorldSpace(*(float3*)(&Ng)));
    sg.P  = ray_origin + t_hit * ray_direction;
    sg.dPdu        = *(float3*)(&dPdu);
    sg.dPdv        = *(float3*)(&dPdv);
    sg.u           = u;
    sg.v           = v;
    sg.Ci          = NULL;
    sg.surfacearea = surfacearea[mesh_ids[primID]];
    sg.backfacing  = dot(sg.N, sg.I) > 0.0f;
    sg.shaderID    = shader_id;

    if (sg.backfacing) {
        sg.N  = -sg.N;
        sg.Ng = -sg.Ng;
    }

    // NB: These variables are not used in the current iteration of the sample
    sg.raytype        = CAMERA;
    sg.flipHandedness = 0;
}



static __device__ float3
process_closure(const OSL::ClosureColor* closure_tree)
{
    OSL::Color3 result = OSL::Color3(0.0f);

    if (!closure_tree) {
        return make_float3(result.x, result.y, result.z);
    }

    // The depth of the closure tree must not exceed the stack size.
    // A stack size of 8 is probably quite generous for relatively
    // balanced trees.
    const int STACK_SIZE = 8;

    // Non-recursive traversal stack
    int stack_idx = 0;
    const OSL::ClosureColor* ptr_stack[STACK_SIZE];
    OSL::Color3 weight_stack[STACK_SIZE];

    // Shading accumulator
    OSL::Color3 weight = OSL::Color3(1.0f);

    const void* cur = closure_tree;
    while (cur) {
        switch (((OSL::ClosureColor*)cur)->id) {
        case OSL::ClosureColor::ADD: {
            ptr_stack[stack_idx]      = ((OSL::ClosureAdd*)cur)->closureB;
            weight_stack[stack_idx++] = weight;
            cur                       = ((OSL::ClosureAdd*)cur)->closureA;
            break;
        }

        case OSL::ClosureColor::MUL: {
            weight *= ((OSL::ClosureMul*)cur)->weight;
            cur = ((OSL::ClosureMul*)cur)->closure;
            break;
        }

        case EMISSION_ID: {
            cur = NULL;
            break;
        }

        case DIFFUSE_ID:
        case OREN_NAYAR_ID:
        case PHONG_ID:
        case WARD_ID:
        case REFLECTION_ID:
        case REFRACTION_ID:
        case FRESNEL_REFLECTION_ID: {
            result += ((OSL::ClosureComponent*)cur)->w * weight;
            cur = NULL;
            break;
        }

        case MICROFACET_ID: {
            const char* mem = (const char*)((OSL::ClosureComponent*)cur)->data();
            OSL::ustringhash dist_uh = *(OSL::ustringhash*)&mem[0];

            if (dist_uh == OSL::Hashes::default_)
                return make_float3(0.0f, 1.0f, 1.0f);
            else
                return make_float3(1.0f, 0.0f, 1.0f);

            break;
        }

        default: cur = NULL; break;
        }

        if (cur == NULL && stack_idx > 0) {
            cur    = ptr_stack[--stack_idx];
            weight = weight_stack[stack_idx];
        }
    }

    return make_float3(result.x, result.y, result.z);
}



extern "C" __global__ void
__closesthit__closest_hit_osl()
{
    // TODO: Fixed-sized allocations can easily be exceeded by arbitrary shader
    //       networks, so there should be (at least) some mechanism to issue a
    //       warning or error if the closure or param storage can possibly be
    //       exceeded.
    alignas(8) char closure_pool[256];

    ShaderGlobals sg;
    globals_from_hit(sg);

    // Pack the "closure pool" into one of the ShaderGlobals pointers
    *(int*)&closure_pool[0] = 0;
    sg.renderstate          = &closure_pool[0];

    // Create some run-time options structs. The OSL shader fills in the structs
    // as it executes, based on the options specified in the shader source.
    NoiseOptCUDA noiseopt;
    TextureOptCUDA textureopt;
    TraceOptCUDA traceopt;

    // Pack the pointers to the options structs in a faux "context",
    // which is a rough stand-in for the host ShadingContext.
    ShadingContextCUDA shading_context = { &noiseopt, &textureopt, &traceopt };

    sg.context = &shading_context;

    // Run the OSL callable
    void* interactive_ptr = reinterpret_cast<void**>(
        render_params.interactive_params)[sg.shaderID];
    const unsigned int shaderIdx = sg.shaderID + 0u;
    optixDirectCall<void, ShaderGlobals*, void*, void*, void*, int, void*>(
        shaderIdx, &sg /*shaderglobals_ptr*/, nullptr /*groupdata_ptr*/,
        nullptr /*userdata_base_ptr*/, nullptr /*output_base_ptr*/,
        0 /*shadeindex - unused*/, interactive_ptr /*interactive_params_ptr*/);

    float3 result      = process_closure((OSL::ClosureColor*)sg.Ci);
    uint3 launch_dims  = optixGetLaunchDimensions();
    uint3 launch_index = optixGetLaunchIndex();

    float3* output_buffer = reinterpret_cast<float3*>(
        render_params.output_buffer);
    int pixel            = launch_index.y * launch_dims.x + launch_index.x;
    output_buffer[pixel] = make_float3(result.x, result.y, result.z);
}
