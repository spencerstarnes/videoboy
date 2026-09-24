//
//  ISFMetalPrelude.swift — the GLSL vocabulary, written in Metal.
//
//  Purpose : Metal Shading Language is C++, and C++ is close enough to GLSL that an
//            ISF shader body compiles in Metal almost unchanged — once the names GLSL
//            has and Metal does not (`vec2`, `mod`, `texture2D`, `IMG_NORM_PIXEL` …)
//            exist. This file is those names. Nothing here parses anything.
//  Inputs  : none; two constant strings.
//  Outputs : `fileScope` goes at the top of the generated source; `members` goes
//            inside the generated `ISFShader` struct, so the helpers can see the
//            sampler and the pixel coordinate the way GLSL built-ins can.
//  Connects: ISFMetalGenerator, the only user.
//  Extend  : when real-world files fail on a GLSL built-in Metal lacks, add it here
//            with GLSL's exact semantics, and add a fixture test that uses it.
//
//  COORDINATES. ISF inherits OpenGL's convention: normalised coordinates run from
//  (0,0) at the BOTTOM-left. Videoboy's textures are stored top row first. Every
//  sampling helper below therefore flips y on the way in, so a shader written for
//  VDMX moves things the same direction here as it does there, and sampling
//  `isf_FragNormCoord` returns exactly the pixel being drawn.
//

import Foundation

enum ISFMetalPrelude {

    /// Type names and keyword shims. File scope, before the struct.
    static let fileScope = """
    #include <metal_stdlib>
    using namespace metal;

    // GLSL type names.
    typedef float2 vec2;
    typedef float3 vec3;
    typedef float4 vec4;
    typedef int2 ivec2;
    typedef int3 ivec3;
    typedef int4 ivec4;
    typedef uint2 uvec2;
    typedef uint3 uvec3;
    typedef uint4 uvec4;
    typedef bool2 bvec2;
    typedef bool3 bvec3;
    typedef bool4 bvec4;
    typedef float2x2 mat2;
    typedef float3x3 mat3;
    typedef float4x4 mat4;

    // GLSL has compound assignment with matrices (`m *= r`, `v *= m`); Metal has only
    // the binary operators. Same meaning as GLSL: m = m * r, v = v * m.
    inline thread float2x2& operator*=(thread float2x2& a, float2x2 b) { a = a * b; return a; }
    inline thread float3x3& operator*=(thread float3x3& a, float3x3 b) { a = a * b; return a; }
    inline thread float4x4& operator*=(thread float4x4& a, float4x4 b) { a = a * b; return a; }
    inline thread float2& operator*=(thread float2& v, float2x2 m) { v = v * m; return v; }
    inline thread float3& operator*=(thread float3& v, float3x3 m) { v = v * m; return v; }
    inline thread float4& operator*=(thread float4& v, float4x4 m) { v = v * m; return v; }

    // ISF files that support both GLSL dialects branch on `__VERSION__`. This host
    // speaks the GLSL 1.2 side (varying, gl_FragColor, texture2D), so say so.
    #ifdef __VERSION__
    #undef __VERSION__
    #endif
    #define __VERSION__ 120
    // Sampler types as parameter types: `vec3 dof(sampler2D tex, …)`. In Metal the
    // texture is the thing passed; sampling goes through the struct's sampler.
    typedef texture2d<float> sampler2D;
    typedef texture2d<float> sampler2DRect;
    typedef texturecube<float> samplerCube;
    // A swizzle passed to an out/inout parameter (`pR(p.xz, a)`). Metal cannot bind a
    // reference to a swizzle; GLSL copies in and back out. This holds the copy, hands
    // the function a reference to it, and writes it back when the call's expression
    // ends — the same order GLSL gives.
    template <typename V, int N> struct ISFSwizzleRef {
        thread V* base;
        int index[4];
        vec<float, N> value;
        ISFSwizzleRef(thread V& v, int a, int b, int c, int d) : base(&v) {
            index[0] = a; index[1] = b; index[2] = c; index[3] = d;
            for (int i = 0; i < N; i++) value[i] = v[index[i]];
        }
        ~ISFSwizzleRef() { for (int i = 0; i < N; i++) (*base)[index[i]] = value[i]; }
        operator thread vec<float, N>&() { return value; }
    };
    template <int N, typename V>
    ISFSwizzleRef<V, N> isf_swizzle(thread V& v, int a, int b, int c = 0, int d = 0) {
        return ISFSwizzleRef<V, N>(v, a, b, c, d);
    }
    // The same for one component passed to an inout float: `pMod(p.z, 8.0)`.
    template <typename V> struct ISFComponentRef {
        thread V* base;
        int index;
        float value;
        ISFComponentRef(thread V& v, int i) : base(&v), index(i), value(v[i]) {}
        ~ISFComponentRef() { (*base)[index] = value; }
        operator thread float&() { return value; }
    };
    template <typename V> ISFComponentRef<V> isf_component(thread V& v, int i) {
        return ISFComponentRef<V>(v, i);
    }
    // GLSL's geometric functions take plain floats too, and Apple's GLSL accepts a
    // float where a vector is expected (`distance(center, 0.5)`). At FILE scope, so a
    // shader that defines its own `distance` or names an input `length` simply hides
    // these, as its own names would hide GLSL's; Metal's vector forms stay visible
    // through `using namespace metal`.
    inline float distance(float a, float b) { return metal::abs(a - b); }
    inline float distance(float2 a, float b) { return metal::distance(a, float2(b)); }
    inline float distance(float3 a, float b) { return metal::distance(a, float3(b)); }
    inline float distance(float4 a, float b) { return metal::distance(a, float4(b)); }
    inline float distance(float a, float2 b) { return metal::distance(float2(a), b); }
    inline float distance(float a, float3 b) { return metal::distance(float3(a), b); }
    inline float distance(float a, float4 b) { return metal::distance(float4(a), b); }
    inline float length(float x) { return metal::abs(x); }
    inline float dot(float a, float b) { return a * b; }
    inline float normalize(float x) { return metal::sign(x); }
    // Matrix constructors with GLSL's mixed arguments — `mat2(a.y, -a.x, a)` — which
    // Metal's matrix types do not take. The converter sends every `matN(` here: the
    // arguments are flattened in order into columns, one scalar makes a diagonal, and
    // a matrix argument is resized, all as GLSL defines.
    inline void isf_push(thread float* c, thread int& i, float x) { if (i < 16) c[i++] = x; }
    inline void isf_push(thread float* c, thread int& i, int x) { if (i < 16) c[i++] = float(x); }
    inline void isf_push(thread float* c, thread int& i, bool x) { if (i < 16) c[i++] = x ? 1.0 : 0.0; }
    inline void isf_push(thread float* c, thread int& i, float2 x) { isf_push(c, i, x.x); isf_push(c, i, x.y); }
    inline void isf_push(thread float* c, thread int& i, float3 x) { isf_push(c, i, x.xy); isf_push(c, i, x.z); }
    inline void isf_push(thread float* c, thread int& i, float4 x) { isf_push(c, i, x.xy); isf_push(c, i, x.zw); }
    template <typename... A> inline float2x2 isf_mat2(A... a) {
        float c[16] = {0}; int i = 0; int expand[] = { 0, (isf_push(c, i, a), 0)... }; (void)expand;
        return float2x2(float2(c[0], c[1]), float2(c[2], c[3]));
    }
    template <typename... A> inline float3x3 isf_mat3(A... a) {
        float c[16] = {0}; int i = 0; int expand[] = { 0, (isf_push(c, i, a), 0)... }; (void)expand;
        return float3x3(float3(c[0], c[1], c[2]), float3(c[3], c[4], c[5]), float3(c[6], c[7], c[8]));
    }
    template <typename... A> inline float4x4 isf_mat4(A... a) {
        float c[16] = {0}; int i = 0; int expand[] = { 0, (isf_push(c, i, a), 0)... }; (void)expand;
        return float4x4(float4(c[0], c[1], c[2], c[3]), float4(c[4], c[5], c[6], c[7]),
                        float4(c[8], c[9], c[10], c[11]), float4(c[12], c[13], c[14], c[15]));
    }
    inline float2x2 isf_mat2(float d) { return float2x2(float2(d, 0.0), float2(0.0, d)); }
    inline float2x2 isf_mat2(int d) { return isf_mat2(float(d)); }
    inline float2x2 isf_mat2(float2x2 m) { return m; }
    inline float2x2 isf_mat2(float3x3 m) { return float2x2(m[0].xy, m[1].xy); }
    inline float2x2 isf_mat2(float4x4 m) { return float2x2(m[0].xy, m[1].xy); }
    inline float3x3 isf_mat3(float d) { return float3x3(float3(d, 0, 0), float3(0, d, 0), float3(0, 0, d)); }
    inline float3x3 isf_mat3(int d) { return isf_mat3(float(d)); }
    inline float3x3 isf_mat3(float3x3 m) { return m; }
    inline float3x3 isf_mat3(float4x4 m) { return float3x3(m[0].xyz, m[1].xyz, m[2].xyz); }
    inline float3x3 isf_mat3(float2x2 m) { return float3x3(float3(m[0], 0), float3(m[1], 0), float3(0, 0, 1)); }
    inline float4x4 isf_mat4(float d) { return float4x4(float4(d,0,0,0), float4(0,d,0,0), float4(0,0,d,0), float4(0,0,0,d)); }
    inline float4x4 isf_mat4(int d) { return isf_mat4(float(d)); }
    inline float4x4 isf_mat4(float4x4 m) { return m; }
    inline float4x4 isf_mat4(float3x3 m) { return float4x4(float4(m[0], 0), float4(m[1], 0), float4(m[2], 0), float4(0, 0, 0, 1)); }
    // Precision qualifiers mean nothing on Apple GPUs.
    #define lowp
    #define mediump
    #define highp

    // Keywords and built-ins that only differ in spelling.
    #define discard discard_fragment()
    #define dFdx dfdx
    #define dFdy dfdy
    """

    /// Helper functions. Inside the struct, so they see `isf_sampler` and the pixel
    /// coordinate as members, exactly as GLSL built-ins see global state.
    ///
    /// Overloads are spelled out per type rather than templated: templates made
    /// `mod(float, 1.0)` ambiguous in the feasibility test.
    /// The same helpers for the vertex stage, where there are no derivatives: every
    /// sample takes level 0 explicitly, which is what GLSL's texture2D does in a
    /// vertex shader.
    static var vertexMembers: String {
        members.replacingOccurrences(
            of: "image.sample(isf_sampler, float2(normalised.x, 1.0 - normalised.y))",
            with: "image.sample(isf_sampler, float2(normalised.x, 1.0 - normalised.y), level(0.0))")
    }

    static let members = """
        // ---- GLSL built-ins Metal spells differently or lacks -------------------

        // GLSL mod is x - y*floor(x/y): the result takes the sign of y. Metal's fmod
        // takes the sign of x, so fmod would break every wrapping animation that
        // goes negative.
        float mod(float x, float y) { return x - y * floor(x / y); }
        vec2 mod(vec2 x, vec2 y) { return x - y * floor(x / y); }
        vec3 mod(vec3 x, vec3 y) { return x - y * floor(x / y); }
        vec4 mod(vec4 x, vec4 y) { return x - y * floor(x / y); }
        vec2 mod(vec2 x, float y) { return x - y * floor(x / y); }
        vec3 mod(vec3 x, float y) { return x - y * floor(x / y); }
        vec4 mod(vec4 x, float y) { return x - y * floor(x / y); }

        // GLSL's two-argument atan is Metal's atan2. Defining atan here hides
        // Metal's, so the one-argument forms are restated too.
        float atan(float y, float x) { return metal::atan2(y, x); }
        vec2 atan(vec2 y, vec2 x) { return metal::atan2(y, x); }
        vec3 atan(vec3 y, vec3 x) { return metal::atan2(y, x); }
        vec4 atan(vec4 y, vec4 x) { return metal::atan2(y, x); }
        float atan(float x) { return metal::atan(x); }
        vec2 atan(vec2 x) { return metal::atan(x); }
        vec3 atan(vec3 x) { return metal::atan(x); }
        vec4 atan(vec4 x) { return metal::atan(x); }

        // mod with an int or uint vector divisor (`mod(uv, glyphSize)`, uvec2).
        vec2 mod(vec2 x, uvec2 y) { return mod(x, vec2(y)); }
        vec2 mod(vec2 x, ivec2 y) { return mod(x, vec2(y)); }
        vec3 mod(vec3 x, ivec3 y) { return mod(x, vec3(y)); }
        vec4 mod(vec4 x, ivec4 y) { return mod(x, vec4(y)); }
        float inversesqrt(float x) { return metal::rsqrt(x); }
        vec2 inversesqrt(vec2 x) { return metal::rsqrt(x); }
        vec3 inversesqrt(vec3 x) { return metal::rsqrt(x); }
        vec4 inversesqrt(vec4 x) { return metal::rsqrt(x); }

        float radians(float d) { return d * 0.017453292519943295; }
        vec2 radians(vec2 d) { return d * 0.017453292519943295; }
        vec3 radians(vec3 d) { return d * 0.017453292519943295; }
        vec4 radians(vec4 d) { return d * 0.017453292519943295; }
        float degrees(float r) { return r * 57.29577951308232; }
        vec2 degrees(vec2 r) { return r * 57.29577951308232; }
        vec3 degrees(vec3 r) { return r * 57.29577951308232; }
        vec4 degrees(vec4 r) { return r * 57.29577951308232; }

        // Component-wise comparisons, which Metal writes as operators.
        bvec2 lessThan(vec2 a, vec2 b) { return a < b; }
        bvec3 lessThan(vec3 a, vec3 b) { return a < b; }
        bvec4 lessThan(vec4 a, vec4 b) { return a < b; }
        bvec2 lessThanEqual(vec2 a, vec2 b) { return a <= b; }
        bvec3 lessThanEqual(vec3 a, vec3 b) { return a <= b; }
        bvec4 lessThanEqual(vec4 a, vec4 b) { return a <= b; }
        bvec2 greaterThan(vec2 a, vec2 b) { return a > b; }
        bvec3 greaterThan(vec3 a, vec3 b) { return a > b; }
        bvec4 greaterThan(vec4 a, vec4 b) { return a > b; }
        bvec2 greaterThanEqual(vec2 a, vec2 b) { return a >= b; }
        bvec3 greaterThanEqual(vec3 a, vec3 b) { return a >= b; }
        bvec4 greaterThanEqual(vec4 a, vec4 b) { return a >= b; }
        bvec2 equal(vec2 a, vec2 b) { return a == b; }
        bvec3 equal(vec3 a, vec3 b) { return a == b; }
        bvec4 equal(vec4 a, vec4 b) { return a == b; }
        bvec2 notEqual(vec2 a, vec2 b) { return a != b; }
        bvec3 notEqual(vec3 a, vec3 b) { return a != b; }
        bvec4 notEqual(vec4 a, vec4 b) { return a != b; }

        // ---- ISF image access ---------------------------------------------------
        // All sampling goes through IMG_NORM_PIXEL, the one place the y flip lives.

        vec2 IMG_SIZE(texture2d<float> image) {
            return vec2(float(image.get_width()), float(image.get_height()));
        }
        vec4 IMG_NORM_PIXEL(texture2d<float> image, vec2 normalised) {
            return image.sample(isf_sampler, float2(normalised.x, 1.0 - normalised.y));
        }
        vec4 IMG_PIXEL(texture2d<float> image, vec2 pixel) {
            return IMG_NORM_PIXEL(image, pixel / IMG_SIZE(image));
        }
        vec4 IMG_THIS_NORM_PIXEL(texture2d<float> image) {
            return IMG_NORM_PIXEL(image, isf_FragNormCoord);
        }
        vec4 IMG_THIS_PIXEL(texture2d<float> image) {
            return IMG_NORM_PIXEL(image, isf_FragNormCoord);
        }

        // Plain GLSL sampling, for files written against older ISF or ported from
        // elsewhere. `texture` is renamed `texture_` by the converter because
        // `texture` is a Metal keyword.
        vec4 texture2D(texture2d<float> image, vec2 normalised) {
            return IMG_NORM_PIXEL(image, normalised);
        }
        vec4 texture2D(texture2d<float> image, vec2 normalised, float bias) {
            return IMG_NORM_PIXEL(image, normalised);
        }
        vec4 texture_(texture2d<float> image, vec2 normalised) {
            return IMG_NORM_PIXEL(image, normalised);
        }
        vec4 texture2DRect(texture2d<float> image, vec2 pixel) {
            return IMG_PIXEL(image, pixel);
        }
    """
}
