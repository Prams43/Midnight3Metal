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
    float v[16][4];
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

static const char* kMetalBlitShader = R"(
#include <metal_stdlib>
using namespace metal;

struct BlitOut {
    float4 position [[position]];
    float2 uv;
};

vertex BlitOut blit_vs(uint vid [[vertex_id]]) {
    float2 pos[3] = { float2(-1.0f, -1.0f), float2(3.0f, -1.0f), float2(-1.0f, 3.0f) };
    float2 uv[3]  = { float2(0.0f, 1.0f),   float2(2.0f, 1.0f),  float2(0.0f, -1.0f) };
    BlitOut o;
    o.position = float4(pos[vid], 0.0f, 1.0f);
    o.uv = uv[vid];
    return o;
}

fragment float4 blit_fs_opaque(BlitOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]],
                               sampler smp [[sampler(0)]]) {
    float4 c = tex.sample(smp, in.uv);
    return float4(c.rgb, 1.0f);
}

fragment float4 blit_fs_rgba(BlitOut in [[stage_in]],
                             texture2d<float> tex [[texture(0)]],
                             sampler smp [[sampler(0)]]) {
    return tex.sample(smp, in.uv);
}

vertex float4 clear_vs(uint vid [[vertex_id]], constant float& depth_z [[buffer(0)]]) {
    float2 pos[3] = { float2(-1.0f, -1.0f), float2(3.0f, -1.0f), float2(-1.0f, 3.0f) };
    return float4(pos[vid], depth_z, 1.0f);
}

fragment float4 clear_fs(constant float4& col [[buffer(0)]]) {
    return col;
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
        for (NSUInteger idx = 0; idx < 16; ++idx) {
            vd.attributes[idx].format = MTLVertexFormatFloat4;
            vd.attributes[idx].offset = idx * sizeof(float) * 4;
            vd.attributes[idx].bufferIndex = 0;
        }
        vd.layouts[0].stride = sizeof(MetalVertex);
        vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

        vertex_desc_ = vd;
        vs_func_ = vs;
        fs_func_ = fs;

        pipeline_ = GetPipeline(0, 0, vs_func_, fs_func_, false, 1, 0, 0, MTLColorWriteMaskAll);
        if (!pipeline_) return false;

        // Fullscreen blit and masked/sub-rect clear pipelines
        id<MTLLibrary> blitLib = [device_ newLibraryWithSource:@(kMetalBlitShader) options:nil error:&err];
        if (!blitLib) {
            LOGE("metal: blit shader compile failed: %s", [[err localizedDescription] UTF8String]);
            return false;
        }
        id<MTLFunction> blitVs = [blitLib newFunctionWithName:@"blit_vs"];
        id<MTLFunction> blitFsOpaque = [blitLib newFunctionWithName:@"blit_fs_opaque"];
        id<MTLFunction> blitFsRgba = [blitLib newFunctionWithName:@"blit_fs_rgba"];
        clear_vs_ = [blitLib newFunctionWithName:@"clear_vs"];
        clear_fs_ = [blitLib newFunctionWithName:@"clear_fs"];
        if (blitVs && blitFsOpaque && blitFsRgba) {
            MTLRenderPipelineDescriptor* bd = [[MTLRenderPipelineDescriptor alloc] init];
            bd.vertexFunction = blitVs;
            bd.fragmentFunction = blitFsOpaque;
            bd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            blit_present_pso_ = [device_ newRenderPipelineStateWithDescriptor:bd error:&err];
            bd.fragmentFunction = blitFsRgba;
            blit_copy_pso_ = [device_ newRenderPipelineStateWithDescriptor:bd error:&err];
        }

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

    static bool IsDepthSurface(const Surface& s) {
        if (!s.header) return false;
        return Format((s.format >> 8) & 0xFF).depth;
    }

    void Clear(const State& s, uint32_t count, const uint8_t* rects, uint32_t flags, uint32_t color, float z, uint32_t) override {
        const uint32_t mask = (flags & kClearTarget) >> 4;  // bit 0=R, 1=G, 2=B, 3=A
        const bool clear_c = (mask != 0) && !IsDepthSurface(s.rt);
        const bool clear_z = (flags & kClearZ) != 0;
        if (!clear_c && !clear_z) return;
        @autoreleasepool {
            const uint32_t rt_va = s.rt.header ? mem::VirtualFromPhysical(s.rt.data) : 0u;
            const uint32_t zs_va = s.zs.header ? mem::VirtualFromPhysical(s.zs.data) : rt_va;
            uint32_t w = 0, h = 0;
            if (s.rt.header) SurfaceSize(s.rt, w, h);
            else if (s.zs.header) SurfaceSize(s.zs, w, h);
            if (!w) w = guest_width_;
            if (!h) h = guest_height_;

            std::vector<MTLScissorRect> rs;
            auto add_rect = [&](int32_t x0, int32_t y0, int32_t x1, int32_t y1) {
                const int32_t cx0 = std::clamp<int32_t>(x0, 0, int32_t(w));
                const int32_t cy0 = std::clamp<int32_t>(y0, 0, int32_t(h));
                const int32_t cx1 = std::clamp<int32_t>(x1, 0, int32_t(w));
                const int32_t cy1 = std::clamp<int32_t>(y1, 0, int32_t(h));
                if (cx1 > cx0 && cy1 > cy0) {
                    rs.push_back(MTLScissorRect{
                        NSUInteger(cx0), NSUInteger(cy0),
                        NSUInteger(cx1 - cx0), NSUInteger(cy1 - cy0)
                    });
                }
            };
            if (count > 0 && rects != nullptr) {
                for (uint32_t i = 0; i < count; ++i) {
                    int32_t r[4];
                    std::memcpy(r, rects + size_t(i) * sizeof(r), sizeof(r));
                    add_rect(r[0], r[1], r[2], r[3]);
                }
            } else if (s.viewport.w && s.viewport.h) {
                add_rect(int32_t(s.viewport.x), int32_t(s.viewport.y),
                         int32_t(s.viewport.x + s.viewport.w), int32_t(s.viewport.y + s.viewport.h));
            } else {
                add_rect(0, 0, int32_t(w), int32_t(h));
            }
            if (rs.empty()) return;

            const bool full_rect = (rs.size() == 1 && rs[0].x == 0 && rs[0].y == 0 &&
                                    rs[0].width == w && rs[0].height == h);
            const float r_f = ((color >> 16) & 0xFF) / 255.0f;
            const float g_f = ((color >> 8) & 0xFF) / 255.0f;
            const float b_f = (color & 0xFF) / 255.0f;
            const float a_f = ((color >> 24) & 0xFF) / 255.0f;
            const float depth_z = std::clamp(z, 0.0f, 1.0f);
            bool handled_z = false;

            if (clear_c) {
                auto& ct = EnsureColorTarget(rt_va, w, h);
                if (full_rect && mask == 0xF) {
                    ct.clear_color = MTLClearColorMake(r_f, g_f, b_f, a_f);
                    ct.pending_clear = true;
                    ct.drawn = true;
                    last_rt_va_ = rt_va;
                    if (encoder_ && active_color_tex_ == ct.tex) EndEncoder();
                } else {
                    // Masked channel clear (e.g. MC3 minimap alpha-only 0x80) or sub-rect clear:
                    // preserve existing contents outside the mask/rects instead of wiping the whole screen!
                    if (ct.pending_clear) FlushColorClear(ct);
                    const bool also_z = clear_z && !full_rect;
                    id<MTLRenderPipelineState> pso = GetClearPipeline(mask, also_z);
                    if (pso && ct.tex) {
                        EndEncoder();
                        if (EnsureCommandBuffer()) {
                            MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
                            pass.colorAttachments[0].texture = ct.tex;
                            pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
                            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                            if (also_z) {
                                auto& dt = EnsureDepthTarget(zs_va, w, h);
                                pass.depthAttachment.texture = dt.tex;
                                pass.depthAttachment.loadAction = dt.pending_clear ? MTLLoadActionClear : MTLLoadActionLoad;
                                pass.depthAttachment.clearDepth = dt.clear_depth;
                                pass.depthAttachment.storeAction = MTLStoreActionStore;
                                dt.pending_clear = false;
                            }
                            id<MTLRenderCommandEncoder> enc = [cmd_buf_ renderCommandEncoderWithDescriptor:pass];
                            if (enc) {
                                [enc setRenderPipelineState:pso];
                                if (also_z) {
                                    id<MTLDepthStencilState> dss = GetDepthStencil(true, true, 8 /* ALWAYS */);
                                    if (dss) [enc setDepthStencilState:dss];
                                }
                                float col4[4] = {r_f, g_f, b_f, a_f};
                                [enc setVertexBytes:&depth_z length:sizeof(depth_z) atIndex:0];
                                [enc setFragmentBytes:col4 length:sizeof(col4) atIndex:0];
                                for (const auto& sc : rs) {
                                    [enc setScissorRect:sc];
                                    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                                }
                                [enc endEncoding];
                            }
                            ct.drawn = true;
                            if (also_z) handled_z = true;
                        }
                    }
                }
            }

            if (clear_z && !handled_z) {
                auto& dt = EnsureDepthTarget(zs_va, w, h);
                if (full_rect) {
                    dt.clear_depth = double(depth_z);
                    dt.pending_clear = true;
                    if (encoder_ && active_depth_tex_ == dt.tex) EndEncoder();
                } else {
                    auto& ct = EnsureColorTarget(rt_va, w, h);
                    if (ct.pending_clear) FlushColorClear(ct);
                    id<MTLRenderPipelineState> pso = GetClearPipeline(0 /* no color writes */, true);
                    if (pso && ct.tex && dt.tex) {
                        EndEncoder();
                        if (EnsureCommandBuffer()) {
                            MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
                            pass.colorAttachments[0].texture = ct.tex;
                            pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
                            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                            pass.depthAttachment.texture = dt.tex;
                            pass.depthAttachment.loadAction = dt.pending_clear ? MTLLoadActionClear : MTLLoadActionLoad;
                            pass.depthAttachment.clearDepth = dt.clear_depth;
                            pass.depthAttachment.storeAction = MTLStoreActionStore;
                            dt.pending_clear = false;
                            id<MTLRenderCommandEncoder> enc = [cmd_buf_ renderCommandEncoderWithDescriptor:pass];
                            if (enc) {
                                [enc setRenderPipelineState:pso];
                                id<MTLDepthStencilState> dss = GetDepthStencil(true, true, 8 /* ALWAYS */);
                                if (dss) [enc setDepthStencilState:dss];
                                float col4[4] = {0, 0, 0, 0};
                                [enc setVertexBytes:&depth_z length:sizeof(depth_z) atIndex:0];
                                [enc setFragmentBytes:col4 length:sizeof(col4) atIndex:0];
                                for (const auto& sc : rs) {
                                    [enc setScissorRect:sc];
                                    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                                }
                                [enc endEncoding];
                            }
                        }
                    }
                }
            }
        }
    }

    void Draw(const State& s, uint32_t prim, uint32_t start, uint32_t count, const uint8_t* indices) override {
        if (!pipeline_ || !layer_) return;
        if (IsDepthSurface(s.rt)) return;
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

        const uint32_t rt_va = s.rt.header ? mem::VirtualFromPhysical(s.rt.data) : 0u;
        const uint32_t zs_va = s.zs.header ? mem::VirtualFromPhysical(s.zs.data) : rt_va;
        uint32_t target_w = 0, target_h = 0;
        if (s.rt.header) SurfaceSize(s.rt, target_w, target_h);
        if (!target_w) target_w = guest_width_;
        if (!target_h) target_h = guest_height_;

        // Resolve textures & TexInfo for all 4 stages
        id<MTLTexture> stage_tex[4] = { white_tex_, white_tex_, white_tex_, white_tex_ };
        id<MTLSamplerState> stage_smp[4] = { sampler_, sampler_, sampler_, sampler_ };
        TexInfo tex_info[4]{};
        float tex_dims[4][2] = {{1.0f, 1.0f}, {1.0f, 1.0f}, {1.0f, 1.0f}, {1.0f, 1.0f}};
        for (int t = 0; t < 4; ++t) {
            if (s.textures[t]) {
                TextureDesc td{};
                const uint32_t simple_pal = s.simple[(0x1B20 + uint32_t(t) * 0x40) / 4];
                id<MTLTexture> mt = ResolveTexture(s.textures[t], s.palettes[t], simple_pal, rt_va, &td);
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

        // Determine active vertex registers supplied by our full 16-register MetalVertex layout
        constexpr uint16_t kSupportedRegs = 0xFFFFu;
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
        const float inv_w = 2.0f / float(target_w);
        const float inv_h = 2.0f / float(target_h);

        for (uint32_t i = 0; i < a.vertex_count; ++i) {
            float p[4] = {};
            if (!read_attr(0, i, p)) return;
            if (use_translated) {
                // Translated HLSL->MSL vertex shaders expect raw guest positions (fixed or programmable)
                verts[i].v[0][0] = p[0];
                verts[i].v[0][1] = p[1];
                verts[i].v[0][2] = p[2];
                verts[i].v[0][3] = (p[3] != 0.0f) ? p[3] : 1.0f;
            } else if (a.pretransformed) {
                verts[i].v[0][0] = p[0] * inv_w - 1.0f;
                verts[i].v[0][1] = 1.0f - p[1] * inv_h;
                verts[i].v[0][2] = p[2];
                verts[i].v[0][3] = 1.0f;
            } else {
                p[3] = (p[3] != 0.0f) ? p[3] : 1.0f;
                float wv[4], vv[4], pv[4];
                MulMat4Vec4(s.transforms[256].data(), p, wv);
                MulMat4Vec4(s.transforms[2].data(), wv, vv);
                MulMat4Vec4(s.transforms[3].data(), vv, pv);
                verts[i].v[0][0] = pv[0];
                verts[i].v[0][1] = pv[1];
                verts[i].v[0][2] = pv[2];
                verts[i].v[0][3] = pv[3];
            }

            for (int r = 1; r < 16; ++r) {
                if (!read_attr(r, i, verts[i].v[r])) {
                    if (r == 3) {
                        verts[i].v[r][0] = verts[i].v[r][1] = verts[i].v[r][2] = verts[i].v[r][3] = 1.0f;
                    } else if (r == 2) {
                        verts[i].v[r][0] = 0.0f;
                        verts[i].v[r][1] = 0.0f;
                        verts[i].v[r][2] = 1.0f;
                        verts[i].v[r][3] = 0.0f;
                    } else if (r == 4) {
                        verts[i].v[r][0] = verts[i].v[r][1] = verts[i].v[r][2] = verts[i].v[r][3] = 0.0f;
                    } else {
                        verts[i].v[r][0] = 0.0f;
                        verts[i].v[r][1] = 0.0f;
                        verts[i].v[r][2] = 0.0f;
                        verts[i].v[r][3] = 1.0f;
                    }
                }
            }
        }

        if (!EnsureEncoderFor(rt_va, zs_va, target_w, target_h)) return;
        color_rts_[rt_va].drawn = true;
        last_rt_va_ = rt_va;

        if (s.scissor_count > 0) {
            const int32_t sx0 = std::clamp<int32_t>(int32_t(s.scissors[0]), 0, int32_t(target_w));
            const int32_t sy0 = std::clamp<int32_t>(int32_t(s.scissors[1]), 0, int32_t(target_h));
            const int32_t sx1 = std::clamp<int32_t>(int32_t(s.scissors[2]), 0, int32_t(target_w));
            const int32_t sy1 = std::clamp<int32_t>(int32_t(s.scissors[3]), 0, int32_t(target_h));
            if (sx1 <= sx0 || sy1 <= sy0) return;
            [encoder_ setScissorRect:MTLScissorRect{
                NSUInteger(sx0), NSUInteger(sy0),
                NSUInteger(sx1 - sx0), NSUInteger(sy1 - sy0)
            }];
        } else {
            [encoder_ setScissorRect:MTLScissorRect{0, 0, target_w, target_h}];
        }

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
            FillDrawConstants(s, fk, dc, tex_dims, target_w, target_h);
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

    void Copy(const Surface& src, const Surface& dst, uint32_t count, uint32_t src_rects, uint32_t dst_points) override {
        if (!src.header || !dst.header) return;
        const uint32_t src_va = mem::VirtualFromPhysical(src.data);
        const uint32_t dst_va = mem::VirtualFromPhysical(dst.data);
        if (!src_va || !dst_va || src_va == dst_va) return;
        @autoreleasepool {
            auto src_it = color_rts_.find(src_va);
            if (src_it != color_rts_.end() && src_it->second.tex && src_it->second.drawn) {
                if (src_it->second.pending_clear) FlushColorClear(src_it->second);
                uint32_t dw = 0, dh = 0;
                SurfaceSize(dst, dw, dh);
                if (!dw) dw = src_it->second.w;
                if (!dh) dh = src_it->second.h;
                auto& dst_ct = EnsureColorTarget(dst_va, dw, dh);
                EndEncoder();
                if (!EnsureCommandBuffer()) return;
                if (count == 0 && src_it->second.w == dst_ct.w && src_it->second.h == dst_ct.h) {
                    id<MTLBlitCommandEncoder> blit = [cmd_buf_ blitCommandEncoder];
                    if (blit) {
                        [blit copyFromTexture:src_it->second.tex
                                  sourceSlice:0
                                  sourceLevel:0
                                 sourceOrigin:MTLOriginMake(0, 0, 0)
                                   sourceSize:MTLSizeMake(dst_ct.w, dst_ct.h, 1)
                                    toTexture:dst_ct.tex
                             destinationSlice:0
                             destinationLevel:0
                            destinationOrigin:MTLOriginMake(0, 0, 0)];
                        [blit endEncoding];
                    }
                } else if (blit_copy_pso_) {
                    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
                    pass.colorAttachments[0].texture = dst_ct.tex;
                    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
                    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                    id<MTLRenderCommandEncoder> enc = [cmd_buf_ renderCommandEncoderWithDescriptor:pass];
                    if (enc) {
                        [enc setRenderPipelineState:blit_copy_pso_];
                        [enc setFragmentTexture:src_it->second.tex atIndex:0];
                        [enc setFragmentSamplerState:sampler_ atIndex:0];
                        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                        [enc endEncoding];
                    }
                }
                dst_ct.pending_clear = false;
                dst_ct.drawn = true;
                return;
            }
            // CPU-written surface copy in guest memory (e.g. video/splash surfaces)
            if (CopySurfaceMemory(src, dst, count, src_rects, dst_points)) {
                MarkDirty(dst.header);
            }
        }
    }

    void Present(const Surface& front) override {
        if (!layer_ || !queue_) return;
        @autoreleasepool {
            EndEncoder();
            const uint32_t front_va = front.data ? mem::VirtualFromPhysical(front.data) : 0u;
            id<MTLTexture> src_tex = nil;
            if (auto it = color_rts_.find(front_va); it != color_rts_.end() && it->second.tex && it->second.drawn) {
                if (it->second.pending_clear) FlushColorClear(it->second);
                src_tex = it->second.tex;
            } else if (auto it2 = color_rts_.find(last_rt_va_); it2 != color_rts_.end() && it2->second.tex && it2->second.drawn) {
                if (it2->second.pending_clear) FlushColorClear(it2->second);
                src_tex = it2->second.tex;
            }

            id<CAMetalDrawable> drawable = [layer_ nextDrawable];
            if (drawable && EnsureCommandBuffer()) {
                MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
                pass.colorAttachments[0].texture = drawable.texture;
                pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
                pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                id<MTLRenderCommandEncoder> enc = [cmd_buf_ renderCommandEncoderWithDescriptor:pass];
                if (enc) {
                    if (src_tex && blit_present_pso_) {
                        [enc setRenderPipelineState:blit_present_pso_];
                        [enc setFragmentTexture:src_tex atIndex:0];
                        [enc setFragmentSamplerState:sampler_ atIndex:0];
                        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                    }
                    [enc endEncoding];
                }
                [cmd_buf_ presentDrawable:drawable];
            }
            if (cmd_buf_) {
                [cmd_buf_ commit];
                last_cmd_buf_ = cmd_buf_;
                cmd_buf_ = nil;
            }
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

    void FillDrawConstants(const State& s, const FixedKey& fk, DrawConstants& dc, const float tex_dims[4][2],
                           uint32_t target_w, uint32_t target_h) {
        const float gw = float(target_w ? target_w : guest_width_);
        const float gh = float(target_h ? target_h : guest_height_);
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
        const float vw = vp.w ? float(vp.w) : gw;
        const float vh = vp.h ? float(vp.h) : gh;
        const float sx = vw / gw;
        const float sy = vh / gh;
        const float ox = (2.0f * vp.x + vw) / gw - 1.0f;
        const float oy = 1.0f - (2.0f * vp.y + vh) / gh;
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

    id<MTLRenderPipelineState> GetClearPipeline(uint32_t mask, bool with_depth) {
        const uint32_t key = (mask & 0xFu) | (with_depth ? 0x10u : 0u);
        if (auto it = clear_pso_cache_.find(key); it != clear_pso_cache_.end()) return it->second;
        if (!clear_vs_ || !clear_fs_) return nil;
        MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.vertexFunction = clear_vs_;
        desc.fragmentFunction = clear_fs_;
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        MTLColorWriteMask wm = MTLColorWriteMaskNone;
        if (mask & 1u) wm |= MTLColorWriteMaskRed;
        if (mask & 2u) wm |= MTLColorWriteMaskGreen;
        if (mask & 4u) wm |= MTLColorWriteMaskBlue;
        if (mask & 8u) wm |= MTLColorWriteMaskAlpha;
        desc.colorAttachments[0].writeMask = wm;
        if (with_depth) desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        NSError* err = nil;
        id<MTLRenderPipelineState> pso = [device_ newRenderPipelineStateWithDescriptor:desc error:&err];
        if (!pso) {
            LOGE("metal: clear pipeline creation failed: %s", [[err localizedDescription] UTF8String]);
            return nil;
        }
        clear_pso_cache_[key] = pso;
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

    struct ColorTarget {
        id<MTLTexture> tex = nil;
        uint32_t w = 0, h = 0;
        bool pending_clear = true;
        MTLClearColor clear_color = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
        bool drawn = false;
    };

    struct DepthTarget {
        id<MTLTexture> tex = nil;
        uint32_t w = 0, h = 0;
        bool pending_clear = true;
        double clear_depth = 1.0;
    };

    ColorTarget& EnsureColorTarget(uint32_t rt_va, uint32_t w, uint32_t h) {
        if (!w) w = guest_width_;
        if (!h) h = guest_height_;
        auto& ct = color_rts_[rt_va];
        if (!ct.tex || ct.w != w || ct.h != h) {
            MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:w
                                                                                         height:h
                                                                                      mipmapped:NO];
            td.storageMode = MTLStorageModePrivate;
            td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            ct.tex = [device_ newTextureWithDescriptor:td];
            ct.w = w;
            ct.h = h;
            ct.pending_clear = true;
            ct.clear_color = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
            ct.drawn = false;
        }
        return ct;
    }

    DepthTarget& EnsureDepthTarget(uint32_t zs_va, uint32_t w, uint32_t h) {
        if (!w) w = guest_width_;
        if (!h) h = guest_height_;
        const uint64_t key = (uint64_t(zs_va) << 32) | (uint64_t(w & 0xFFFFu) << 16) | uint64_t(h & 0xFFFFu);
        auto& dt = depth_rts_[key];
        if (!dt.tex || dt.w != w || dt.h != h) {
            MTLTextureDescriptor* dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                          width:w
                                                                                         height:h
                                                                                      mipmapped:NO];
            dd.storageMode = MTLStorageModePrivate;
            dd.usage = MTLTextureUsageRenderTarget;
            dt.tex = [device_ newTextureWithDescriptor:dd];
            dt.w = w;
            dt.h = h;
            dt.pending_clear = true;
            dt.clear_depth = 1.0;
        }
        return dt;
    }

    void EndEncoder() {
        if (encoder_) {
            [encoder_ endEncoding];
            encoder_ = nil;
            active_color_tex_ = nil;
            active_depth_tex_ = nil;
        }
    }

    bool EnsureCommandBuffer() {
        if (cmd_buf_) return true;
        cmd_buf_ = [queue_ commandBuffer];
        return cmd_buf_ != nil;
    }

    void FlushColorClear(ColorTarget& ct) {
        if (!ct.pending_clear || !ct.tex) return;
        EndEncoder();
        if (!EnsureCommandBuffer()) return;
        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = ct.tex;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].clearColor = ct.clear_color;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [cmd_buf_ renderCommandEncoderWithDescriptor:pass];
        if (enc) [enc endEncoding];
        ct.pending_clear = false;
    }

    id<MTLTexture> CopyToFeedback(id<MTLTexture> src) {
        if (!src) return black_tex_;
        const NSUInteger w = src.width, h = src.height;
        if (!feedback_tex_ || feedback_tex_.width != w || feedback_tex_.height != h) {
            MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:w
                                                                                         height:h
                                                                                      mipmapped:NO];
            td.storageMode = MTLStorageModePrivate;
            td.usage = MTLTextureUsageShaderRead;
            feedback_tex_ = [device_ newTextureWithDescriptor:td];
        }
        if (!feedback_tex_) return black_tex_;
        EndEncoder();
        if (!EnsureCommandBuffer()) return black_tex_;
        id<MTLBlitCommandEncoder> blit = [cmd_buf_ blitCommandEncoder];
        if (blit) {
            [blit copyFromTexture:src
                      sourceSlice:0
                      sourceLevel:0
                     sourceOrigin:MTLOriginMake(0, 0, 0)
                       sourceSize:MTLSizeMake(w, h, 1)
                        toTexture:feedback_tex_
                 destinationSlice:0
                 destinationLevel:0
                destinationOrigin:MTLOriginMake(0, 0, 0)];
            [blit endEncoding];
        }
        return feedback_tex_;
    }

    id<MTLTexture> ResolveTexture(uint32_t header_va, uint32_t palette_va, uint32_t simple_palette,
                                  uint32_t current_rt_va, TextureDesc* out_desc = nullptr) {
        TextureDesc d;
        if (!Describe(header_va, d) || !d.data || !d.width || !d.height) return nil;
        if (out_desc) *out_desc = d;
        const auto& fi = Format(d.format);
        const bool is_bc = (fi.host == gpu::Host::BC1 || fi.host == gpu::Host::BC2 || fi.host == gpu::Host::BC3);
        if (!is_bc) {
            if (auto it = color_rts_.find(d.data); it != color_rts_.end() && it->second.tex && it->second.drawn) {
                if (it->second.pending_clear) FlushColorClear(it->second);
                if (d.data == current_rt_va) {
                    return CopyToFeedback(it->second.tex);
                }
                if (encoder_ && active_color_tex_ == it->second.tex) {
                    EndEncoder();
                }
                return it->second.tex;
            }
        }
        MTLPixelFormat mtl_fmt = MTLPixelFormatBGRA8Unorm;
        if (fi.host == gpu::Host::R32F) mtl_fmt = MTLPixelFormatR32Float;
        else if (fi.host == gpu::Host::R16Unorm) mtl_fmt = MTLPixelFormatR16Unorm;
        else if (fi.host != gpu::Host::BGRA8 && !is_bc) return nil;

        constexpr uint32_t kFmtP8 = 0x0B;
        uint32_t pal_data_va = 0;
        uint32_t pal_buf[256] = {};
        uint64_t pal_hash = 0;
        if (d.format == kFmtP8) {
            size_t pal_bytes = sizeof(pal_buf);
            if (palette_va) {
                pal_data_va = mem::VirtualFromPhysical(kernel::R32(palette_va + 4));
                const uint32_t size_code = (kernel::R32(palette_va) >> 30) & 3u;
                pal_bytes = (256u >> size_code) * sizeof(uint32_t);
            } else if (simple_palette) {
                pal_data_va = mem::VirtualFromPhysical(simple_palette & ~0x3Fu);
            }
            if (pal_data_va) {
                std::memcpy(pal_buf, kernel::HostPtr(pal_data_va), pal_bytes);
                pal_hash = Hash(pal_buf, sizeof(pal_buf));
            }
        }

        const uint8_t* guest = static_cast<const uint8_t*>(kernel::HostPtr(d.data));
        uint64_t epoch = DirtyEpoch(d.data) ^ (pal_hash * 0xBF58476D1CE4E5B9ull);
        if (d.linear && !is_bc) {
            // Sample 4 locations of linear textures (e.g. Bink YUY2 video frames) so in-place CPU updates
            // are detected even when updated without Lock/BlockUntilNotBusy.
            const uint32_t total = d.pitch * d.height;
            if (total >= 64) {
                const uint64_t s0 = Hash(guest, 64);
                const uint64_t s1 = Hash(guest + total / 3, std::min<uint32_t>(64, total - total / 3));
                const uint64_t s2 = Hash(guest + total / 2, std::min<uint32_t>(64, total - total / 2));
                const uint64_t s3 = Hash(guest + (total * 2) / 3, std::min<uint32_t>(64, total - (total * 2) / 3));
                epoch ^= s0 ^ (s1 * 0x9E3779B97F4A7C15ull) ^ (s2 * 0xBF58476D1CE4E5B9ull) ^ (s3 * 0x94D049BB133111EBull);
            }
        }
        const uint64_t cache_key = (uint64_t(pal_data_va) << 32) | d.data;
        auto& entry = tex_cache_[cache_key];
        if (entry.tex && entry.format == d.format && entry.w == d.width && entry.h == d.height &&
            entry.epoch == epoch) {
            return entry.tex;
        }

        const uint32_t* pal = pal_data_va ? pal_buf : nullptr;
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
            // Guard against uninitialized YUY2/UYVY pixels (all-0x00 -> bright green, all-0xFF -> bright pink/purple)
            // before or between Bink frames. Valid studio-range BT.601 black is 0x80108010, never 0x00000000 or 0xFFFFFFFF.
            const uint32_t total = d.pitch * d.height;
            if (total >= 64) {
                uint32_t dw0 = 0, dw1 = 0, dw2 = 0, dw3 = 0;
                std::memcpy(&dw0, guest + 0, 4);
                std::memcpy(&dw1, guest + ((total / 3) & ~3u), 4);
                std::memcpy(&dw2, guest + ((total / 2) & ~3u), 4);
                std::memcpy(&dw3, guest + (((total * 2) / 3) & ~3u), 4);
                static std::atomic<int> yuv_logged{0};
                if (yuv_logged.fetch_add(1, std::memory_order_relaxed) < 12) {
                    LOGR("metal: yuv tex fmt=%02X %ux%u pitch=%u dw=%08X,%08X,%08X,%08X",
                         d.format, d.width, d.height, d.pitch, dw0, dw1, dw2, dw3);
                }
                const bool uniform_fill = (dw0 == dw1 && dw1 == dw2 && dw2 == dw3) &&
                    (dw0 == 0u || dw0 == 0xFFFFFFFFu || (dw0 & 0xFFFFu) == (dw0 >> 16));
                if (uniform_fill) {
                    for (size_t i = 0; i + 3 < decoded.size(); i += 4) {
                        decoded[i + 0] = 0;
                        decoded[i + 1] = 0;
                        decoded[i + 2] = 0;
                        decoded[i + 3] = 255;
                    }
                } else {
                    for (uint32_t y = 0; y < d.height; ++y) {
                        const uint8_t* row = guest + size_t(y) * d.pitch;
                        for (uint32_t x = 0; x + 1 < d.width; x += 2) {
                            uint32_t pair = 0;
                            std::memcpy(&pair, row + size_t(x) * 2, 4);
                            if (pair == 0u || pair == 0xFFFFFFFFu) {
                                uint8_t* o = &decoded[(size_t(y) * d.width + x) * 4];
                                o[0] = o[1] = o[2] = 0; o[3] = 255;
                                o[4] = o[5] = o[6] = 0; o[7] = 255;
                            }
                        }
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

    bool EnsureEncoderFor(uint32_t rt_va, uint32_t zs_va, uint32_t w, uint32_t h) {
        auto& ct = EnsureColorTarget(rt_va, w, h);
        auto& dt = EnsureDepthTarget(zs_va, w, h);
        if (!ct.tex || !dt.tex) return false;
        if (encoder_ && active_color_tex_ == ct.tex && active_depth_tex_ == dt.tex &&
            !ct.pending_clear && !dt.pending_clear) {
            return true;
        }
        EndEncoder();
        if (!EnsureCommandBuffer()) return false;
        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = ct.tex;
        pass.colorAttachments[0].loadAction = ct.pending_clear ? MTLLoadActionClear : MTLLoadActionLoad;
        pass.colorAttachments[0].clearColor = ct.clear_color;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.depthAttachment.texture = dt.tex;
        pass.depthAttachment.loadAction = dt.pending_clear ? MTLLoadActionClear : MTLLoadActionLoad;
        pass.depthAttachment.clearDepth = dt.clear_depth;
        pass.depthAttachment.storeAction = MTLStoreActionStore;
        encoder_ = [cmd_buf_ renderCommandEncoderWithDescriptor:pass];
        if (!encoder_) return false;
        active_color_tex_ = ct.tex;
        active_depth_tex_ = dt.tex;
        ct.pending_clear = false;
        dt.pending_clear = false;
        return true;
    }

    uint32_t guest_width_ = 640;
    uint32_t guest_height_ = 480;
    uint32_t last_rt_va_ = 0;
    std::unordered_map<uint32_t, ColorTarget> color_rts_;
    std::unordered_map<uint64_t, DepthTarget> depth_rts_;
    CAMetalLayer* layer_ = nil;
    id<MTLDevice> device_ = nil;
    id<MTLCommandQueue> queue_ = nil;
    id<MTLFunction> vs_func_ = nil;
    id<MTLFunction> fs_func_ = nil;
    MTLVertexDescriptor* vertex_desc_ = nil;
    id<MTLRenderPipelineState> pipeline_ = nil;
    id<MTLRenderPipelineState> blit_present_pso_ = nil;
    id<MTLRenderPipelineState> blit_copy_pso_ = nil;
    id<MTLFunction> clear_vs_ = nil;
    id<MTLFunction> clear_fs_ = nil;
    std::unordered_map<uint32_t, id<MTLRenderPipelineState>> clear_pso_cache_;
    id<MTLTexture> white_tex_ = nil;
    id<MTLTexture> black_tex_ = nil;
    id<MTLTexture> feedback_tex_ = nil;
    id<MTLSamplerState> sampler_ = nil;
    id<MTLSamplerState> wrap_sampler_ = nil;
    std::unordered_map<uint64_t, id<MTLRenderPipelineState>> pso_cache_;
    std::unordered_map<uint64_t, id<MTLFunction>> vs_cache_;
    std::unordered_map<uint64_t, id<MTLFunction>> fs_cache_;
    std::unordered_set<uint64_t> failed_shaders_;
    std::unordered_map<uint32_t, id<MTLDepthStencilState>> dss_cache_;
    std::unordered_map<uint64_t, CachedTex> tex_cache_;

    id<MTLCommandBuffer> cmd_buf_ = nil;
    id<MTLRenderCommandEncoder> encoder_ = nil;
    id<MTLTexture> active_color_tex_ = nil;
    id<MTLTexture> active_depth_tex_ = nil;
    id<MTLCommandBuffer> last_cmd_buf_ = nil;
};

}  // namespace

void SetMetalLayer(void* ca_metal_layer) {
    g_metal_layer = (__bridge CAMetalLayer*)ca_metal_layer;
}

std::unique_ptr<Backend> CreateBackend() {
    return std::make_unique<MetalBackend>();
}

}  // namespace gpu
