#include "gpu/backend.h"
#include "gpu/metal.h"
#include "gpu/metal_shaders.h"
#include "gpu/shaders.h"
#include "gpu/texture.h"
#include "gpu/vertex.h"
#include "core/log.h"
#include "kernel/kernel.h"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace gpu {

namespace {

CAMetalLayer* g_metal_layer = nil;

struct MetalVertex {
    float pos[4];     // v0
    float weight[4];  // v1
    float norm[4];    // v2
    float col[4];     // v3
    float spec[4];    // v4
    float uv0[4];     // v9
    float uv1[4];     // v10
    float uv2[4];     // v11
    float uv3[4];     // v12
};

static const char* kMetalPassthroughShader = R"(
#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float4 position [[attribute(0)]];
    float4 color [[attribute(3)]];
    float4 uv [[attribute(9)]];
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
};

vertex VertexOut vertex_main(VertexIn in [[stage_in]]) {
    VertexOut out;
    out.position = in.position;
    out.color = in.color;
    out.uv = in.uv.xy;
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]],
                              texture2d<float> tex0 [[texture(0)]],
                              sampler samp0 [[sampler(0)]]) {
    return in.color * tex0.sample(samp0, in.uv);
}
)";

MTLBlendFactor ToMetalBlend(uint32_t nv_blend, bool is_alpha) {
    // Xbox NV2A uses OpenGL blend factor enums (not D3DBLEND 1..10).
    switch (nv_blend) {
    case 0:      return MTLBlendFactorZero;
    case 1:      return MTLBlendFactorOne;
    case 0x300:  return is_alpha ? MTLBlendFactorSourceAlpha : MTLBlendFactorSourceColor;
    case 0x301:  return is_alpha ? MTLBlendFactorOneMinusSourceAlpha : MTLBlendFactorOneMinusSourceColor;
    case 0x302:  return MTLBlendFactorSourceAlpha;
    case 0x303:  return MTLBlendFactorOneMinusSourceAlpha;
    case 0x304:  return MTLBlendFactorDestinationAlpha;
    case 0x305:  return MTLBlendFactorOneMinusDestinationAlpha;
    case 0x306:  return is_alpha ? MTLBlendFactorDestinationAlpha : MTLBlendFactorDestinationColor;
    case 0x307:  return is_alpha ? MTLBlendFactorOneMinusDestinationAlpha : MTLBlendFactorOneMinusDestinationColor;
    case 0x308:  return MTLBlendFactorSourceAlphaSaturated;
    case 0x8001:
    case 0x8003: return is_alpha ? MTLBlendFactorBlendAlpha : MTLBlendFactorBlendColor;
    case 0x8002:
    case 0x8004: return is_alpha ? MTLBlendFactorOneMinusBlendAlpha : MTLBlendFactorOneMinusBlendColor;
    default:     return MTLBlendFactorOne;
    }
}

MTLBlendOperation ToMetalBlendOp(uint32_t nv_op) {
    switch (nv_op) {
    case 0x800A: return MTLBlendOperationSubtract;
    case 0x800B:
    case 0xF005: return MTLBlendOperationReverseSubtract;
    case 0x8007: return MTLBlendOperationMin;
    case 0x8008: return MTLBlendOperationMax;
    case 0:
    case 0x8006:
    case 0xF006:
    default:     return MTLBlendOperationAdd;
    }
}

MTLColorWriteMask ToMetalWriteMask(uint32_t cw) {
    // When unset (0), default to all channels only if kMColorWriteEnable was never written;
    // in D3D8, SetRenderTarget / InitDefaultState sets kMColorWriteEnable = 0x0F0F0F0F or 0x01010101.
    MTLColorWriteMask m = MTLColorWriteMaskNone;
    if ((cw >> 16) & 1) m |= MTLColorWriteMaskRed;
    if ((cw >> 8) & 1)  m |= MTLColorWriteMaskGreen;
    if (cw & 1)         m |= MTLColorWriteMaskBlue;
    if ((cw >> 24) & 1) m |= MTLColorWriteMaskAlpha;
    return m;
}

MTLCompareFunction ToMetalCompare(uint32_t d3d_cmp) {
    // D3DCMPFUNC: 1=NEVER .. 8=ALWAYS (NV2A/D3D8 uses 0x200+i or 1..8)
    const uint32_t c = (d3d_cmp >= 0x200) ? (d3d_cmp - 0x200 + 1) : d3d_cmp;
    switch (c) {
    case 1: return MTLCompareFunctionNever;
    case 2: return MTLCompareFunctionLess;
    case 3: return MTLCompareFunctionEqual;
    case 4: return MTLCompareFunctionLessEqual;
    case 5: return MTLCompareFunctionGreater;
    case 6: return MTLCompareFunctionNotEqual;
    case 7: return MTLCompareFunctionGreaterEqual;
    case 8:
    default: return MTLCompareFunctionAlways;
    }
}

void MulMat4Vec4(const float m[16], const float v[4], float out[4]) {
    for (int col = 0; col < 4; ++col) {
        out[col] = v[0] * m[0 * 4 + col] + v[1] * m[1 * 4 + col] +
                   v[2] * m[2 * 4 + col] + v[3] * m[3 * 4 + col];
    }
}

MTLPrimitiveType ToMetalPrimitive(Topology topo, bool strip) {
    switch (topo) {
    case Topology::Points: return MTLPrimitiveTypePoint;
    case Topology::Lines: return strip ? MTLPrimitiveTypeLineStrip : MTLPrimitiveTypeLine;
    case Topology::Triangles:
    default: return strip ? MTLPrimitiveTypeTriangleStrip : MTLPrimitiveTypeTriangle;
    }
}

class MetalBackend final : public Backend {
public:
    ~MetalBackend() override { Flush(); }

    bool Init(uint32_t width, uint32_t height) override {
        guest_width_ = width ? width : 640;
        guest_height_ = height ? height : 480;

        layer_ = g_metal_layer;
        if (!layer_) {
            LOGE("metal: CAMetalLayer not set via gpu::SetMetalLayer");
            return false;
        }

        device_ = MTLCreateSystemDefaultDevice();
        if (!device_) {
            LOGE("metal: MTLCreateSystemDefaultDevice failed");
            return false;
        }

        queue_ = [device_ newCommandQueue];
        if (!queue_) {
            LOGE("metal: newCommandQueue failed");
            return false;
        }

        layer_.device = device_;
        layer_.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer_.framebufferOnly = YES;

        NSError* err = nil;
        id<MTLLibrary> lib = [device_ newLibraryWithSource:@(kMetalPassthroughShader) options:nil error:&err];
        if (!lib) {
            LOGE("metal: shader compile failed: %s", [[err localizedDescription] UTF8String]);
            return false;
        }

        id<MTLFunction> vs = [lib newFunctionWithName:@"vertex_main"];
        id<MTLFunction> fs = [lib newFunctionWithName:@"fragment_main"];
        if (!vs || !fs) {
            LOGE("metal: missing vertex_main or fragment_main");
            return false;
        }

        MTLVertexDescriptor* vd = [[MTLVertexDescriptor alloc] init];
        auto set_attr = [&](NSUInteger idx, size_t off) {
            vd.attributes[idx].format = MTLVertexFormatFloat4;
            vd.attributes[idx].offset = off;
            vd.attributes[idx].bufferIndex = 0;
        };
        set_attr(0, offsetof(MetalVertex, pos));
        set_attr(1, offsetof(MetalVertex, weight));
        set_attr(2, offsetof(MetalVertex, norm));
        set_attr(3, offsetof(MetalVertex, col));
        set_attr(4, offsetof(MetalVertex, spec));
        set_attr(9, offsetof(MetalVertex, uv0));
        set_attr(10, offsetof(MetalVertex, uv1));
        set_attr(11, offsetof(MetalVertex, uv2));
        set_attr(12, offsetof(MetalVertex, uv3));

        vd.layouts[0].stride = sizeof(MetalVertex);
        vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

        vertex_desc_ = vd;
        vs_func_ = vs;
        fs_func_ = fs;

        pipeline_ = GetPipeline(0, 0, vs_func_, fs_func_, false, 1, 0, 0, MTLColorWriteMaskAll);
        if (!pipeline_) return false;

        // 1x1 white fallback texture for untextured draws, 1x1 transparent black for unrendered RTs
        MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:1
                                                                                     height:1
                                                                                  mipmapped:NO];
        white_tex_ = [device_ newTextureWithDescriptor:td];
        const uint32_t white = 0xFFFFFFFFu;
        [white_tex_ replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&white bytesPerRow:4];

        black_tex_ = [device_ newTextureWithDescriptor:td];
        const uint32_t black = 0x00000000u;
        [black_tex_ replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&black bytesPerRow:4];

        MTLSamplerDescriptor* sd = [[MTLSamplerDescriptor alloc] init];
        sd.minFilter = MTLSamplerMinMagFilterLinear;
        sd.magFilter = MTLSamplerMinMagFilterLinear;
        sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        sampler_ = [device_ newSamplerStateWithDescriptor:sd];
        sd.sAddressMode = MTLSamplerAddressModeRepeat;
        sd.tAddressMode = MTLSamplerAddressModeRepeat;
        wrap_sampler_ = [device_ newSamplerStateWithDescriptor:sd];

        LOGI("metal: backend initialized (%ux%u, device=%s)", guest_width_, guest_height_,
             [device_.name UTF8String]);
        return true;
    }

    bool IsOffscreenTarget(const State& s) {
        if (!s.rt.header) return false;
        uint32_t w = 0, h = 0;
        SurfaceSize(s.rt, w, h);
        const uint32_t rt_va = mem::VirtualFromPhysical(s.rt.data);
        if ((w && w != guest_width_) || (h && h != guest_height_)) {
            if (rt_va) offscreen_rt_data_.insert(rt_va);
            return true;
        }
        // Seed the primary swapchain render target data address on the first full-size target
        if (rt_va && main_rt_data_.empty()) {
            main_rt_data_.insert(rt_va);
        }
        if (rt_va && !main_rt_data_.empty() && main_rt_data_.find(rt_va) == main_rt_data_.end()) {
            offscreen_rt_data_.insert(rt_va);
            return true;
        }
        return false;
    }

    void Clear(const State& s, uint32_t, const uint8_t*, uint32_t flags, uint32_t color, float z, uint32_t) override {
        if (IsOffscreenTarget(s)) return;
        // If we already encoded draws in this frame, only apply mid-frame depth clears or full target clears before draws
        if (encoder_) return;
        if (flags & kClearTarget) {
            const double a = ((color >> 24) & 0xFF) / 255.0;
            const double r = ((color >> 16) & 0xFF) / 255.0;
            const double g = ((color >> 8) & 0xFF) / 255.0;
            const double b = (color & 0xFF) / 255.0;
            clear_color_ = MTLClearColorMake(r, g, b, a);
            has_clear_ = true;
        }
        if (flags & kClearZ) {
            clear_depth_ = double(z);
            has_depth_clear_ = true;
        }
    }

    void Draw(const State& s, uint32_t prim, uint32_t start, uint32_t count, const uint8_t* indices) override {
        if (!pipeline_ || !layer_) return;
        if (IsOffscreenTarget(s)) return;
        const uint32_t blend_op = s.simple[kMBlendOp / 4];
        if (s.simple[kMBlendEnable / 4] && (blend_op == 0xF005 || blend_op == 0xF006)) return;
        @autoreleasepool {
            DrawImpl(s, prim, start, count, indices);
        }
    }

    void DrawImpl(const State& s, uint32_t prim, uint32_t start, uint32_t count, const uint8_t* indices) {

        Assembled a;
        if (!Assemble(s, prim, start, count, indices, a)) return;
        if (a.vertex_count == 0) return;

        auto read_attr = [&](int reg, uint32_t v, float out[4]) -> bool {
            if ((a.regs & (1u << reg)) == 0) return false;
            if (!a.vertices.empty()) {
                const int reg_count = std::popcount(a.regs);
                const int slot = std::popcount(a.regs & ((1u << reg) - 1));
                const float* p = &a.vertices[(size_t(v) * size_t(reg_count) + size_t(slot)) * 4];
                std::memcpy(out, p, 16);
                return true;
            }
            const auto& e = a.elements[size_t(reg)];
            if (e.buffer >= a.buffer_count || !a.buffers[e.buffer].src) return false;
            const auto& buf = a.buffers[e.buffer];
            const size_t off = size_t(v) * buf.stride + e.offset;
            if (off >= buf.bytes) return false;
            const uint8_t* p = buf.src + off;
            out[0] = out[1] = out[2] = 0.0f;
            out[3] = 1.0f;
            switch (e.format) {
            case 2: // DXGI_FORMAT_R32G32B32A32_FLOAT
                std::memcpy(out, p, 16);
                return true;
            case 6: // DXGI_FORMAT_R32G32B32_FLOAT
                std::memcpy(out, p, 12);
                return true;
            case 16: // DXGI_FORMAT_R32G32_FLOAT
                std::memcpy(out, p, 8);
                return true;
            case 87: // DXGI_FORMAT_B8G8R8A8_UNORM (D3DCOLOR)
                out[0] = p[2] / 255.0f;
                out[1] = p[1] / 255.0f;
                out[2] = p[0] / 255.0f;
                out[3] = p[3] / 255.0f;
                return true;
            case 28: // DXGI_FORMAT_R8G8B8A8_UNORM
                out[0] = p[0] / 255.0f;
                out[1] = p[1] / 255.0f;
                out[2] = p[2] / 255.0f;
                out[3] = p[3] / 255.0f;
                return true;
            default:
                return false;
            }
        };

        // Resolve textures & TexInfo for all 4 stages
        id<MTLTexture> stage_tex[4] = { white_tex_, white_tex_, white_tex_, white_tex_ };
        id<MTLSamplerState> stage_smp[4] = { sampler_, sampler_, sampler_, sampler_ };
        TexInfo tex_info[4]{};
        float tex_dims[4][2] = {{1.0f, 1.0f}, {1.0f, 1.0f}, {1.0f, 1.0f}, {1.0f, 1.0f}};
        for (int t = 0; t < 4; ++t) {
            if (s.textures[t]) {
                TextureDesc td{};
                const uint32_t simple_pal = s.simple[(0x1B20 + uint32_t(t) * 0x40) / 4];
                id<MTLTexture> mt = ResolveTexture(s.textures[t], s.palettes[t], simple_pal, &td);
                if (mt) {
                    stage_tex[t] = mt;
                    tex_info[t].kind = (td.cube) ? kTexCube : (td.depth > 1) ? kTex3D : kTex2D;
                    tex_info[t].rect = td.linear ? 1 : 0;
                    tex_dims[t][0] = td.width ? float(td.width) : 1.0f;
                    tex_dims[t][1] = td.height ? float(td.height) : 1.0f;
                    const uint32_t addr_u = s.tss[size_t(t)][kTssAddressU];
                    const uint32_t addr_v = s.tss[size_t(t)][kTssAddressV];
                    if (!td.linear && (addr_u == 1 || addr_v == 1)) {
                        stage_smp[t] = wrap_sampler_;
                    }
                }
            }
        }

        // Determine active vertex registers supplied by our MetalVertex layout
        constexpr uint16_t kSupportedRegs = (1u << 0) | (1u << 1) | (1u << 2) | (1u << 3) | (1u << 4) |
                                            (1u << 9) | (1u << 10) | (1u << 11) | (1u << 12);
        const uint16_t supplied_regs = (a.regs & kSupportedRegs) | (1u << 0);
        const FixedKey fk = MakeFixedKey(s);
        uint64_t vs_hash = 0, ps_hash = 0;
        id<MTLFunction> active_vs = nil;
        id<MTLFunction> active_fs = nil;

        {
            const bool is_prog_vs = (s.vs_handle & 1) && s.vs && !s.vs->program.empty();
            if (is_prog_vs) {
                uint64_t prog_h = s.vs->hash ? s.vs->hash : Hash(s.vs->program.data(), s.vs->program.size() * 4);
                vs_hash = Hash(&prog_h, sizeof(prog_h), uint64_t(supplied_regs) | 0x5653505200000000ull);
            } else {
                vs_hash = Hash(&fk, sizeof(fk),
                               uint64_t(supplied_regs) | (uint64_t(a.pretransformed) << 16) | 0x5653464600000000ull);
            }
            if (auto it = vs_cache_.find(vs_hash); it != vs_cache_.end()) {
                active_vs = it->second;
            } else {
                std::string vs_hlsl = is_prog_vs
                    ? VertexProgramHlsl(s.vs->program, supplied_regs, 0)
                    : FixedVertexHlsl(supplied_regs, a.pretransformed, 0, fk);
                std::string vs_msl = TranslateVertexHlslToMsl(vs_hlsl, supplied_regs);
                active_vs = GetOrCompileFunction(vs_hash, vs_msl, @"vs_main", vs_cache_);
            }

            PixelKey pk = MakePixelKey(s, tex_info);
            ps_hash = Hash(&pk, sizeof(pk));
            if (auto it = fs_cache_.find(ps_hash); it != fs_cache_.end()) {
                active_fs = it->second;
            } else {
                std::string ps_hlsl = PixelHlsl(pk);
                std::string ps_msl = TranslatePixelHlslToMsl(ps_hlsl, pk);
                active_fs = GetOrCompileFunction(ps_hash, ps_msl, @"fs_main", fs_cache_);
            }
        }

        const bool use_translated = (active_vs != nil && active_fs != nil);
        if (!use_translated) {
            active_vs = vs_func_;
            active_fs = fs_func_;
            vs_hash = 0;
            ps_hash = 0;
        }

        std::vector<MetalVertex> verts(a.vertex_count);
        const float inv_w = 2.0f / float(guest_width_);
        const float inv_h = 2.0f / float(guest_height_);

        for (uint32_t i = 0; i < a.vertex_count; ++i) {
            float p[4] = {};
            if (!read_attr(0, i, p)) return;
            if (use_translated) {
                // Translated HLSL->MSL vertex shaders expect raw guest positions (fixed or programmable)
                verts[i].pos[0] = p[0];
                verts[i].pos[1] = p[1];
                verts[i].pos[2] = p[2];
                verts[i].pos[3] = (p[3] != 0.0f) ? p[3] : 1.0f;
            } else if (a.pretransformed) {
                verts[i].pos[0] = p[0] * inv_w - 1.0f;
                verts[i].pos[1] = 1.0f - p[1] * inv_h;
                verts[i].pos[2] = p[2];
                verts[i].pos[3] = 1.0f;
            } else {
                p[3] = (p[3] != 0.0f) ? p[3] : 1.0f;
                float wv[4], vv[4], pv[4];
                MulMat4Vec4(s.transforms[256].data(), p, wv);
                MulMat4Vec4(s.transforms[2].data(), wv, vv);
                MulMat4Vec4(s.transforms[3].data(), vv, pv);
                verts[i].pos[0] = pv[0];
                verts[i].pos[1] = pv[1];
                verts[i].pos[2] = pv[2];
                verts[i].pos[3] = pv[3];
            }

            if (!read_attr(1, i, verts[i].weight)) {
                verts[i].weight[0] = verts[i].weight[1] = verts[i].weight[2] = 0.0f;
                verts[i].weight[3] = 1.0f;
            }
            if (!read_attr(2, i, verts[i].norm)) {
                verts[i].norm[0] = verts[i].norm[1] = 0.0f;
                verts[i].norm[2] = 1.0f;
                verts[i].norm[3] = 0.0f;
            }
            if (!read_attr(3, i, verts[i].col)) {
                verts[i].col[0] = 1.0f;
                verts[i].col[1] = 1.0f;
                verts[i].col[2] = 1.0f;
                verts[i].col[3] = 1.0f;
            }
            if (!read_attr(4, i, verts[i].spec)) {
                verts[i].spec[0] = verts[i].spec[1] = verts[i].spec[2] = verts[i].spec[3] = 0.0f;
            }

            auto fill_uv = [&](int reg, float dst[4]) {
                dst[0] = dst[1] = dst[2] = 0.0f;
                dst[3] = 1.0f;
                read_attr(reg, i, dst);
            };
            fill_uv(9, verts[i].uv0);
            fill_uv(10, verts[i].uv1);
            fill_uv(11, verts[i].uv2);
            fill_uv(12, verts[i].uv3);
        }

        if (!EnsureEncoder()) return;

        const bool blend_on = s.simple[kMBlendEnable / 4] != 0;
        const uint32_t src_b = s.simple[kMSrcBlend / 4];
        const uint32_t dst_b = s.simple[kMDestBlend / 4];
        const uint32_t blend_op = s.simple[kMBlendOp / 4];
        const uint32_t cw_raw = s.simple[kMColorWriteEnable / 4];
        const MTLColorWriteMask write_mask = s.rt.header
            ? ToMetalWriteMask(cw_raw)
            : MTLColorWriteMaskAll;
        id<MTLRenderPipelineState> pso = GetPipeline(vs_hash, ps_hash, active_vs, active_fs,
                                                     blend_on, src_b, dst_b, blend_op, write_mask);
        if (!pso) return;

        const bool z_en = s.rs[kRsZEnable] != 0;
        const bool z_wr = s.simple[kMZWriteEnable / 4] != 0;
        const uint32_t z_fn = s.simple[kMZFunc / 4];
        id<MTLDepthStencilState> dss = GetDepthStencil(z_en, z_wr, z_fn);

        const size_t vb_bytes = verts.size() * sizeof(MetalVertex);
        id<MTLBuffer> vb = nil;
        if (vb_bytes > 4096) {
            vb = [device_ newBufferWithBytes:verts.data()
                                      length:vb_bytes
                                     options:MTLResourceStorageModeShared];
            if (!vb) return;
        }

        [encoder_ setRenderPipelineState:pso];
        if (dss) [encoder_ setDepthStencilState:dss];
        if (blend_on) {
            const uint32_t bc = s.simple[kMBlendColor / 4];
            [encoder_ setBlendColorRed:((bc >> 16) & 0xFF) / 255.0f
                                 green:((bc >> 8) & 0xFF) / 255.0f
                                  blue:(bc & 0xFF) / 255.0f
                                 alpha:((bc >> 24) & 0xFF) / 255.0f];
        }
        for (int t = 0; t < 4; ++t) {
            [encoder_ setFragmentTexture:stage_tex[t] atIndex:t];
            [encoder_ setFragmentSamplerState:stage_smp[t] atIndex:t];
        }
        if (vb) {
            [encoder_ setVertexBuffer:vb offset:0 atIndex:0];
        } else {
            [encoder_ setVertexBytes:verts.data() length:vb_bytes atIndex:0];
        }

        if (use_translated) {
            DrawConstants dc{};
            FillDrawConstants(s, fk, dc, tex_dims);
            [encoder_ setVertexBytes:s.vsc.data() length:sizeof(s.vsc) atIndex:16];
            [encoder_ setVertexBytes:&dc length:sizeof(dc) atIndex:17];
            [encoder_ setFragmentBytes:s.vsc.data() length:sizeof(s.vsc) atIndex:16];
            [encoder_ setFragmentBytes:&dc length:sizeof(dc) atIndex:17];
        }

        const MTLPrimitiveType mtl_prim = ToMetalPrimitive(a.topology, a.strip);
        if (a.index_count > 0 && !a.indices.empty()) {
            const uint32_t* idx_ptr = a.indices.data();
            std::vector<uint32_t> biased32;
            if (a.base_vertex != 0) {
                biased32.resize(a.index_count);
                for (uint32_t k = 0; k < a.index_count; ++k) {
                    int64_t v = int64_t(a.indices[k]) + int64_t(a.base_vertex);
                    biased32[k] = (v >= 0 && v < int64_t(a.vertex_count)) ? uint32_t(v) : 0u;
                }
                idx_ptr = biased32.data();
            }
            id<MTLBuffer> ib = [device_ newBufferWithBytes:idx_ptr
                                                   length:size_t(a.index_count) * sizeof(uint32_t)
                                                  options:MTLResourceStorageModeShared];
            if (ib) {
                [encoder_ drawIndexedPrimitives:mtl_prim
                                     indexCount:a.index_count
                                      indexType:MTLIndexTypeUInt32
                                    indexBuffer:ib
                              indexBufferOffset:0];
            }
        } else if (a.index_count > 0 && a.index_src) {
            if (a.index16) {
                const auto* src16 = static_cast<const uint16_t*>(a.index_src);
                const uint16_t* idx_ptr = src16;
                std::vector<uint16_t> biased16;
                if (a.base_vertex != 0) {
                    biased16.resize(a.index_count);
                    for (uint32_t k = 0; k < a.index_count; ++k) {
                        int64_t v = int64_t(src16[k]) + int64_t(a.base_vertex);
                        biased16[k] = (v >= 0 && v < int64_t(a.vertex_count)) ? uint16_t(v) : 0u;
                    }
                    idx_ptr = biased16.data();
                }
                id<MTLBuffer> ib = [device_ newBufferWithBytes:idx_ptr
                                                       length:size_t(a.index_count) * sizeof(uint16_t)
                                                      options:MTLResourceStorageModeShared];
                if (ib) {
                    [encoder_ drawIndexedPrimitives:mtl_prim
                                         indexCount:a.index_count
                                          indexType:MTLIndexTypeUInt16
                                        indexBuffer:ib
                                  indexBufferOffset:0];
                }
            } else {
                const auto* src32 = static_cast<const uint32_t*>(a.index_src);
                const uint32_t* idx_ptr = src32;
                std::vector<uint32_t> biased32;
                if (a.base_vertex != 0) {
                    biased32.resize(a.index_count);
                    for (uint32_t k = 0; k < a.index_count; ++k) {
                        int64_t v = int64_t(src32[k]) + int64_t(a.base_vertex);
                        biased32[k] = (v >= 0 && v < int64_t(a.vertex_count)) ? uint32_t(v) : 0u;
                    }
                    idx_ptr = biased32.data();
                }
                id<MTLBuffer> ib = [device_ newBufferWithBytes:idx_ptr
                                                       length:size_t(a.index_count) * sizeof(uint32_t)
                                                      options:MTLResourceStorageModeShared];
                if (ib) {
                    [encoder_ drawIndexedPrimitives:mtl_prim
                                         indexCount:a.index_count
                                          indexType:MTLIndexTypeUInt32
                                        indexBuffer:ib
                                  indexBufferOffset:0];
                }
            }
        } else if (a.draw_count > 0) {
            [encoder_ drawPrimitives:mtl_prim vertexStart:0 vertexCount:a.draw_count];
        }
    }

    void Copy(const Surface&, const Surface&, uint32_t, uint32_t, uint32_t) override {}

    void Present(const Surface& front) override {
        if (!layer_ || !queue_) return;
        if (front.data && main_rt_data_.size() < 8) {
            main_rt_data_.insert(mem::VirtualFromPhysical(front.data));
        }
        @autoreleasepool {
            if (!encoder_ && has_clear_) EnsureEncoder();
            if (encoder_) {
                [encoder_ endEncoding];
                encoder_ = nil;
            }
            if (cmd_buf_) {
                if (drawable_) [cmd_buf_ presentDrawable:drawable_];
                [cmd_buf_ commit];
                last_cmd_buf_ = cmd_buf_;
                cmd_buf_ = nil;
                drawable_ = nil;
            }
            has_clear_ = false;
            has_depth_clear_ = false;
            clear_color_ = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
            clear_depth_ = 1.0;
        }
    }

    void Sync(uint32_t, uint32_t) override { Flush(); }
    void SyncLate(uint32_t) override { Flush(); }

    void Flush() override {
        @autoreleasepool {
            if (last_cmd_buf_) {
                [last_cmd_buf_ waitUntilCompleted];
                last_cmd_buf_ = nil;
            }
        }
    }

    void SetGamma(const uint8_t*) override {}

    void GetReport(uint32_t report) override {
        if (!report) return;
        kernel::W32(report + 0, 1);
        kernel::W32(report + 4, 0);
        kernel::W32(report + 8, 0);
        std::atomic_thread_fence(std::memory_order_release);
        kernel::W32(report + 12, 0);
    }

private:
    struct CachedTex {
        id<MTLTexture> tex = nil;
        uint32_t format = 0;
        uint32_t w = 0, h = 0;
        uint64_t epoch = ~0ull;
    };

    id<MTLFunction> GetOrCompileFunction(uint64_t hash, const std::string& msl, NSString* entry,
                                         std::unordered_map<uint64_t, id<MTLFunction>>& cache) {
        if (auto it = cache.find(hash); it != cache.end()) return it->second;
        NSError* err = nil;
        id<MTLLibrary> lib = [device_ newLibraryWithSource:@(msl.c_str()) options:nil error:&err];
        if (!lib) {
            if (failed_shaders_.insert(hash).second) {
                LOGE("metal: MSL compile failed (%s): %s", [entry UTF8String], [[err localizedDescription] UTF8String]);
            }
            cache[hash] = nil;
            return nil;
        }
        id<MTLFunction> fn = [lib newFunctionWithName:entry];
        cache[hash] = fn;
        return fn;
    }

    static void MulMat4(const float a[16], const float b[16], float out[16]) {
        for (int r = 0; r < 4; ++r) {
            for (int c = 0; c < 4; ++c) {
                out[r * 4 + c] = a[r * 4 + 0] * b[0 * 4 + c] + a[r * 4 + 1] * b[1 * 4 + c] +
                                 a[r * 4 + 2] * b[2 * 4 + c] + a[r * 4 + 3] * b[3 * 4 + c];
            }
        }
    }

    static void TransposeMat4(const float m[16], float out[16]) {
        for (int r = 0; r < 4; ++r) {
            for (int c = 0; c < 4; ++c) {
                out[c * 4 + r] = m[r * 4 + c];
            }
        }
    }

    static void InverseTranspose3x3(const float wv[16], float n[16]) {
        const float det = wv[0] * (wv[5] * wv[10] - wv[6] * wv[9]) -
                          wv[1] * (wv[4] * wv[10] - wv[6] * wv[8]) +
                          wv[2] * (wv[4] * wv[9] - wv[5] * wv[8]);
        const float id = det != 0.0f ? (1.0f / det) : 0.0f;
        for (int r = 0; r < 3; ++r) {
            for (int col = 0; col < 3; ++col) {
                const int r1 = (r + 1) % 3, r2 = (r + 2) % 3;
                const int c1 = (col + 1) % 3, c2 = (col + 2) % 3;
                n[r * 4 + col] = (wv[r1 * 4 + c1] * wv[r2 * 4 + c2] - wv[r1 * 4 + c2] * wv[r2 * 4 + c1]) * id;
            }
        }
    }

    static uint32_t CmpIndex(uint32_t v) {
        const uint32_t c = (v >= 0x200) ? (v - 0x200 + 1) : v;
        return (c >= 1 && c <= 8) ? (c - 1) : 7;
    }

    void FillDrawConstants(const State& s, const FixedKey& fk, DrawConstants& dc, const float tex_dims[4][2]) {
        const float gw = float(guest_width_);
        const float gh = float(guest_height_);
        dc.surf[0] = gw;
        dc.surf[1] = gh;
        dc.surf[2] = s.zscale > 0.0f ? (1.0f / s.zscale) : (1.0f / 16777215.0f);
        dc.surf[3] = 0.0f;

        auto f32 = [](uint32_t u) {
            float f;
            std::memcpy(&f, &u, 4);
            return f;
        };
        const bool vertex_prog = (s.vs && !s.vs->program.empty());
        if (s.rs[kRsFogEnable]) {
            if (vertex_prog && s.rs[kRsFogTableMode] == 0) {
                dc.fog[0] = 1.0f;
                dc.fog[1] = 0.0f;
                dc.fog[2] = 0.0f;
                dc.fog[3] = 3.0f;
            } else {
                dc.fog[0] = f32(s.rs[kRsFogStart]);
                dc.fog[1] = f32(s.rs[kRsFogEnd]);
                dc.fog[2] = f32(s.rs[kRsFogDensity]);
                dc.fog[3] = float(s.rs[kRsFogTableMode]);
            }
        }

        auto unpack_c = [](uint32_t v, float out[4]) {
            out[0] = ((v >> 16) & 0xFF) / 255.0f;
            out[1] = ((v >> 8) & 0xFF) / 255.0f;
            out[2] = (v & 0xFF) / 255.0f;
            out[3] = ((v >> 24) & 0xFF) / 255.0f;
        };
        unpack_c(s.rs[kRsFogColor], dc.fog_color);

        dc.misc[0] = float(s.simple[kMAlphaRef / 4] & 0xFF);
        dc.misc[1] = s.simple[kMAlphaTestEnable / 4] ? float(CmpIndex(s.simple[kMAlphaFunc / 4])) : 7.0f;
        dc.misc[2] = float(CmpIndex(s.rs[kRsShadowFunc]));
        dc.misc[3] = s.rs[kRsSpecularEnable] ? 1.0f : 0.0f;

        unpack_c(s.rs[kRsTextureFactor], dc.tfactor);

        for (int i = 0; i < 8; ++i) {
            unpack_c(s.simple[kMPsConstant0 / 4 + i], dc.pc[i * 2 + 0]);
            unpack_c(s.simple[kMPsConstant1 / 4 + i], dc.pc[i * 2 + 1]);
        }
        unpack_c(s.simple[kMPsFinalConstant0 / 4], dc.pc[16]);
        unpack_c(s.simple[kMPsFinalConstant1 / 4], dc.pc[17]);

        float wv[16], wvp[16], full[16], n[16] = {};
        MulMat4(s.transforms[256].data(), s.transforms[2].data(), wv);
        MulMat4(wv, s.transforms[3].data(), wvp);
        const auto& vp = s.viewport;
        const float sx = float(vp.w) / gw;
        const float sy = float(vp.h) / gh;
        const float ox = (2.0f * vp.x + vp.w) / gw - 1.0f;
        const float oy = 1.0f - (2.0f * vp.y + vp.h) / gh;
        const float vpm[16] = {
            sx, 0,  0,                  0,
            0,  sy, 0,                  0,
            0,  0,  vp.max_z - vp.min_z, 0,
            ox, oy, vp.min_z,           1
        };
        MulMat4(wvp, vpm, full);
        TransposeMat4(full, dc.wvp);
        TransposeMat4(wv, dc.wv);
        InverseTranspose3x3(wv, n);
        TransposeMat4(n, dc.wvn);

        for (int t = 0; t < 4; ++t) {
            TransposeMat4(s.transforms[16 + t].data(), dc.tm[t]);
            dc.texsize[t][0] = tex_dims[t][0];
            dc.texsize[t][1] = tex_dims[t][1];
            const auto& ts = s.tss[size_t(t)];
            dc.bump[t][0] = f32(ts[kTssBumpEnvMat00]);
            dc.bump[t][1] = f32(ts[kTssBumpEnvMat01]);
            dc.bump[t][2] = f32(ts[kTssBumpEnvMat10]);
            dc.bump[t][3] = f32(ts[kTssBumpEnvMat11]);
            dc.bumpl[t][0] = f32(ts[kTssBumpEnvLScale]);
            dc.bumpl[t][1] = f32(ts[kTssBumpEnvLOffset]);
        }

        std::memcpy(dc.mat, s.material.data(), sizeof(float) * 16);
        dc.mat[4][0] = s.material[16];
        unpack_c(s.rs[kRsAmbient], dc.amb);
        const float* vm = s.transforms[2].data();
        for (int i = 0; i < 8; ++i) {
            if (!((fk.types >> (i * 2)) & 3)) continue;
            float f[26];
            std::memcpy(f, s.lights[size_t(i)].data(), sizeof(f));
            for (int j = 0; j < 4; ++j) {
                dc.lt[i][0][j] = f[1 + j];
                dc.lt[i][1][j] = f[5 + j];
                dc.lt[i][2][j] = f[9 + j];
            }
            const float* pos = f + 13;
            const float* dir = f + 16;
            for (int j = 0; j < 3; ++j) {
                dc.lt[i][3][j] = pos[0] * vm[j] + pos[1] * vm[4 + j] + pos[2] * vm[8 + j] + vm[12 + j];
                dc.lt[i][4][j] = dir[0] * vm[j] + dir[1] * vm[4 + j] + dir[2] * vm[8 + j];
            }
            dc.lt[i][3][3] = f[19];
            dc.lt[i][4][3] = f[20];
            dc.lt[i][5][0] = f[21];
            dc.lt[i][5][1] = f[22];
            dc.lt[i][5][2] = f[23];
            dc.lt[i][6][0] = std::cos(f[24] * 0.5f);
            dc.lt[i][6][1] = std::cos(f[25] * 0.5f);
        }
    }

    id<MTLRenderPipelineState> GetPipeline(uint64_t vs_hash, uint64_t ps_hash,
                                           id<MTLFunction> vs, id<MTLFunction> fs,
                                           bool blend, uint32_t src_b, uint32_t dst_b,
                                           uint32_t blend_op, MTLColorWriteMask write_mask) {
        const uint64_t state_bits = (uint64_t(blend) << 56) |
                                    (uint64_t(write_mask & 0xF) << 48) |
                                    (uint64_t(blend_op & 0xFFFF) << 32) |
                                    (uint64_t(src_b & 0xFFFF) << 16) |
                                    uint64_t(dst_b & 0xFFFF);
        const uint64_t key = vs_hash ^ (ps_hash * 0x9E3779B97F4A7C15ull) ^ (state_bits * 0xBF58476D1CE4E5B9ull);
        if (auto it = pso_cache_.find(key); it != pso_cache_.end()) return it->second;

        MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.vertexFunction = vs;
        desc.fragmentFunction = fs;
        desc.vertexDescriptor = vertex_desc_;
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        desc.colorAttachments[0].writeMask = write_mask;
        desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        if (blend) {
            const MTLBlendOperation op = ToMetalBlendOp(blend_op);
            desc.colorAttachments[0].blendingEnabled = YES;
            desc.colorAttachments[0].rgbBlendOperation = op;
            desc.colorAttachments[0].alphaBlendOperation = op;
            desc.colorAttachments[0].sourceRGBBlendFactor = ToMetalBlend(src_b, false);
            desc.colorAttachments[0].destinationRGBBlendFactor = ToMetalBlend(dst_b, false);
            desc.colorAttachments[0].sourceAlphaBlendFactor = ToMetalBlend(src_b, true);
            desc.colorAttachments[0].destinationAlphaBlendFactor = ToMetalBlend(dst_b, true);
        }
        NSError* err = nil;
        id<MTLRenderPipelineState> pso = [device_ newRenderPipelineStateWithDescriptor:desc error:&err];
        if (!pso) {
            LOGE("metal: pipeline creation failed: %s", [[err localizedDescription] UTF8String]);
            return nil;
        }
        pso_cache_[key] = pso;
        return pso;
    }

    id<MTLDepthStencilState> GetDepthStencil(bool z_en, bool z_wr, uint32_t z_fn) {
        const uint32_t key = (uint32_t(z_en) << 17) | (uint32_t(z_wr) << 16) | (z_fn & 0xFFFF);
        if (auto it = dss_cache_.find(key); it != dss_cache_.end()) return it->second;

        MTLDepthStencilDescriptor* desc = [[MTLDepthStencilDescriptor alloc] init];
        desc.depthCompareFunction = z_en ? ToMetalCompare(z_fn) : MTLCompareFunctionAlways;
        desc.depthWriteEnabled = (z_en && z_wr) ? YES : NO;
        id<MTLDepthStencilState> dss = [device_ newDepthStencilStateWithDescriptor:desc];
        dss_cache_[key] = dss;
        return dss;
    }

    static void DecompressBcBlockColor(const uint8_t* blk, uint8_t c[4][4], bool bc1_alpha) {
        uint16_t c0 = uint16_t(blk[0]) | (uint16_t(blk[1]) << 8);
        uint16_t c1 = uint16_t(blk[2]) | (uint16_t(blk[3]) << 8);
        auto rgb565 = [](uint16_t v, uint8_t out[4]) {
            uint8_t r = uint8_t((v >> 11) & 31);
            uint8_t g = uint8_t((v >> 5) & 63);
            uint8_t b = uint8_t(v & 31);
            out[0] = uint8_t((b << 3) | (b >> 2));
            out[1] = uint8_t((g << 2) | (g >> 4));
            out[2] = uint8_t((r << 3) | (r >> 2));
            out[3] = 255;
        };
        rgb565(c0, c[0]);
        rgb565(c1, c[1]);
        if (c0 > c1 || !bc1_alpha) {
            for (int i = 0; i < 3; ++i) {
                c[2][i] = uint8_t((2 * c[0][i] + c[1][i] + 1) / 3);
                c[3][i] = uint8_t((c[0][i] + 2 * c[1][i] + 1) / 3);
            }
            c[2][3] = c[3][3] = 255;
        } else {
            for (int i = 0; i < 3; ++i) c[2][i] = uint8_t((c[0][i] + c[1][i]) / 2);
            c[2][3] = 255;
            c[3][0] = c[3][1] = c[3][2] = c[3][3] = 0;
        }
    }

    static void DecompressBcToBgra8(gpu::Host host, uint32_t w, uint32_t h, const uint8_t* src,
                                    std::vector<uint8_t>& out, uint32_t& pitch) {
        pitch = w * 4;
        out.assign(size_t(pitch) * h, 0);
        const uint32_t bw = std::max(1u, (w + 3) / 4);
        const uint32_t bh = std::max(1u, (h + 3) / 4);
        const uint32_t blk_bytes = (host == gpu::Host::BC1) ? 8 : 16;
        for (uint32_t by = 0; by < bh; ++by) {
            for (uint32_t bx = 0; bx < bw; ++bx) {
                const uint8_t* blk = src + (size_t(by) * bw + bx) * blk_bytes;
                const uint8_t* cblk = (host == gpu::Host::BC1) ? blk : (blk + 8);
                uint8_t pal[4][4];
                DecompressBcBlockColor(cblk, pal, host == gpu::Host::BC1);
                uint32_t lut = uint32_t(cblk[4]) | (uint32_t(cblk[5]) << 8) |
                               (uint32_t(cblk[6]) << 16) | (uint32_t(cblk[7]) << 24);
                uint8_t a_pal[8] = {};
                uint64_t a_lut = 0;
                if (host == gpu::Host::BC3) {
                    a_pal[0] = blk[0];
                    a_pal[1] = blk[1];
                    if (a_pal[0] > a_pal[1]) {
                        for (int i = 1; i <= 6; ++i)
                            a_pal[i + 1] = uint8_t(((7 - i) * a_pal[0] + i * a_pal[1] + 3) / 7);
                    } else {
                        for (int i = 1; i <= 4; ++i)
                            a_pal[i + 1] = uint8_t(((5 - i) * a_pal[0] + i * a_pal[1] + 2) / 5);
                        a_pal[6] = 0;
                        a_pal[7] = 255;
                    }
                    for (int i = 0; i < 6; ++i) a_lut |= uint64_t(blk[2 + i]) << (i * 8);
                }
                for (uint32_t py = 0; py < 4; ++py) {
                    const uint32_t y = by * 4 + py;
                    if (y >= h) continue;
                    for (uint32_t px = 0; px < 4; ++px) {
                        const uint32_t x = bx * 4 + px;
                        if (x >= w) continue;
                        const uint32_t idx = py * 4 + px;
                        uint8_t* dst = &out[(size_t(y) * w + x) * 4];
                        const uint8_t* c = pal[(lut >> (idx * 2)) & 3];
                        dst[0] = c[0];
                        dst[1] = c[1];
                        dst[2] = c[2];
                        if (host == gpu::Host::BC1) {
                            dst[3] = c[3];
                        } else if (host == gpu::Host::BC2) {
                            const uint8_t a4 = (blk[idx >> 1] >> ((idx & 1) * 4)) & 0xF;
                            dst[3] = uint8_t((a4 << 4) | a4);
                        } else {
                            dst[3] = a_pal[(a_lut >> (idx * 3)) & 7];
                        }
                    }
                }
            }
        }
    }

    id<MTLTexture> ResolveTexture(uint32_t header_va, uint32_t palette_va, uint32_t simple_palette,
                                  TextureDesc* out_desc = nullptr) {
        TextureDesc d;
        if (!Describe(header_va, d) || !d.data || !d.width || !d.height) return nil;
        if (out_desc) *out_desc = d;
        const auto& fi = Format(d.format);
        const bool is_bc = (fi.host == gpu::Host::BC1 || fi.host == gpu::Host::BC2 || fi.host == gpu::Host::BC3);
        if (!is_bc && (offscreen_rt_data_.find(d.data) != offscreen_rt_data_.end() ||
                       main_rt_data_.find(d.data) != main_rt_data_.end())) {
            // Unrendered offscreen render targets or swapchain backbuffers sampled by bloom/blur/reflection passes
            // have no GPU render target backing in this simplified backend; return transparent black so additive
            // post-process passes contribute 0 instead of solid white or uninitialized diagonal stripes.
            return black_tex_;
        }
        MTLPixelFormat mtl_fmt = MTLPixelFormatBGRA8Unorm;
        if (fi.host == gpu::Host::R32F) mtl_fmt = MTLPixelFormatR32Float;
        else if (fi.host == gpu::Host::R16Unorm) mtl_fmt = MTLPixelFormatR16Unorm;
        else if (fi.host != gpu::Host::BGRA8 && !is_bc) return nil;

        constexpr uint32_t kFmtP8 = 0x0B;
        uint32_t pal_data_va = 0;
        if (d.format == kFmtP8) {
            if (palette_va) {
                pal_data_va = mem::VirtualFromPhysical(kernel::R32(palette_va + 4));
            } else if (simple_palette) {
                pal_data_va = mem::VirtualFromPhysical(simple_palette & ~0x3Fu);
            }
        }

        const uint8_t* guest = static_cast<const uint8_t*>(kernel::HostPtr(d.data));
        uint64_t epoch = DirtyEpoch(d.data);
        if (d.linear && !is_bc) {
            // Sample a few locations of linear textures (e.g. Bink YUY2 video frames) so in-place CPU updates
            // are detected even when updated without Lock/BlockUntilNotBusy, and skip uninitialized 0x00/0xFF frames.
            const uint32_t total = d.pitch * d.height;
            if (total >= 64) {
                const uint64_t s0 = Hash(guest, 64);
                const uint64_t s1 = Hash(guest + total / 2, std::min<uint32_t>(64, total - total / 2));
                epoch ^= s0 ^ (s1 * 0x9E3779B97F4A7C15ull);
            }
        }
        const uint64_t cache_key = (uint64_t(pal_data_va) << 32) | d.data;
        auto& entry = tex_cache_[cache_key];
        if (entry.tex && entry.format == d.format && entry.w == d.width && entry.h == d.height &&
            entry.epoch == epoch) {
            return entry.tex;
        }

        const uint32_t* pal = pal_data_va ? static_cast<const uint32_t*>(kernel::HostPtr(pal_data_va)) : nullptr;
        std::vector<uint8_t> decoded;
        uint32_t pitch = 0;
        DecodeLevel(d, 0, 0, guest, pal, decoded, pitch);
        if (decoded.empty() || !pitch) return nil;
        if (is_bc) {
            std::vector<uint8_t> bgra;
            uint32_t bgra_pitch = 0;
            DecompressBcToBgra8(fi.host, d.width, d.height, decoded.data(), bgra, bgra_pitch);
            decoded = std::move(bgra);
            pitch = bgra_pitch;
        } else if (d.format == 0x24 || d.format == 0x25) {
            // Guard against uninitialized YUY2/UYVY buffers before Bink decodes its first frame.
            // Check 4 sample dwords across the frame; if uniform (e.g. all 0x00, 0xFF, or repeating fill),
            // or if Y/U/V bytes are outside valid video fill, black out the frame to avoid neon pink/green flash.
            const uint32_t total = d.pitch * d.height;
            if (total >= 64) {
                uint32_t dw0 = 0, dw1 = 0, dw2 = 0, dw3 = 0;
                std::memcpy(&dw0, guest + 0, 4);
                std::memcpy(&dw1, guest + ((total / 3) & ~3u), 4);
                std::memcpy(&dw2, guest + ((total / 2) & ~3u), 4);
                std::memcpy(&dw3, guest + (((total * 2) / 3) & ~3u), 4);
                if (dw0 == dw1 && dw1 == dw2 && dw2 == dw3 &&
                    (dw0 == 0u || dw0 == 0xFFFFFFFFu || (dw0 & 0xFFFFu) == (dw0 >> 16))) {
                    for (size_t i = 0; i + 3 < decoded.size(); i += 4) {
                        decoded[i + 0] = 0;
                        decoded[i + 1] = 0;
                        decoded[i + 2] = 0;
                        decoded[i + 3] = 255;
                    }
                }
            }
        }

        MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:mtl_fmt
                                                                                      width:d.width
                                                                                     height:d.height
                                                                                  mipmapped:NO];
        id<MTLTexture> tex = [device_ newTextureWithDescriptor:td];
        if (!tex) return nil;
        [tex replaceRegion:MTLRegionMake2D(0, 0, d.width, d.height)
               mipmapLevel:0
                 withBytes:decoded.data()
               bytesPerRow:pitch];
        entry = {tex, d.format, d.width, d.height, epoch};
        return tex;
    }

    bool EnsureEncoder() {
        if (encoder_) return true;
        drawable_ = [layer_ nextDrawable];
        if (!drawable_) return false;
        const NSUInteger dw = drawable_.texture.width;
        const NSUInteger dh = drawable_.texture.height;
        if (!depth_tex_ || depth_tex_.width != dw || depth_tex_.height != dh) {
            MTLTextureDescriptor* dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                          width:dw
                                                                                         height:dh
                                                                                      mipmapped:NO];
            dd.storageMode = MTLStorageModePrivate;
            dd.usage = MTLTextureUsageRenderTarget;
            depth_tex_ = [device_ newTextureWithDescriptor:dd];
        }
        cmd_buf_ = [queue_ commandBuffer];
        if (!cmd_buf_) {
            drawable_ = nil;
            return false;
        }
        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = drawable_.texture;
        // A freshly acquired CAMetalDrawable has undefined contents on iOS TBDR GPUs; always clear at pass start.
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].clearColor = clear_color_;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        if (depth_tex_) {
            pass.depthAttachment.texture = depth_tex_;
            pass.depthAttachment.loadAction = MTLLoadActionClear;
            pass.depthAttachment.clearDepth = clear_depth_;
            pass.depthAttachment.storeAction = MTLStoreActionDontCare;
        }
        encoder_ = [cmd_buf_ renderCommandEncoderWithDescriptor:pass];
        if (!encoder_) {
            cmd_buf_ = nil;
            drawable_ = nil;
            return false;
        }
        return true;
    }

    uint32_t guest_width_ = 640;
    uint32_t guest_height_ = 480;
    std::unordered_set<uint32_t> main_rt_data_;
    std::unordered_set<uint32_t> offscreen_rt_data_;
    CAMetalLayer* layer_ = nil;
    id<MTLDevice> device_ = nil;
    id<MTLCommandQueue> queue_ = nil;
    id<MTLFunction> vs_func_ = nil;
    id<MTLFunction> fs_func_ = nil;
    MTLVertexDescriptor* vertex_desc_ = nil;
    id<MTLRenderPipelineState> pipeline_ = nil;
    id<MTLTexture> white_tex_ = nil;
    id<MTLTexture> black_tex_ = nil;
    id<MTLTexture> depth_tex_ = nil;
    id<MTLSamplerState> sampler_ = nil;
    id<MTLSamplerState> wrap_sampler_ = nil;
    std::unordered_map<uint64_t, id<MTLRenderPipelineState>> pso_cache_;
    std::unordered_map<uint64_t, id<MTLFunction>> vs_cache_;
    std::unordered_map<uint64_t, id<MTLFunction>> fs_cache_;
    std::unordered_set<uint64_t> failed_shaders_;
    std::unordered_map<uint32_t, id<MTLDepthStencilState>> dss_cache_;
    std::unordered_map<uint64_t, CachedTex> tex_cache_;

    id<CAMetalDrawable> drawable_ = nil;
    id<MTLCommandBuffer> cmd_buf_ = nil;
    id<MTLRenderCommandEncoder> encoder_ = nil;
    id<MTLCommandBuffer> last_cmd_buf_ = nil;
    MTLClearColor clear_color_ = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    double clear_depth_ = 1.0;
    bool has_clear_ = true;
    bool has_depth_clear_ = true;
};

}  // namespace

void SetMetalLayer(void* ca_metal_layer) {
    g_metal_layer = (__bridge CAMetalLayer*)ca_metal_layer;
}

std::unique_ptr<Backend> CreateBackend() {
    return std::make_unique<MetalBackend>();
}

}  // namespace gpu
