#include "gpu/backend.h"
#include "gpu/metal.h"
#include "gpu/metal_shaders.h"
#include "gpu/shaders.h"
#include "gpu/texture.h"
#include "gpu/vertex.h"
#include "core/hitch_prof.h"
#include "core/log.h"
#include "kernel/kernel.h"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <dispatch/dispatch.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <bit>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace gpu {

namespace {

CAMetalLayer* g_metal_layer = nil;
std::atomic<uint32_t> g_presented_frames{0};
std::atomic<float> g_res_scale{1.0f};
std::atomic<bool> g_aniso_enabled{true};
std::atomic<bool> g_motion_blur_enabled{false};
std::atomic<uint32_t> g_target_fps{60};

std::mutex g_minimap_lock;
MinimapConfig g_minimap_cfg{};

struct MinimapFrameState {
    bool active = false;
    bool hidden = false;
    float orig_x = 0.0f, orig_y = 0.0f, orig_w = 0.0f, orig_h = 0.0f;
    float dx = 0.0f, dy = 0.0f;
};
MinimapFrameState g_minimap_frame{};

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
    case 0x8001: return is_alpha ? MTLBlendFactorBlendAlpha : MTLBlendFactorBlendColor;
    case 0x8002: return is_alpha ? MTLBlendFactorOneMinusBlendAlpha : MTLBlendFactorOneMinusBlendColor;
    case 0x8003: return MTLBlendFactorBlendAlpha;
    case 0x8004: return MTLBlendFactorOneMinusBlendAlpha;
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
    ~MetalBackend() override {
        Flush();
        if (frame_sem_) {
            for (uint32_t i = 0; i < kRingCount; ++i) {
                dispatch_semaphore_wait(frame_sem_, DISPATCH_TIME_FOREVER);
            }
            for (uint32_t i = 0; i < kRingCount; ++i) {
                dispatch_semaphore_signal(frame_sem_);
            }
        }
    }

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

        pipeline_ = GetPipeline(0, 0, vs_func_, fs_func_, false, 1, 0, 0, MTLColorWriteMaskAll, 0xFFFFu);
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

        sd.maxAnisotropy = 8;
        sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        aniso_sampler_ = [device_ newSamplerStateWithDescriptor:sd];
        sd.sAddressMode = MTLSamplerAddressModeRepeat;
        sd.tAddressMode = MTLSamplerAddressModeRepeat;
        aniso_wrap_sampler_ = [device_ newSamplerStateWithDescriptor:sd];

        // Triple-buffered transient upload ring for vertices, indices, and constants (zero per-draw Metal allocs)
        frame_sem_ = dispatch_semaphore_create(kRingCount);
        const MTLResourceOptions ring_opts =
            MTLResourceStorageModeShared | MTLResourceHazardTrackingModeUntracked;
        for (uint32_t i = 0; i < kRingCount; ++i) {
            ring_buf_[i] = [device_ newBufferWithLength:kRingSize options:ring_opts];
            ring_ptr_[i] = ring_buf_[i] ? static_cast<uint8_t*>([ring_buf_[i] contents]) : nullptr;
        }
        vsc_dummy_buf_ = [device_ newBufferWithLength:sizeof(State::vsc) options:MTLResourceStorageModeShared];
        if (vsc_dummy_buf_) {
            std::memset([vsc_dummy_buf_ contents], 0, sizeof(State::vsc));
        }
        scratch_verts_.reserve(4096);
        scratch_idx16_.reserve(8192);
        scratch_idx32_.reserve(8192);

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

            uint32_t phys_w = w, phys_h = h;
            PhysicalTargetSize(w, h, phys_w, phys_h);
            const double scale_x = double(phys_w) / double(w);
            const double scale_y = double(phys_h) / double(h);

            MinimapFrameState mm{};
            if (w == guest_width_ && h == guest_height_) {
                std::lock_guard<std::mutex> lk(g_minimap_lock);
                mm = g_minimap_frame;
            }

            std::vector<MTLScissorRect> rs;
            auto add_rect = [&](int32_t x0, int32_t y0, int32_t x1, int32_t y1) {
                const int32_t cx0 = std::clamp<int32_t>(int32_t(std::floor(x0 * scale_x)), 0, int32_t(phys_w));
                const int32_t cy0 = std::clamp<int32_t>(int32_t(std::floor(y0 * scale_y)), 0, int32_t(phys_h));
                const int32_t cx1 = std::clamp<int32_t>(int32_t(std::ceil(x1 * scale_x)), 0, int32_t(phys_w));
                const int32_t cy1 = std::clamp<int32_t>(int32_t(std::ceil(y1 * scale_y)), 0, int32_t(phys_h));
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
                    if (mm.active &&
                        r[0] >= int32_t(mm.orig_x) - 24 && r[2] <= int32_t(mm.orig_x + mm.orig_w) + 24 &&
                        r[1] >= int32_t(mm.orig_y) - 24 && r[3] <= int32_t(mm.orig_y + mm.orig_h) + 24) {
                        if (mm.hidden) continue;
                        r[0] += int32_t(std::lround(mm.dx));
                        r[2] += int32_t(std::lround(mm.dx));
                        r[1] += int32_t(std::lround(mm.dy));
                        r[3] += int32_t(std::lround(mm.dy));
                    }
                    add_rect(r[0], r[1], r[2], r[3]);
                }
            } else if (s.viewport.w && s.viewport.h) {
                add_rect(int32_t(s.viewport.x), int32_t(s.viewport.y),
                         int32_t(s.viewport.x + s.viewport.w), int32_t(s.viewport.y + s.viewport.h));
            } else if (mm.active && mm.hidden && s.viewport.w == 0 && s.viewport.h == 0) {
                return;
            } else {
                add_rect(0, 0, int32_t(w), int32_t(h));
            }
            if (rs.empty()) return;

            const bool full_rect = (rs.size() == 1 && rs[0].x == 0 && rs[0].y == 0 &&
                                    rs[0].width == phys_w && rs[0].height == phys_h);
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
                    ct.drawn_epoch = DirtyEpoch(rt_va);
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
                            ct.drawn_epoch = DirtyEpoch(rt_va);
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
        DrawImpl(s, prim, start, count, indices);
    }

    struct RegSrc {
        int reg = 0;
        int slot = 0;
        const uint8_t* src = nullptr;
        uint32_t stride = 0;
        uint32_t bytes = 0;
        uint16_t offset = 0;
        uint8_t format = 0;
    };

    static inline void DefaultReg(int r, float out[4]) {
        if (r == 3) {
            out[0] = out[1] = out[2] = out[3] = 1.0f;
        } else if (r == 2) {
            out[0] = 0.0f; out[1] = 0.0f; out[2] = 1.0f; out[3] = 0.0f;
        } else if (r == 4) {
            out[0] = out[1] = out[2] = out[3] = 0.0f;
        } else {
            out[0] = 0.0f; out[1] = 0.0f; out[2] = 0.0f; out[3] = 1.0f;
        }
    }

    static inline bool ReadReg(const RegSrc& rs, uint32_t v, bool has_conv, const float* conv, int reg_count, float out[4]) {
        if (has_conv) {
            std::memcpy(out, conv + (size_t(v) * size_t(reg_count) + size_t(rs.slot)) * 4, 16);
            return true;
        }
        const size_t off = size_t(v) * rs.stride + rs.offset;
        if (off >= rs.bytes) return false;
        const uint8_t* p = rs.src + off;
        switch (rs.format) {
        case 2: // DXGI_FORMAT_R32G32B32A32_FLOAT
            std::memcpy(out, p, 16);
            return true;
        case 6: // DXGI_FORMAT_R32G32B32_FLOAT
            std::memcpy(out, p, 12);
            out[3] = 1.0f;
            return true;
        case 16: // DXGI_FORMAT_R32G32_FLOAT
            std::memcpy(out, p, 8);
            out[2] = 0.0f;
            out[3] = 1.0f;
            return true;
        case 87: // DXGI_FORMAT_B8G8R8A8_UNORM (D3DCOLOR)
            out[0] = p[2] * (1.0f / 255.0f);
            out[1] = p[1] * (1.0f / 255.0f);
            out[2] = p[0] * (1.0f / 255.0f);
            out[3] = p[3] * (1.0f / 255.0f);
            return true;
        case 28: // DXGI_FORMAT_R8G8B8A8_UNORM
            out[0] = p[0] * (1.0f / 255.0f);
            out[1] = p[1] * (1.0f / 255.0f);
            out[2] = p[2] * (1.0f / 255.0f);
            out[3] = p[3] * (1.0f / 255.0f);
            return true;
        default:
            return false;
        }
    }

    void DrawImpl(const State& s, uint32_t prim, uint32_t start, uint32_t count, const uint8_t* indices) {

        Assembled& a = assembled_;
        if (!Assemble(s, prim, start, count, indices, a)) return;
        if (a.vertex_count == 0 || (a.regs & 1u) == 0) return;

        const bool has_conv = !a.vertices.empty();
        const float* conv_ptr = has_conv ? a.vertices.data() : nullptr;
        const int reg_count = has_conv ? std::popcount(a.regs) : 0;

        auto build_reg = [&](int r, RegSrc& out) -> bool {
            if ((a.regs & (1u << r)) == 0) return false;
            out.reg = r;
            if (has_conv) {
                out.slot = std::popcount(uint16_t(a.regs & ((1u << r) - 1)));
                return true;
            }
            const auto& e = a.elements[size_t(r)];
            if (e.buffer >= a.buffer_count || !a.buffers[e.buffer].src) return false;
            const auto& buf = a.buffers[e.buffer];
            out.src = buf.src;
            out.stride = buf.stride;
            out.bytes = buf.bytes;
            out.offset = e.offset;
            out.format = e.format;
            return true;
        };

        RegSrc pos_src{};
        RegSrc active_regs[15];
        int active_count = 0;
        uint16_t active_mask = a.regs;
        if (!has_conv) {
            if (!build_reg(0, pos_src)) return;
            active_mask = 1u;
            for (int r = 1; r < 16; ++r) {
                if (build_reg(r, active_regs[active_count])) {
                    active_mask |= uint16_t(1u << r);
                    ++active_count;
                }
            }
        }

        const uint32_t rt_va = s.rt.header ? mem::VirtualFromPhysical(s.rt.data) : 0u;
        const uint32_t zs_va = s.zs.header ? mem::VirtualFromPhysical(s.zs.data) : rt_va;
        uint32_t target_w = 0, target_h = 0;
        if (s.rt.header) SurfaceSize(s.rt, target_w, target_h);
        if (!target_w) target_w = guest_width_;
        if (!target_h) target_h = guest_height_;

        // Resolve textures & TexInfo for all 4 stages
        const bool use_aniso = g_aniso_enabled.load(std::memory_order_relaxed);
        id<MTLSamplerState> base_clamp = (use_aniso && aniso_sampler_) ? aniso_sampler_ : sampler_;
        id<MTLSamplerState> base_wrap = (use_aniso && aniso_wrap_sampler_) ? aniso_wrap_sampler_ : wrap_sampler_;
        id<MTLTexture> stage_tex[4] = { white_tex_, white_tex_, white_tex_, white_tex_ };
        id<MTLSamplerState> stage_smp[4] = { base_clamp, base_clamp, base_clamp, base_clamp };
        TexInfo tex_info[4]{};
        float tex_dims[4][2] = {{1.0f, 1.0f}, {1.0f, 1.0f}, {1.0f, 1.0f}, {1.0f, 1.0f}};
        bool stage_is_rt[4] = {};
        uint32_t stage_rt_w[4] = {}, stage_rt_h[4] = {};
        for (int t = 0; t < 4; ++t) {
            if (s.textures[t]) {
                TextureDesc td{};
                bool is_rt = false;
                const uint32_t simple_pal = s.simple[(0x1B20 + uint32_t(t) * 0x40) / 4];
                id<MTLTexture> mt = ResolveTexture(s.textures[t], s.palettes[t], simple_pal, rt_va, &td, &is_rt);
                if (mt) {
                    stage_tex[t] = mt;
                    stage_is_rt[t] = is_rt;
                    if (is_rt) {
                        stage_rt_w[t] = td.width;
                        stage_rt_h[t] = td.height;
                    }
                    tex_info[t].kind = (mt.textureType == MTLTextureTypeCube) ? kTexCube
                                     : (mt.textureType == MTLTextureType3D)   ? kTex3D
                                     : kTex2D;
                    tex_info[t].rect = td.linear ? 1 : 0;
                    tex_dims[t][0] = td.width ? float(td.width) : 1.0f;
                    tex_dims[t][1] = td.height ? float(td.height) : 1.0f;
                    const uint32_t addr_u = s.tss[size_t(t)][kTssAddressU];
                    const uint32_t addr_v = s.tss[size_t(t)][kTssAddressV];
                    if (!td.linear && (addr_u == 1 || addr_v == 1)) {
                        stage_smp[t] = base_wrap;
                    }
                }
            }
        }

        const bool blend_on = s.simple[kMBlendEnable / 4] != 0;
        const uint32_t src_b = s.simple[kMSrcBlend / 4];
        const uint32_t dst_b = s.simple[kMDestBlend / 4];
        const uint32_t blend_op = s.simple[kMBlendOp / 4];

        // Suppress MC3's mcSenseOfSpeed half-resolution radial speed-blur composite unless the user
        // explicitly enables original Xbox speed blur in the launcher settings.
        if (!g_motion_blur_enabled.load(std::memory_order_relaxed) &&
            a.pretransformed && prim == 6 && count == 4 &&
            s.vs_handle == 0x1C4 && !s.ps &&
            target_w == guest_width_ && target_h == guest_height_ &&
            s.viewport.x == 0 && s.viewport.y == 0 &&
            s.viewport.w == guest_width_ && s.viewport.h == guest_height_ &&
            stage_is_rt[0] && stage_rt_w[0] * 2 == target_w && stage_rt_h[0] * 2 == target_h &&
            !s.textures[1] && !s.textures[2] && !s.textures[3] &&
            blend_on && src_b == 0x302 && dst_b == 0x303) {
            return;
        }

        // Shift or hide 2D XYZRHW minimap frame/blip quads when the user moved or hid the minimap.
        if (a.pretransformed && has_conv && target_w == guest_width_ && target_h == guest_height_ &&
            a.vertex_count > 0 && a.vertex_count <= 128 && reg_count > 0) {
            MinimapFrameState mm{};
            {
                std::lock_guard<std::mutex> lk(g_minimap_lock);
                mm = g_minimap_frame;
            }
            if (mm.active) {
                const float min_x = mm.orig_x - 24.0f, max_x = mm.orig_x + mm.orig_w + 24.0f;
                const float min_y = mm.orig_y - 24.0f, max_y = mm.orig_y + mm.orig_h + 24.0f;
                bool all_in = true;
                float* verts_f = a.vertices.data();
                for (uint32_t i = 0; i < a.vertex_count; ++i) {
                    const float vx = verts_f[size_t(i) * size_t(reg_count) * 4 + 0];
                    const float vy = verts_f[size_t(i) * size_t(reg_count) * 4 + 1];
                    if (vx < min_x || vx > max_x || vy < min_y || vy > max_y) {
                        all_in = false;
                        break;
                    }
                }
                if (all_in) {
                    if (mm.hidden) return;
                    if (mm.dx != 0.0f || mm.dy != 0.0f) {
                        for (uint32_t i = 0; i < a.vertex_count; ++i) {
                            verts_f[size_t(i) * size_t(reg_count) * 4 + 0] += mm.dx;
                            verts_f[size_t(i) * size_t(reg_count) * 4 + 1] += mm.dy;
                        }
                    }
                }
            }
        }

        // Determine active vertex registers supplied by our full 16-register MetalVertex layout
        const uint16_t supplied_regs = active_mask | (1u << 0);
        const bool is_prog_vs = (s.vs_handle & 1) && s.vs && !s.vs->program.empty();
        const FixedKey fk = is_prog_vs ? FixedKey{} : MakeFixedKey(s);
        uint64_t vs_hash = 0, ps_hash = 0;
        id<MTLFunction> active_vs = nil;
        id<MTLFunction> active_fs = nil;

        {
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

        // Fast zero-copy path: translated MSL shaders read tightly-packed float4[nregs] vertices
        // directly from AssembleConverted (e.g. 48 B/vert instead of 256 B/vert = ~5x less bandwidth).
        const bool direct_packed_vb = (use_translated && has_conv);
        const void* vb_src = nullptr;
        size_t vb_bytes = 0;
        if (direct_packed_vb) {
            vb_src = a.vertices.data();
            vb_bytes = a.vertices.size() * sizeof(float);
        } else {
            if (has_conv) {
                if (!build_reg(0, pos_src)) return;
                active_count = 0;
                for (int r = 1; r < 16; ++r) {
                    if (build_reg(r, active_regs[active_count])) ++active_count;
                }
            }
            scratch_verts_.resize(a.vertex_count);
            MetalVertex* verts = scratch_verts_.data();
            const float inv_w = 2.0f / float(target_w);
            const float inv_h = 2.0f / float(target_h);
            const bool need_fallback_c3 = !use_translated && ((active_mask & (1u << 3)) == 0);
            const bool need_fallback_t9 = !use_translated && ((active_mask & (1u << 9)) == 0);

            for (uint32_t i = 0; i < a.vertex_count; ++i) {
                float p[4] = {};
                if (!ReadReg(pos_src, i, has_conv, conv_ptr, reg_count, p)) return;
                MetalVertex& dst = verts[i];
                if (use_translated) {
                    dst.v[0][0] = p[0];
                    dst.v[0][1] = p[1];
                    dst.v[0][2] = p[2];
                    dst.v[0][3] = (p[3] != 0.0f) ? p[3] : 1.0f;
                } else if (a.pretransformed) {
                    dst.v[0][0] = p[0] * inv_w - 1.0f;
                    dst.v[0][1] = 1.0f - p[1] * inv_h;
                    dst.v[0][2] = p[2];
                    dst.v[0][3] = 1.0f;
                } else {
                    p[3] = (p[3] != 0.0f) ? p[3] : 1.0f;
                    float wv[4], vv[4], pv[4];
                    MulMat4Vec4(s.transforms[256].data(), p, wv);
                    MulMat4Vec4(s.transforms[2].data(), wv, vv);
                    MulMat4Vec4(s.transforms[3].data(), vv, pv);
                    dst.v[0][0] = pv[0];
                    dst.v[0][1] = pv[1];
                    dst.v[0][2] = pv[2];
                    dst.v[0][3] = pv[3];
                }

                for (int k = 0; k < active_count; ++k) {
                    const RegSrc& rs = active_regs[k];
                    if (!ReadReg(rs, i, has_conv, conv_ptr, reg_count, dst.v[rs.reg])) {
                        DefaultReg(rs.reg, dst.v[rs.reg]);
                    }
                }
                if (need_fallback_c3) DefaultReg(3, dst.v[3]);
                if (need_fallback_t9) DefaultReg(9, dst.v[9]);
            }
            vb_src = verts;
            vb_bytes = size_t(a.vertex_count) * sizeof(MetalVertex);
        }

        // Skip draws when viewport was intentionally zeroed (e.g. hidden minimap).
        if (s.viewport.w == 0 && s.viewport.h == 0) {
            MinimapFrameState mm{};
            {
                std::lock_guard<std::mutex> lk(g_minimap_lock);
                mm = g_minimap_frame;
            }
            if (mm.active && mm.hidden) return;
        }

        if (!EnsureEncoderFor(rt_va, zs_va, target_w, target_h)) return;
        if (active_ct_) active_ct_->drawn = true;
        last_rt_va_ = rt_va;

        const uint32_t phys_w = active_ct_ ? active_ct_->phys_w : target_w;
        const uint32_t phys_h = active_ct_ ? active_ct_->phys_h : target_h;
        const double sc_scale_x = double(phys_w) / double(target_w);
        const double sc_scale_y = double(phys_h) / double(target_h);

        // Always clip to the active viewport (and any explicit scissor rect) just like
        // Xbox D3D8/NV2A, so sub-viewport draws such as the minimap never bleed outside.
        int32_t sx0 = 0, sy0 = 0, sx1 = int32_t(target_w), sy1 = int32_t(target_h);
        if (s.viewport.w && s.viewport.h) {
            sx0 = std::max<int32_t>(sx0, int32_t(s.viewport.x));
            sy0 = std::max<int32_t>(sy0, int32_t(s.viewport.y));
            sx1 = std::min<int32_t>(sx1, int32_t(s.viewport.x + s.viewport.w));
            sy1 = std::min<int32_t>(sy1, int32_t(s.viewport.y + s.viewport.h));
        }
        if (s.scissor_count > 0) {
            sx0 = std::max<int32_t>(sx0, int32_t(s.scissors[0]));
            sy0 = std::max<int32_t>(sy0, int32_t(s.scissors[1]));
            sx1 = std::min<int32_t>(sx1, int32_t(s.scissors[2]));
            sy1 = std::min<int32_t>(sy1, int32_t(s.scissors[3]));
        }
        const int32_t psx0 = std::clamp<int32_t>(int32_t(std::floor(sx0 * sc_scale_x)), 0, int32_t(phys_w));
        const int32_t psy0 = std::clamp<int32_t>(int32_t(std::floor(sy0 * sc_scale_y)), 0, int32_t(phys_h));
        const int32_t psx1 = std::clamp<int32_t>(int32_t(std::ceil(sx1 * sc_scale_x)), 0, int32_t(phys_w));
        const int32_t psy1 = std::clamp<int32_t>(int32_t(std::ceil(sy1 * sc_scale_y)), 0, int32_t(phys_h));
        if (psx1 <= psx0 || psy1 <= psy0) return;
        const MTLScissorRect sc{
            NSUInteger(psx0), NSUInteger(psy0),
            NSUInteger(psx1 - psx0), NSUInteger(psy1 - psy0)
        };
        if (!bound_scissor_valid_ ||
            sc.x != bound_scissor_.x || sc.y != bound_scissor_.y ||
            sc.width != bound_scissor_.width || sc.height != bound_scissor_.height) {
            [encoder_ setScissorRect:sc];
            bound_scissor_ = sc;
            bound_scissor_valid_ = true;
        }

        const uint32_t cw_raw = s.simple[kMColorWriteEnable / 4];
        const MTLColorWriteMask write_mask = s.rt.header
            ? ToMetalWriteMask(cw_raw)
            : MTLColorWriteMaskAll;
        const uint16_t vd_regs = direct_packed_vb ? a.regs : 0xFFFFu;
        id<MTLRenderPipelineState> pso = GetPipeline(vs_hash, ps_hash, active_vs, active_fs,
                                                     blend_on, src_b, dst_b, blend_op, write_mask, vd_regs);
        if (!pso) return;

        const bool z_en = s.rs[kRsZEnable] != 0;
        const bool z_wr = s.simple[kMZWriteEnable / 4] != 0;
        const uint32_t z_fn = s.simple[kMZFunc / 4];
        id<MTLDepthStencilState> dss = GetDepthStencil(z_en, z_wr, z_fn);

        id<MTLBuffer> vb = nil;
        NSUInteger vb_off = 0;
        if (!AllocateRing(vb_src, vb_bytes, 16, vb, vb_off)) return;

        if (pso != bound_pso_) {
            [encoder_ setRenderPipelineState:pso];
            bound_pso_ = pso;
        }
        if (dss && dss != bound_dss_) {
            [encoder_ setDepthStencilState:dss];
            bound_dss_ = dss;
        }
        if (blend_on) {
            const uint32_t bc = s.simple[kMBlendColor / 4];
            if (!bound_blend_color_valid_ || bc != bound_blend_color_) {
                [encoder_ setBlendColorRed:((bc >> 16) & 0xFF) * (1.0f / 255.0f)
                                     green:((bc >> 8) & 0xFF) * (1.0f / 255.0f)
                                      blue:(bc & 0xFF) * (1.0f / 255.0f)
                                     alpha:((bc >> 24) & 0xFF) * (1.0f / 255.0f)];
                bound_blend_color_ = bc;
                bound_blend_color_valid_ = true;
            }
        }
        for (int t = 0; t < 4; ++t) {
            if (stage_tex[t] != bound_tex_[t]) {
                [encoder_ setFragmentTexture:stage_tex[t] atIndex:t];
                bound_tex_[t] = stage_tex[t];
            }
            if (stage_smp[t] != bound_smp_[t]) {
                [encoder_ setFragmentSamplerState:stage_smp[t] atIndex:t];
                bound_smp_[t] = stage_smp[t];
            }
        }
        if (vb == bound_vs_buf0_) {
            [encoder_ setVertexBufferOffset:vb_off atIndex:0];
        } else {
            [encoder_ setVertexBuffer:vb offset:vb_off atIndex:0];
            bound_vs_buf0_ = vb;
        }

        if (use_translated) {
            DrawConstants dc;
            if (is_prog_vs) {
                std::memset(&dc, 0, offsetof(DrawConstants, wvp));
                std::memset(dc.ext, 0, sizeof(dc.ext) + sizeof(dc.spread));
            } else {
                std::memset(&dc, 0, sizeof(dc));
            }
            FillDrawConstants(s, fk, dc, tex_dims, target_w, target_h, is_prog_vs, a.pretransformed);
            id<MTLBuffer> dc_buf = nil;
            NSUInteger dc_off = 0;
            if (!AllocateRing(&dc, sizeof(dc), 256, dc_buf, dc_off)) return;
            if (dc_buf == bound_vs_buf17_) {
                [encoder_ setVertexBufferOffset:dc_off atIndex:17];
            } else {
                [encoder_ setVertexBuffer:dc_buf offset:dc_off atIndex:17];
                bound_vs_buf17_ = dc_buf;
            }
            if (dc_buf == bound_fs_buf17_) {
                [encoder_ setFragmentBufferOffset:dc_off atIndex:17];
            } else {
                [encoder_ setFragmentBuffer:dc_buf offset:dc_off atIndex:17];
                bound_fs_buf17_ = dc_buf;
            }

            // Fragment shaders never read vc.c (vsc_dummy_buf_ stays bound at fragment buffer 16),
            // and fixed-function vertex shaders never read vc.c either. Only upload s.vsc for
            // programmable vertex shaders, and skip the upload when constants are unchanged.
            if (is_prog_vs) {
                if (!bound_vsc_valid_ || std::memcmp(s.vsc.data(), bound_vsc_.data(), sizeof(s.vsc)) != 0) {
                    id<MTLBuffer> vc_buf = nil;
                    NSUInteger vc_off = 0;
                    if (!AllocateRing(s.vsc.data(), sizeof(s.vsc), 256, vc_buf, vc_off)) return;
                    if (vc_buf == bound_vs_buf16_) {
                        [encoder_ setVertexBufferOffset:vc_off atIndex:16];
                    } else {
                        [encoder_ setVertexBuffer:vc_buf offset:vc_off atIndex:16];
                        bound_vs_buf16_ = vc_buf;
                    }
                    std::memcpy(bound_vsc_.data(), s.vsc.data(), sizeof(s.vsc));
                    bound_vsc_valid_ = true;
                }
            }
        }

        const MTLPrimitiveType mtl_prim = ToMetalPrimitive(a.topology, a.strip);
        if (a.index_count > 0 && !a.indices.empty()) {
            const uint32_t* idx_ptr = a.indices.data();
            if (a.base_vertex != 0) {
                scratch_idx32_.resize(a.index_count);
                for (uint32_t k = 0; k < a.index_count; ++k) {
                    int64_t v = int64_t(a.indices[k]) + int64_t(a.base_vertex);
                    scratch_idx32_[k] = (v >= 0 && v < int64_t(a.vertex_count)) ? uint32_t(v) : 0u;
                }
                idx_ptr = scratch_idx32_.data();
            }
            id<MTLBuffer> ib = nil;
            NSUInteger ib_off = 0;
            if (AllocateRing(idx_ptr, size_t(a.index_count) * sizeof(uint32_t), 16, ib, ib_off)) {
                [encoder_ drawIndexedPrimitives:mtl_prim
                                     indexCount:a.index_count
                                      indexType:MTLIndexTypeUInt32
                                    indexBuffer:ib
                              indexBufferOffset:ib_off];
            }
        } else if (a.index_count > 0 && a.index_src) {
            if (a.index16) {
                const auto* src16 = static_cast<const uint16_t*>(a.index_src);
                const uint16_t* idx_ptr = src16;
                if (a.base_vertex != 0) {
                    scratch_idx16_.resize(a.index_count);
                    for (uint32_t k = 0; k < a.index_count; ++k) {
                        int64_t v = int64_t(src16[k]) + int64_t(a.base_vertex);
                        scratch_idx16_[k] = (v >= 0 && v < int64_t(a.vertex_count)) ? uint16_t(v) : 0u;
                    }
                    idx_ptr = scratch_idx16_.data();
                }
                id<MTLBuffer> ib = nil;
                NSUInteger ib_off = 0;
                if (AllocateRing(idx_ptr, size_t(a.index_count) * sizeof(uint16_t), 16, ib, ib_off)) {
                    [encoder_ drawIndexedPrimitives:mtl_prim
                                         indexCount:a.index_count
                                          indexType:MTLIndexTypeUInt16
                                        indexBuffer:ib
                                  indexBufferOffset:ib_off];
                }
            } else {
                const auto* src32 = static_cast<const uint32_t*>(a.index_src);
                const uint32_t* idx_ptr = src32;
                if (a.base_vertex != 0) {
                    scratch_idx32_.resize(a.index_count);
                    for (uint32_t k = 0; k < a.index_count; ++k) {
                        int64_t v = int64_t(src32[k]) + int64_t(a.base_vertex);
                        scratch_idx32_[k] = (v >= 0 && v < int64_t(a.vertex_count)) ? uint32_t(v) : 0u;
                    }
                    idx_ptr = scratch_idx32_.data();
                }
                id<MTLBuffer> ib = nil;
                NSUInteger ib_off = 0;
                if (AllocateRing(idx_ptr, size_t(a.index_count) * sizeof(uint32_t), 16, ib, ib_off)) {
                    [encoder_ drawIndexedPrimitives:mtl_prim
                                         indexCount:a.index_count
                                          indexType:MTLIndexTypeUInt32
                                        indexBuffer:ib
                                  indexBufferOffset:ib_off];
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
                if (count == 0 && src_it->second.phys_w == dst_ct.phys_w && src_it->second.phys_h == dst_ct.phys_h) {
                    id<MTLBlitCommandEncoder> blit = [cmd_buf_ blitCommandEncoder];
                    if (blit) {
                        [blit copyFromTexture:src_it->second.tex
                                  sourceSlice:0
                                  sourceLevel:0
                                 sourceOrigin:MTLOriginMake(0, 0, 0)
                                   sourceSize:MTLSizeMake(dst_ct.phys_w, dst_ct.phys_h, 1)
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
                dst_ct.drawn_epoch = DirtyEpoch(dst_va);
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
            ++frame_id_;
            g_presented_frames.fetch_add(1, std::memory_order_relaxed);
            {
                std::lock_guard<std::mutex> lk(g_minimap_lock);
                g_minimap_frame.active = false;
            }
        }
    }

    // Avoid stalling the CPU on GPU completion for resource-busy hints; Metal textures are
    // copied synchronously on upload and the transient ring is synchronized per frame.
    void Sync(uint32_t, uint32_t) override {}
    void SyncLate(uint32_t) override {}

    void Flush() override {
        const uint64_t t0 = hitch::NowUs();
        @autoreleasepool {
            EndEncoder();
            if (cmd_buf_) {
                [cmd_buf_ commit];
                last_cmd_buf_ = cmd_buf_;
                cmd_buf_ = nil;
            }
            if (last_cmd_buf_) {
                [last_cmd_buf_ waitUntilCompleted];
                last_cmd_buf_ = nil;
            }
        }
        hitch::AddD3dFlush(hitch::NowUs() - t0);
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
        uint32_t w = 0, h = 0, depth = 1;
        uint64_t epoch = ~0ull;
        uint64_t pal_hash = 0;
        uint64_t frame = 0;
        uint64_t last_used_frame = 0;
    };

    static uint64_t MemSig(const uint8_t* p, uint32_t total) {
        if (!p || !total) return 0;
        uint64_t sig = total;
        if (total <= 4096) return Hash(p, total, sig);
        constexpr uint32_t kSamples = 16;
        constexpr uint32_t kBytes = 64;
        for (uint32_t i = 0; i < kSamples; ++i) {
            const uint32_t off = uint32_t(uint64_t(total - kBytes) * i / (kSamples - 1));
            sig = Hash(p + off, kBytes, sig);
        }
        return sig;
    }

    id<MTLFunction> GetOrCompileFunction(uint64_t hash, const std::string& msl, NSString* entry,
                                         std::unordered_map<uint64_t, id<MTLFunction>>& cache) {
        if (auto it = cache.find(hash); it != cache.end()) return it->second;
        const uint64_t t0 = hitch::NowUs();
        @autoreleasepool {
            NSError* err = nil;
            MTLCompileOptions* opts = [[MTLCompileOptions alloc] init];
            opts.fastMathEnabled = YES;
            id<MTLLibrary> lib = [device_ newLibraryWithSource:@(msl.c_str()) options:opts error:&err];
            if (!lib) {
                if (failed_shaders_.insert(hash).second) {
                    LOGE("metal: MSL compile failed (%s): %s", [entry UTF8String], [[err localizedDescription] UTF8String]);
                }
                cache[hash] = nil;
                hitch::AddMetalCompile(hitch::NowUs() - t0);
                return nil;
            }
            id<MTLFunction> fn = [lib newFunctionWithName:entry];
            cache[hash] = fn;
            hitch::AddMetalCompile(hitch::NowUs() - t0);
            return fn;
        }
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
                           uint32_t target_w, uint32_t target_h, bool is_prog_vs, bool pretransformed) {
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
        if (s.rs[kRsFogEnable]) {
            if (is_prog_vs && s.rs[kRsFogTableMode] == 0) {
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
            out[0] = ((v >> 16) & 0xFF) * (1.0f / 255.0f);
            out[1] = ((v >> 8) & 0xFF) * (1.0f / 255.0f);
            out[2] = (v & 0xFF) * (1.0f / 255.0f);
            out[3] = ((v >> 24) & 0xFF) * (1.0f / 255.0f);
        };
        unpack_c(s.rs[kRsFogColor], dc.fog_color);

        dc.misc[0] = float(s.simple[kMAlphaRef / 4] & 0xFF);
        dc.misc[1] = s.simple[kMAlphaTestEnable / 4] ? float(CmpIndex(s.simple[kMAlphaFunc / 4])) : 7.0f;
        dc.misc[2] = float(CmpIndex(s.rs[kRsShadowFunc]));
        dc.misc[3] = s.rs[kRsSpecularEnable] ? 1.0f : 0.0f;

        unpack_c(s.rs[kRsTextureFactor], dc.tfactor);

        if (s.ps) {
            for (int i = 0; i < 8; ++i) {
                unpack_c(s.simple[kMPsConstant0 / 4 + i], dc.pc[i * 2 + 0]);
                unpack_c(s.simple[kMPsConstant1 / 4 + i], dc.pc[i * 2 + 1]);
            }
            unpack_c(s.simple[kMPsFinalConstant0 / 4], dc.pc[16]);
            unpack_c(s.simple[kMPsFinalConstant1 / 4], dc.pc[17]);
        }

        for (int t = 0; t < 4; ++t) {
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

        // Programmable vertex shaders use vc.c[0..191] instead of fixed-function matrices & lights.
        if (is_prog_vs) return;

        if (!pretransformed) {
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
        }

        for (int t = 0; t < 4; ++t) {
            if ((fk.tex[t] >> 8) & 7u) {
                TransposeMat4(s.transforms[16 + t].data(), dc.tm[t]);
            }
        }

        if (fk.light & 1u) {
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
    }

    MTLVertexDescriptor* GetVertexDescriptor(uint16_t regs) {
        if (regs == 0xFFFFu) return vertex_desc_;
        if (auto it = vd_cache_.find(regs); it != vd_cache_.end()) return it->second;
        @autoreleasepool {
            MTLVertexDescriptor* vd = [[MTLVertexDescriptor alloc] init];
            NSUInteger slot = 0;
            for (NSUInteger r = 0; r < 16; ++r) {
                if (regs & (1u << r)) {
                    vd.attributes[r].format = MTLVertexFormatFloat4;
                    vd.attributes[r].offset = slot * sizeof(float) * 4;
                    vd.attributes[r].bufferIndex = 0;
                    ++slot;
                }
            }
            vd.layouts[0].stride = slot * sizeof(float) * 4;
            vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
            vd_cache_[regs] = vd;
            return vd;
        }
    }

    id<MTLRenderPipelineState> GetPipeline(uint64_t vs_hash, uint64_t ps_hash,
                                           id<MTLFunction> vs, id<MTLFunction> fs,
                                           bool blend, uint32_t src_b, uint32_t dst_b,
                                           uint32_t blend_op, MTLColorWriteMask write_mask,
                                           uint16_t vd_regs) {
        const uint64_t state_bits = (uint64_t(blend) << 56) |
                                    (uint64_t(write_mask & 0xF) << 48) |
                                    (uint64_t(blend_op & 0xFFFF) << 32) |
                                    (uint64_t(src_b & 0xFFFF) << 16) |
                                    uint64_t(dst_b & 0xFFFF);
        const uint64_t key = vs_hash ^ (ps_hash * 0x9E3779B97F4A7C15ull) ^
                             (state_bits * 0xBF58476D1CE4E5B9ull) ^
                             (uint64_t(vd_regs) * 0x94D049BB133111EBull);
        if (auto it = pso_cache_.find(key); it != pso_cache_.end()) return it->second;

        const uint64_t t0 = hitch::NowUs();
        @autoreleasepool {
            MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
            desc.vertexFunction = vs;
            desc.fragmentFunction = fs;
            desc.vertexDescriptor = GetVertexDescriptor(vd_regs);
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
            hitch::AddMetalCompile(hitch::NowUs() - t0);
            if (!pso) {
                LOGE("metal: pipeline creation failed: %s", [[err localizedDescription] UTF8String]);
                return nil;
            }
            pso_cache_[key] = pso;
            return pso;
        }
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

        @autoreleasepool {
            MTLDepthStencilDescriptor* desc = [[MTLDepthStencilDescriptor alloc] init];
            desc.depthCompareFunction = z_en ? ToMetalCompare(z_fn) : MTLCompareFunctionAlways;
            desc.depthWriteEnabled = (z_en && z_wr) ? YES : NO;
            id<MTLDepthStencilState> dss = [device_ newDepthStencilStateWithDescriptor:desc];
            dss_cache_[key] = dss;
            return dss;
        }
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
        out.resize(size_t(pitch) * h);
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
        uint32_t phys_w = 0, phys_h = 0;
        bool pending_clear = true;
        MTLClearColor clear_color = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
        bool drawn = false;
        uint64_t drawn_epoch = 0;
    };

    struct DepthTarget {
        id<MTLTexture> tex = nil;
        uint32_t w = 0, h = 0;
        uint32_t phys_w = 0, phys_h = 0;
        bool pending_clear = true;
        double clear_depth = 1.0;
    };

    void PhysicalTargetSize(uint32_t w, uint32_t h, uint32_t& pw, uint32_t& ph) const {
        const float scale = std::clamp(g_res_scale.load(std::memory_order_relaxed), 1.0f, 2.0f);
        if (scale > 1.01f && w == guest_width_ && h == guest_height_) {
            pw = uint32_t(std::lround(double(w) * double(scale)));
            ph = uint32_t(std::lround(double(h) * double(scale)));
        } else {
            pw = w;
            ph = h;
        }
    }

    ColorTarget& EnsureColorTarget(uint32_t rt_va, uint32_t w, uint32_t h) {
        if (!w) w = guest_width_;
        if (!h) h = guest_height_;
        uint32_t pw = w, ph = h;
        PhysicalTargetSize(w, h, pw, ph);
        auto& ct = color_rts_[rt_va];
        if (!ct.tex || ct.w != w || ct.h != h || ct.phys_w != pw || ct.phys_h != ph) {
            MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:pw
                                                                                         height:ph
                                                                                      mipmapped:NO];
            td.storageMode = MTLStorageModePrivate;
            td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            ct.tex = [device_ newTextureWithDescriptor:td];
            ct.w = w;
            ct.h = h;
            ct.phys_w = pw;
            ct.phys_h = ph;
            ct.pending_clear = true;
            ct.clear_color = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
            ct.drawn = false;
        }
        return ct;
    }

    DepthTarget& EnsureDepthTarget(uint32_t zs_va, uint32_t w, uint32_t h) {
        if (!w) w = guest_width_;
        if (!h) h = guest_height_;
        uint32_t pw = w, ph = h;
        PhysicalTargetSize(w, h, pw, ph);
        const uint64_t key = (uint64_t(zs_va) << 32) | (uint64_t(w & 0xFFFFu) << 16) | uint64_t(h & 0xFFFFu);
        auto& dt = depth_rts_[key];
        if (!dt.tex || dt.w != w || dt.h != h || dt.phys_w != pw || dt.phys_h != ph) {
            MTLTextureDescriptor* dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                          width:pw
                                                                                         height:ph
                                                                                      mipmapped:NO];
            dd.storageMode = MTLStorageModePrivate;
            dd.usage = MTLTextureUsageRenderTarget;
            dt.tex = [device_ newTextureWithDescriptor:dd];
            dt.w = w;
            dt.h = h;
            dt.phys_w = pw;
            dt.phys_h = ph;
            dt.pending_clear = true;
            dt.clear_depth = 1.0;
        }
        return dt;
    }

    void ResetEncoderState() {
        bound_pso_ = nil;
        bound_dss_ = nil;
        for (int t = 0; t < 4; ++t) {
            bound_tex_[t] = nil;
            bound_smp_[t] = nil;
        }
        bound_vs_buf0_ = nil;
        bound_vs_buf16_ = nil;
        bound_vs_buf17_ = nil;
        bound_fs_buf17_ = nil;
        bound_scissor_valid_ = false;
        bound_blend_color_valid_ = false;
        bound_vsc_valid_ = false;
    }

    bool AllocateRing(const void* data, size_t bytes, size_t align, __strong id<MTLBuffer>& out_buf, NSUInteger& out_off) {
        if (bytes == 0) return false;
        const size_t mask = align - 1;
        const size_t aligned = (ring_off_ + mask) & ~mask;
        if (ring_buf_[ring_idx_] && ring_ptr_[ring_idx_] && aligned + bytes <= kRingSize) {
            std::memcpy(ring_ptr_[ring_idx_] + aligned, data, bytes);
            out_buf = ring_buf_[ring_idx_];
            out_off = NSUInteger(aligned);
            ring_off_ = aligned + bytes;
            return true;
        }
        out_buf = [device_ newBufferWithBytes:data length:bytes options:MTLResourceStorageModeShared];
        out_off = 0;
        return out_buf != nil;
    }

    void EndEncoder() {
        if (encoder_) {
            [encoder_ endEncoding];
            encoder_ = nil;
            active_color_tex_ = nil;
            active_depth_tex_ = nil;
            active_ct_ = nullptr;
            ResetEncoderState();
        }
    }

    bool EnsureCommandBuffer() {
        if (cmd_buf_) return true;
        if (frame_sem_) {
            dispatch_semaphore_wait(frame_sem_, DISPATCH_TIME_FOREVER);
            ring_idx_ = (ring_idx_ + 1) % kRingCount;
            ring_off_ = 0;
        }
        cmd_buf_ = [queue_ commandBuffer];
        if (!cmd_buf_) {
            if (frame_sem_) dispatch_semaphore_signal(frame_sem_);
            return false;
        }
        if (frame_sem_) {
            dispatch_semaphore_t sem = frame_sem_;
            [cmd_buf_ addCompletedHandler:^(__unused id<MTLCommandBuffer> cb) {
                dispatch_semaphore_signal(sem);
            }];
        }
        return true;
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
                                  uint32_t current_rt_va, TextureDesc* out_desc = nullptr, bool* out_is_rt = nullptr) {
        TextureDesc d;
        if (!Describe(header_va, d) || !d.data || !d.width || !d.height) return nil;
        if (out_desc) *out_desc = d;
        if (out_is_rt) *out_is_rt = false;
        const auto& fi = Format(d.format);
        const bool is_bc = (fi.host == gpu::Host::BC1 || fi.host == gpu::Host::BC2 || fi.host == gpu::Host::BC3);
        if (!is_bc && !d.cube && d.depth <= 1 && d.format != 0x24 && d.format != 0x25 && d.format != 0x0B) {
            if (auto it = color_rts_.find(d.data);
                it != color_rts_.end() && it->second.tex && it->second.drawn &&
                it->second.w == d.width && it->second.h == d.height &&
                it->second.drawn_epoch == DirtyEpoch(d.data)) {
                if (out_is_rt) *out_is_rt = true;
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
                const uint32_t size_code = (simple_palette >> 2) & 3u;
                pal_bytes = (256u >> size_code) * sizeof(uint32_t);
            }
            if (pal_data_va) {
                std::memcpy(pal_buf, kernel::HostPtr(pal_data_va), pal_bytes);
                pal_hash = Hash(pal_buf, sizeof(pal_buf));
            }
        }

        const MTLTextureType want_type = (d.cube && d.width == d.height) ? MTLTextureTypeCube
                                       : (d.depth > 1)                   ? MTLTextureType3D
                                       : MTLTextureType2D;
        const uint64_t cache_key = (uint64_t(pal_data_va) << 32) | d.data;
        auto& entry = tex_cache_[cache_key];
        const bool same_meta = entry.tex && entry.tex.textureType == want_type &&
                               entry.format == d.format && entry.w == d.width &&
                               entry.h == d.height && entry.depth == d.depth;
        // Fast path: already validated during this frame (skips DirtyEpoch mutex & MemSig hashing)
        if (same_meta && entry.frame == frame_id_ && entry.pal_hash == pal_hash) {
            entry.last_used_frame = frame_id_;
            return entry.tex;
        }

        const uint8_t* guest = static_cast<const uint8_t*>(kernel::HostPtr(d.data));
        const uint32_t total = d.linear ? (d.pitch * d.height) : TotalSize(d);
        const uint64_t epoch = DirtyEpoch(d.data) ^ MemSig(guest, total) ^ (pal_hash * 0xBF58476D1CE4E5B9ull);
        if (same_meta && entry.epoch == epoch) {
            entry.frame = frame_id_;
            entry.pal_hash = pal_hash;
            entry.last_used_frame = frame_id_;
            return entry.tex;
        }

        const uint64_t tex_t0 = hitch::NowUs();
        const uint32_t* pal = pal_data_va ? pal_buf : nullptr;
        const bool can_reuse = same_meta && entry.tex.pixelFormat == mtl_fmt &&
                               (entry.last_used_frame + kRingCount <= frame_id_);

        @autoreleasepool {
            if (d.cube && d.width == d.height) {
                id<MTLTexture> tex = can_reuse ? entry.tex : nil;
                if (!tex) {
                    MTLTextureDescriptor* td = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:mtl_fmt
                                                                                                     size:d.width
                                                                                                mipmapped:NO];
                    tex = [device_ newTextureWithDescriptor:td];
                    if (!tex) return nil;
                }
                for (uint32_t face = 0; face < 6; ++face) {
                    uint32_t pitch = 0;
                    DecodeLevel(d, 0, face, guest, pal, scratch_decode_, pitch);
                    if (scratch_decode_.empty() || !pitch) continue;
                    const uint8_t* src_ptr = scratch_decode_.data();
                    if (is_bc) {
                        uint32_t bgra_pitch = 0;
                        DecompressBcToBgra8(fi.host, d.width, d.height, scratch_decode_.data(), scratch_bc_, bgra_pitch);
                        src_ptr = scratch_bc_.data();
                        pitch = bgra_pitch;
                    }
                    [tex replaceRegion:MTLRegionMake2D(0, 0, d.width, d.height)
                           mipmapLevel:0
                                 slice:face
                             withBytes:src_ptr
                           bytesPerRow:pitch
                         bytesPerImage:size_t(pitch) * d.height];
                }
                entry = {tex, d.format, d.width, d.height, d.depth, epoch, pal_hash, frame_id_, frame_id_};
                return tex;
            }

            uint32_t pitch = 0;
            DecodeLevel(d, 0, 0, guest, pal, scratch_decode_, pitch);
            if (scratch_decode_.empty() || !pitch) return nil;
            const uint8_t* upload_ptr = scratch_decode_.data();
            if (is_bc) {
                if (d.depth > 1) {
                    const uint32_t bh = std::max(1u, (d.height + 3) / 4);
                    const size_t slice_in = size_t(pitch) * bh;
                    std::vector<uint8_t> vol;
                    uint32_t bgra_pitch = d.width * 4;
                    vol.reserve(size_t(bgra_pitch) * d.height * d.depth);
                    for (uint32_t z = 0; z < d.depth; ++z) {
                        DecompressBcToBgra8(fi.host, d.width, d.height, scratch_decode_.data() + z * slice_in, scratch_bc_, bgra_pitch);
                        vol.insert(vol.end(), scratch_bc_.begin(), scratch_bc_.end());
                    }
                    scratch_decode_ = std::move(vol);
                    upload_ptr = scratch_decode_.data();
                    pitch = bgra_pitch;
                } else {
                    uint32_t bgra_pitch = 0;
                    DecompressBcToBgra8(fi.host, d.width, d.height, scratch_decode_.data(), scratch_bc_, bgra_pitch);
                    upload_ptr = scratch_bc_.data();
                    pitch = bgra_pitch;
                }
            } else if (d.format == 0x24 || d.format == 0x25) {
                // Fast whole-frame blank check for uniformly filled uninitialized YUY2/UYVY buffers
                // (per-pixel BT.601 studio-range out-of-gamut sanitization already runs inside DecodeLevel).
                const uint32_t yuv_total = d.pitch * d.height;
                if (yuv_total >= 64) {
                    uint32_t dw0 = 0, dw1 = 0, dw2 = 0, dw3 = 0;
                    std::memcpy(&dw0, guest + 0, 4);
                    std::memcpy(&dw1, guest + ((yuv_total / 3) & ~3u), 4);
                    std::memcpy(&dw2, guest + ((yuv_total / 2) & ~3u), 4);
                    std::memcpy(&dw3, guest + (((yuv_total * 2) / 3) & ~3u), 4);
                    if (dw0 == dw1 && dw1 == dw2 && dw2 == dw3) {
                        const bool yuy2 = (d.format == 0x24);
                        const uint8_t b0 = dw0 & 0xFF, b1 = (dw0 >> 8) & 0xFF, b2 = (dw0 >> 16) & 0xFF, b3 = (dw0 >> 24) & 0xFF;
                        const int y0 = yuy2 ? b0 : b1, u = yuy2 ? b1 : b0, y1 = yuy2 ? b2 : b3, v = yuy2 ? b3 : b2;
                        const bool studio_black = (y0 <= 20 && y1 <= 20);
                        const bool bad_pattern = (dw0 == 0u || dw0 == 0xFFFFFFFFu || dw0 == 0xFF000000u ||
                                                  dw0 == 0x000000FFu || dw0 == 0xFF00FF00u || dw0 == 0x00FF00FFu ||
                                                  std::abs(u - 128) > 36 || std::abs(v - 128) > 36);
                        if (studio_black && bad_pattern) {
                            for (size_t i = 0; i + 3 < scratch_decode_.size(); i += 4) {
                                scratch_decode_[i + 0] = 0;
                                scratch_decode_[i + 1] = 0;
                                scratch_decode_[i + 2] = 0;
                                scratch_decode_[i + 3] = 255;
                            }
                        }
                    }
                }
            }

            id<MTLTexture> tex = can_reuse ? entry.tex : nil;
            if (d.depth > 1) {
                if (!tex) {
                    MTLTextureDescriptor* td = [[MTLTextureDescriptor alloc] init];
                    td.textureType = MTLTextureType3D;
                    td.pixelFormat = mtl_fmt;
                    td.width = d.width;
                    td.height = d.height;
                    td.depth = d.depth;
                    td.mipmapLevelCount = 1;
                    tex = [device_ newTextureWithDescriptor:td];
                    if (!tex) return nil;
                }
                [tex replaceRegion:MTLRegionMake3D(0, 0, 0, d.width, d.height, d.depth)
                       mipmapLevel:0
                             slice:0
                         withBytes:upload_ptr
                       bytesPerRow:pitch
                     bytesPerImage:size_t(pitch) * d.height];
            } else {
                if (!tex) {
                    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:mtl_fmt
                                                                                                  width:d.width
                                                                                                 height:d.height
                                                                                              mipmapped:NO];
                    tex = [device_ newTextureWithDescriptor:td];
                    if (!tex) return nil;
                }
                [tex replaceRegion:MTLRegionMake2D(0, 0, d.width, d.height)
                       mipmapLevel:0
                         withBytes:upload_ptr
                       bytesPerRow:pitch];
            }
            entry = {tex, d.format, d.width, d.height, d.depth, epoch, pal_hash, frame_id_, frame_id_};
            hitch::AddMetalTex(hitch::NowUs() - tex_t0);
            return tex;
        }
    }

    bool EnsureEncoderFor(uint32_t rt_va, uint32_t zs_va, uint32_t w, uint32_t h) {
        auto& ct = EnsureColorTarget(rt_va, w, h);
        auto& dt = EnsureDepthTarget(zs_va, w, h);
        if (!ct.tex || !dt.tex) return false;
        if (encoder_ && active_color_tex_ == ct.tex && active_depth_tex_ == dt.tex &&
            !ct.pending_clear && !dt.pending_clear) {
            active_ct_ = &ct;
            return true;
        }
        EndEncoder();
        if (!EnsureCommandBuffer()) return false;
        @autoreleasepool {
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
        }
        if (!encoder_) return false;
        active_color_tex_ = ct.tex;
        active_depth_tex_ = dt.tex;
        active_ct_ = &ct;
        ct.drawn_epoch = DirtyEpoch(rt_va);
        ct.pending_clear = false;
        dt.pending_clear = false;
        ResetEncoderState();
        if (vsc_dummy_buf_) {
            [encoder_ setVertexBuffer:vsc_dummy_buf_ offset:0 atIndex:16];
            [encoder_ setFragmentBuffer:vsc_dummy_buf_ offset:0 atIndex:16];
            bound_vs_buf16_ = vsc_dummy_buf_;
        }
        return true;
    }

    static constexpr uint32_t kRingCount = 3;
    static constexpr size_t kRingSize = 8 * 1024 * 1024;

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
    id<MTLSamplerState> aniso_sampler_ = nil;
    id<MTLSamplerState> aniso_wrap_sampler_ = nil;
    std::unordered_map<uint64_t, id<MTLRenderPipelineState>> pso_cache_;
    std::unordered_map<uint16_t, MTLVertexDescriptor*> vd_cache_;
    std::unordered_map<uint64_t, id<MTLFunction>> vs_cache_;
    std::unordered_map<uint64_t, id<MTLFunction>> fs_cache_;
    std::unordered_set<uint64_t> failed_shaders_;
    std::unordered_map<uint32_t, id<MTLDepthStencilState>> dss_cache_;
    std::unordered_map<uint64_t, CachedTex> tex_cache_;

    dispatch_semaphore_t frame_sem_ = nil;
    id<MTLBuffer> ring_buf_[kRingCount] = {};
    uint8_t* ring_ptr_[kRingCount] = {};
    uint32_t ring_idx_ = 0;
    size_t ring_off_ = 0;
    id<MTLBuffer> vsc_dummy_buf_ = nil;
    Assembled assembled_;
    std::vector<MetalVertex> scratch_verts_;
    std::vector<uint16_t> scratch_idx16_;
    std::vector<uint32_t> scratch_idx32_;
    std::vector<uint8_t> scratch_decode_;
    std::vector<uint8_t> scratch_bc_;
    uint64_t frame_id_ = 1;

    id<MTLRenderPipelineState> bound_pso_ = nil;
    id<MTLDepthStencilState> bound_dss_ = nil;
    id<MTLTexture> bound_tex_[4] = {};
    id<MTLSamplerState> bound_smp_[4] = {};
    id<MTLBuffer> bound_vs_buf0_ = nil;
    id<MTLBuffer> bound_vs_buf16_ = nil;
    id<MTLBuffer> bound_vs_buf17_ = nil;
    id<MTLBuffer> bound_fs_buf17_ = nil;
    MTLScissorRect bound_scissor_{0, 0, 0, 0};
    bool bound_scissor_valid_ = false;
    uint32_t bound_blend_color_ = 0;
    bool bound_blend_color_valid_ = false;
    std::array<float, 192 * 4> bound_vsc_{};
    bool bound_vsc_valid_ = false;

    id<MTLCommandBuffer> cmd_buf_ = nil;
    id<MTLRenderCommandEncoder> encoder_ = nil;
    id<MTLTexture> active_color_tex_ = nil;
    id<MTLTexture> active_depth_tex_ = nil;
    ColorTarget* active_ct_ = nullptr;
    id<MTLCommandBuffer> last_cmd_buf_ = nil;
};

}  // namespace

void SetMetalLayer(void* ca_metal_layer) {
    g_metal_layer = (__bridge CAMetalLayer*)ca_metal_layer;
}

uint32_t PresentedFrameCount() {
    return g_presented_frames.load(std::memory_order_relaxed);
}

void SetResolutionScale(float scale) {
    g_res_scale.store(std::clamp(scale, 1.0f, 2.0f), std::memory_order_relaxed);
}

float GetResolutionScale() {
    return g_res_scale.load(std::memory_order_relaxed);
}

void SetAnisotropicFiltering(bool enabled) {
    g_aniso_enabled.store(enabled, std::memory_order_relaxed);
}

bool GetAnisotropicFiltering() {
    return g_aniso_enabled.load(std::memory_order_relaxed);
}

void SetMotionBlurEnabled(bool enabled) {
    g_motion_blur_enabled.store(enabled, std::memory_order_relaxed);
}

bool GetMotionBlurEnabled() {
    return g_motion_blur_enabled.load(std::memory_order_relaxed);
}

void SetTargetFps(uint32_t fps) {
    g_target_fps.store((fps == 30) ? 30u : 60u, std::memory_order_relaxed);
}

uint32_t GetTargetFps() {
    return g_target_fps.load(std::memory_order_relaxed);
}

void SetMinimapConfig(const MinimapConfig& cfg) {
    std::lock_guard<std::mutex> lk(g_minimap_lock);
    g_minimap_cfg = cfg;
}

MinimapConfig GetMinimapConfig() {
    std::lock_guard<std::mutex> lk(g_minimap_lock);
    return g_minimap_cfg;
}

void ReportMinimapFrame(bool active, bool hidden, float orig_x, float orig_y, float orig_w, float orig_h, float dx, float dy) {
    std::lock_guard<std::mutex> lk(g_minimap_lock);
    g_minimap_frame.active = active;
    g_minimap_frame.hidden = hidden;
    g_minimap_frame.orig_x = orig_x;
    g_minimap_frame.orig_y = orig_y;
    g_minimap_frame.orig_w = orig_w;
    g_minimap_frame.orig_h = orig_h;
    g_minimap_frame.dx = dx;
    g_minimap_frame.dy = dy;
}

std::unique_ptr<Backend> CreateBackend() {
    return std::make_unique<MetalBackend>();
}

}  // namespace gpu
