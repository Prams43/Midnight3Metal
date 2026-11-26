#include "gpu/metal_shaders.h"
#include <regex>
#include <string>

namespace gpu {

namespace {

void ReplaceAll(std::string& s, const std::string& from, const std::string& to) {
    if (from.empty()) return;
    size_t pos = 0;
    while ((pos = s.find(from, pos)) != std::string::npos) {
        s.replace(pos, from.size(), to);
        pos += to.size();
    }
}

// Replace `=` scalar zero initialization on vector types, e.g. `float4 r1 = 0;` -> `float4 r1 = float4(0.0f);`
// Also handles comma-separated declarations like `float3 la = 0, ld = 0, ls = 0;`
std::string FixVectorZeroInit(std::string s) {
    // Handle `float4 x = 0;` and `float4 a = ..., b = 0;`
    s = std::regex_replace(s, std::regex(R"(\b(float[234])\s+([A-Za-z_]\w*)\s*=\s*0\s*;)"), "$1 $2 = $1(0.0f);");
    s = std::regex_replace(s, std::regex(R"(\bfloat3\s+la\s*=\s*0,\s*ld\s*=\s*0,\s*ls\s*=\s*0;)"),
                           "float3 la = float3(0.0f), ld = float3(0.0f), ls = float3(0.0f);");
    s = std::regex_replace(s, std::regex(R"(\bfloat4\s+cur\s*=\s*v0,\s*tmp\s*=\s*0;)"),
                           "float4 cur = v0, tmp = float4(0.0f);");
    s = std::regex_replace(s, std::regex(R"(\bfloat4\s+r0\s*=\s*([^;]+),\s*r1\s*=\s*0;)"),
                           "float4 r0 = $1, r1 = float4(0.0f);");
    return s;
}

std::string CommonHlslToMslFixes(std::string s) {
    // Strip cbuffer VC and DC declarations (we emit clean MSL structs at the top)
    s = std::regex_replace(s, std::regex(R"(cbuffer\s+VC\s*:\s*register\(b0\)\s*\{[^}]*\}\s*;)"), "");
    s = std::regex_replace(s, std::regex(R"(cbuffer\s+DC\s*:\s*register\(b1\)\s*\{[^}]*\}\s*;)"), "");

    // Strip Texture/Sampler global declarations (moved to fs_main parameters)
    s = std::regex_replace(s, std::regex(R"(Texture(?:2D<float>|2D|3D|Cube)\s+tex\d+\s*:\s*register\(t\d+\)\s*;\s*)"), "");
    s = std::regex_replace(s, std::regex(R"(Sampler(?:ComparisonState|State)\s+smp\d+\s*:\s*register\(s\d+\)\s*;\s*)"), "");

    // Basic keyword & intrinsic translations
    ReplaceAll(s, "precise ", "");
    ReplaceAll(s, "1.#INF", "INFINITY");
    ReplaceAll(s, "(float4)0", "float4(0.0f)");
    ReplaceAll(s, "(float3)0", "float3(0.0f)");
    ReplaceAll(s, "(float2)0", "float2(0.0f)");
    ReplaceAll(s, "discard;", "discard_fragment();");
    ReplaceAll(s, "lerp(", "mix(");
    ReplaceAll(s, "frac(", "fract(");
    ReplaceAll(s, "ddx(", "dfdx(");
    ReplaceAll(s, "ddy(", "dfdy(");

    // `(float4)(a < b)` -> `float4(a < b)` and `(float)(...)` -> `float(...)`
    s = std::regex_replace(s, std::regex(R"(\(float([234]?)\)\s*\()"), "float$1(");

    // Fix `mac_mul`: in MSL `(a == 0 || b == 0)` on float4 is invalid; use select
    ReplaceAll(s,
               "float4 mac_mul(float4 a, float4 b) { return (a == 0 || b == 0) ? (float4)0 : a * b; }",
               "float4 mac_mul(float4 a, float4 b) { return select(a * b, float4(0.0f), (a == 0.0f) | (b == 0.0f)); }");
    // In case (float4)0 was already replaced above:
    ReplaceAll(s,
               "float4 mac_mul(float4 a, float4 b) { return (a == 0 || b == 0) ? float4(0.0f) : a * b; }",
               "float4 mac_mul(float4 a, float4 b) { return select(a * b, float4(0.0f), (a == 0.0f) | (b == 0.0f)); }");

    // Scalar `.xxxx` swizzles (invalid on float in MSL)
    s = std::regex_replace(s, std::regex(R"(magclamp\(1\.0 / v\)\.xxxx)"), "float4(magclamp(1.0f / v))");
    s = std::regex_replace(s, std::regex(R"(\(1\.0 / v\)\.xxxx)"), "float4(1.0f / v)");
    s = std::regex_replace(s, std::regex(R"(\(rsqrt\(abs\(v\)\)\)\.xxxx)"), "float4(rsqrt(abs(v)))");
    s = std::regex_replace(s, std::regex(R"(\(INFINITY\)\.xxxx)"), "float4(INFINITY)");
    s = std::regex_replace(s, std::regex(R"(dot\(([^;{}]+?)\)\.xxxx)"), "float4(dot($1))");
    s = std::regex_replace(s, std::regex(R"(t\.SampleCmpLevelZero\(([^;{}]+?)\)\.xxxx)"), "float4(t.sample_compare($1))");

    // Fix MSL type/overload ambiguities in VS/PS helpers
    ReplaceAll(s, "max(s.x, 0)", "max(s.x, 0.0f)");
    ReplaceAll(s, "max(s.y, 0)", "max(s.y, 0.0f)");
    ReplaceAll(s, "clamp(z, 0, mx)", "clamp(z, 0.0f, mx)");
    ReplaceAll(s, ", -1, 1)", ", -1.0f, 1.0f)");
    ReplaceAll(s, ", -1.0, 1.0)", ", -1.0f, 1.0f)");
    s = std::regex_replace(s, std::regex(R"(\bmax\(([^;{}]+?),\s*0(?:\.0)?\))"), "max($1, 0.0f)");
    ReplaceAll(s, "return (b - (b >= 128 ? hi : lo)) / d;", "return (b - select(float3(lo), float3(hi), b >= 128.0f)) / d;");

    // Texture sampling methods
    ReplaceAll(s,
               "t.SampleLevel(s, uv + w.xy * (float2(x, y) - (n - 1) * 0.5), 0)",
               "t.sample(s, uv + w.xy * (float2(x, y) - (n - 1) * 0.5f), level(0.0f))");
    s = std::regex_replace(s, std::regex(R"((\b(?:tex\d+|t))\.(?:SampleCmpLevelZero)\(([^)]+)\))"), "$1.sample_compare($2)");
    s = std::regex_replace(s, std::regex(R"((\b(?:tex\d+|t))\.SampleLevel\(([^,]+),\s*([^,]+),\s*([^)]+)\))"), "$1.sample($2, $3, level($4))");
    s = std::regex_replace(s, std::regex(R"((\b(?:tex\d+|t))\.Sample\()"), "$1.sample(");
    s = std::regex_replace(s, std::regex(R"(tex3\.Load\(int3\(([^,]+),\s*0\)\))"), "tex3.read(uint2($1), 0)");

    // `mul(v, m)` -> `(v * m)`
    s = std::regex_replace(s, std::regex(R"(\bmul\s*\()"), "hlsl_mul(");

    // Fix vector zero initializations
    s = FixVectorZeroInit(std::move(s));

    // Fix VOut semantics
    ReplaceAll(s, "float4 pos : SV_Position;", "float4 pos [[position]];");
    s = std::regex_replace(s, std::regex(R"(\s*:\s*(?:COLOR|TEXCOORD)\d+\s*;)"), ";");

    // Fix VIn / VRaw input attributes
    s = std::regex_replace(s, std::regex(R"(:\s*ATTR(\d+)\s*;)"), "[[attribute($1)]];");
    ReplaceAll(s, "uint id : SV_VertexID;", "");

    return s;
}

const char* kMslPreamble = R"(#include <metal_stdlib>
using namespace metal;

struct VC {
    float4 c[192];
};

struct DC {
    float4 surf;
    float4 fogp;
    float4 fogcolor;
    float4 misc;
    float4 pc[18];
    float4 tfactor;
    float4 texsize[4];
    float4 bumpmat[4];
    float4 bumplum[4];
    float4x4 wvp;
    float4 ext;
    float4 spread[4];
    float4x4 wv;
    float4x4 wvn;
    float4x4 tm[4];
    float4 mat[5];
    float4 amb;
    float4 lt[56];
};

inline float4 hlsl_mul(float4 v, float4x4 m) { return v * m; }
)";

std::string InjectConstantBufferAccess(std::string s) {
    // Prefix DC fields with `dc.` and VC array `c[` with `vc.c[`
    static const char* kDcFields[] = {
        "surf", "fogp", "fogcolor", "misc", "pc", "tfactor", "texsize",
        "bumpmat", "bumplum", "wvp", "ext", "spread", "wv", "wvn", "tm",
        "mat", "amb", "lt"
    };
    for (const char* f : kDcFields) {
        s = std::regex_replace(s, std::regex(std::string(R"(\b)") + f + R"(\b)"), std::string("dc.") + f);
    }
    s = std::regex_replace(s, std::regex(R"(\bc\s*\[)"), "vc.c[");
    return s;
}

// Helper: add `constant VC& vc, constant DC& dc` to helper functions that reference vc/dc
std::string ForwardBuffersToHelpers(std::string s) {
    // fogfactor uses dc.fogp
    ReplaceAll(s, "float fogfactor(float d) {", "float fogfactor(float d, constant DC& dc) {");
    ReplaceAll(s, "fogfactor(oFog.x)", "fogfactor(oFog.x, dc)");
    ReplaceAll(s, "fogfactor(abs(cp.z))", "fogfactor(abs(cp.z), dc)");

    // alphatest uses dc.misc
    ReplaceAll(s, "void alphatest(float a) {", "void alphatest(float a, constant DC& dc) {");
    ReplaceAll(s, "alphatest(outc.a);", "alphatest(outc.a, dc);");

    // spreadtap uses texture2d<float> / sampler
    ReplaceAll(s, "float4 spreadtap(Texture2D t, SamplerState s,",
               "float4 spreadtap(texture2d<float> t, sampler s,");

    // shadow uses depth2d<float> / sampler
    ReplaceAll(s, "float4 shadow(Texture2D<float> t, SamplerComparisonState s,",
               "float4 shadow(depth2d<float> t, sampler s,");

    // HeadVis uses vc.c
    ReplaceAll(s, "float HeadVis(float4 p, out float inside) {",
               "float HeadVis(float4 p, thread float& inside, constant VC& vc, texture2d<float> tex3) {");
    ReplaceAll(s, "HeadVis(i.pos, hin)", "HeadVis(i.pos, hin, vc, tex3)");

    // UnpackNp3: MSL max(float3, float3)
    ReplaceAll(s, "float3(1023, 1023, 511), -1)", "float3(1023.0f, 1023.0f, 511.0f), float3(-1.0f))");

    return s;
}

}  // namespace

std::string TranslateVertexHlslToMsl(const std::string& hlsl, uint16_t regs) {
    std::string s = CommonHlslToMslFixes(hlsl);

    // Replace entry point signature
    std::string params = regs
        ? "vertex VOut vs_main(VIn i [[stage_in]], constant VC& vc [[buffer(16)]], constant DC& dc [[buffer(17)]]) {"
        : "vertex VOut vs_main(uint id [[vertex_id]], constant VC& vc [[buffer(16)]], constant DC& dc [[buffer(17)]]) {\n    VIn i;";

    if (s.find("VOut main(VRaw ri)") != std::string::npos) {
        std::string rawParams = "vertex VOut vs_main(VRaw ri [[stage_in]], constant VC& vc [[buffer(16)]], constant DC& dc [[buffer(17)]]) {";
        ReplaceAll(s, "VOut main(VRaw ri) {", rawParams);
    } else {
        ReplaceAll(s, "VOut main(VIn i) {", params);
    }

    s = InjectConstantBufferAccess(std::move(s));
    s = ForwardBuffersToHelpers(std::move(s));

    return std::string(kMslPreamble) + s;
}

std::string TranslatePixelHlslToMsl(const std::string& hlsl, const PixelKey& key) {
    std::string s = CommonHlslToMslFixes(hlsl);

    std::string texParams;
    for (int i = 0; i < 4; i++) {
        const TexInfo& t = key.tex[i];
        const char* ttype = t.shadow ? "depth2d<float>"
                          : t.kind == kTex3D ? "texture3d<float>"
                          : t.kind == kTexCube ? "texturecube<float>"
                          : "texture2d<float>";
        texParams += ", " + std::string(ttype) + " tex" + std::to_string(i) + " [[texture(" + std::to_string(i) + ")]]";
        texParams += ", sampler smp" + std::to_string(i) + " [[sampler(" + std::to_string(i) + ")]]";
    }

    std::string fsSig = "fragment float4 fs_main(VOut i [[stage_in]], bool front [[front_facing]], "
                        "constant VC& vc [[buffer(16)]], constant DC& dc [[buffer(17)]]" + texParams + ") {";
    ReplaceAll(s, "float4 main(VOut i, bool front : SV_IsFrontFace) : SV_Target {", fsSig);

    s = InjectConstantBufferAccess(std::move(s));
    s = ForwardBuffersToHelpers(std::move(s));

    return std::string(kMslPreamble) + s;
}

}  // namespace gpu
