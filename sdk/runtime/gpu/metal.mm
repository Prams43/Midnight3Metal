#include "gpu/backend.h"
#include "gpu/metal.h"
#include "gpu/texture.h"
#include "gpu/vertex.h"
#include "core/log.h"
#include "kernel/kernel.h"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <algorithm>
#include <bit>
#include <cstdint>
#include <cstring>
#include <memory>
#include <unordered_map>
#include <vector>

namespace gpu {

namespace {

CAMetalLayer* g_metal_layer = nil;

struct MetalVertex {
    float pos[4];
    float col[4];
    float uv[2];
};

static const char* kMetalPassthroughShader = R"(
#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float4 position [[attribute(0)]];
    float4 color [[attribute(1)]];
    float2 uv [[attribute(2)]];
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
    out.uv = in.uv;
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]],
                              texture2d<float> tex0 [[texture(0)]],
                              sampler samp0 [[sampler(0)]]) {
    return in.color * tex0.sample(samp0, in.uv);
}
)";

MTLBlendFactor ToMetalBlend(uint32_t d3d_blend, bool is_src) {
    // D3DBLEND values (Xbox XDK / D3D8): 1=ZERO, 2=ONE, 3=SRCCOLOR, 4=INVSRCCOLOR,
    // 5=SRCALPHA, 6=INVSRCALPHA, 7=DESTALPHA, 8=INVDESTALPHA, 9=DESTCOLOR, 10=INVDESTCOLOR
    switch (d3d_blend) {
    case 1: return MTLBlendFactorZero;
    case 2: return MTLBlendFactorOne;
    case 3: return MTLBlendFactorSourceColor;
    case 4: return MTLBlendFactorOneMinusSourceColor;
    case 5: return MTLBlendFactorSourceAlpha;
    case 6: return MTLBlendFactorOneMinusSourceAlpha;
    case 7: return MTLBlendFactorDestinationAlpha;
    case 8: return MTLBlendFactorOneMinusDestinationAlpha;
    case 9: return MTLBlendFactorDestinationColor;
    case 10: return MTLBlendFactorOneMinusDestinationColor;
    default: return is_src ? MTLBlendFactorOne : MTLBlendFactorZero;
    }
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
        vd.attributes[0].format = MTLVertexFormatFloat4;
        vd.attributes[0].offset = offsetof(MetalVertex, pos);
        vd.attributes[0].bufferIndex = 0;

        vd.attributes[1].format = MTLVertexFormatFloat4;
        vd.attributes[1].offset = offsetof(MetalVertex, col);
        vd.attributes[1].bufferIndex = 0;

        vd.attributes[2].format = MTLVertexFormatFloat2;
        vd.attributes[2].offset = offsetof(MetalVertex, uv);
        vd.attributes[2].bufferIndex = 0;

        vd.layouts[0].stride = sizeof(MetalVertex);
        vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

        vertex_desc_ = vd;
        vs_func_ = vs;
        fs_func_ = fs;

        pipeline_ = GetPipeline(false, 2, 1);
        if (!pipeline_) return false;

        // 1x1 white fallback texture for untextured draws
        MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:1
                                                                                     height:1
                                                                                  mipmapped:NO];
        white_tex_ = [device_ newTextureWithDescriptor:td];
        const uint32_t white = 0xFFFFFFFFu;
        [white_tex_ replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&white bytesPerRow:4];

        MTLSamplerDescriptor* sd = [[MTLSamplerDescriptor alloc] init];
        sd.minFilter = MTLSamplerMinMagFilterLinear;
        sd.magFilter = MTLSamplerMinMagFilterLinear;
        sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        sampler_ = [device_ newSamplerStateWithDescriptor:sd];

        LOGI("metal: backend initialized (%ux%u, device=%s)", guest_width_, guest_height_,
             [device_.name UTF8String]);
        return true;
    }

    void Clear(const State&, uint32_t, const uint8_t*, uint32_t flags, uint32_t color, float z, uint32_t) override {
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

        std::vector<MetalVertex> verts(a.vertex_count);
        const float inv_w = 2.0f / float(guest_width_);
        const float inv_h = 2.0f / float(guest_height_);

        for (uint32_t i = 0; i < a.vertex_count; ++i) {
            float p[4] = {};
            if (!read_attr(0, i, p)) return;
            if (a.pretransformed) {
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

            if (!read_attr(3, i, verts[i].col)) {
                verts[i].col[0] = 1.0f;
                verts[i].col[1] = 1.0f;
                verts[i].col[2] = 1.0f;
                verts[i].col[3] = 1.0f;
            }

            float uv[4] = {0.0f, 0.0f, 0.0f, 1.0f};
            read_attr(9, i, uv);
            verts[i].uv[0] = uv[0];
            verts[i].uv[1] = uv[1];
        }

        if (!EnsureEncoder()) return;

        const bool blend_on = s.simple[kMBlendEnable / 4] != 0;
        const uint32_t src_b = s.simple[kMSrcBlend / 4];
        const uint32_t dst_b = s.simple[kMDestBlend / 4];
        id<MTLRenderPipelineState> pso = GetPipeline(blend_on, src_b, dst_b);
        if (!pso) return;

        const bool z_en = s.rs[kRsZEnable] != 0;
        const bool z_wr = s.simple[kMZWriteEnable / 4] != 0;
        const uint32_t z_fn = s.simple[kMZFunc / 4];
        id<MTLDepthStencilState> dss = GetDepthStencil(z_en, z_wr, z_fn);

        id<MTLTexture> tex0 = s.textures[0] ? ResolveTexture(s.textures[0], s.palettes[0]) : white_tex_;
        if (!tex0) tex0 = white_tex_;

        const size_t vb_bytes = verts.size() * sizeof(MetalVertex);
        id<MTLBuffer> vb = [device_ newBufferWithBytes:verts.data()
                                               length:vb_bytes
                                              options:MTLResourceStorageModeShared];
        if (!vb) return;

        [encoder_ setRenderPipelineState:pso];
        if (dss) [encoder_ setDepthStencilState:dss];
        [encoder_ setFragmentTexture:tex0 atIndex:0];
        [encoder_ setFragmentSamplerState:sampler_ atIndex:0];
        [encoder_ setVertexBuffer:vb offset:0 atIndex:0];

        const MTLPrimitiveType mtl_prim = ToMetalPrimitive(a.topology, a.strip);
        if (a.index_count > 0 && !a.indices.empty()) {
            id<MTLBuffer> ib = [device_ newBufferWithBytes:a.indices.data()
                                                   length:a.indices.size() * sizeof(uint32_t)
                                                  options:MTLResourceStorageModeShared];
            if (ib) {
                [encoder_ drawIndexedPrimitives:mtl_prim
                                     indexCount:a.index_count
                                      indexType:MTLIndexTypeUInt32
                                    indexBuffer:ib
                              indexBufferOffset:0];
            }
        } else {
            [encoder_ drawPrimitives:mtl_prim vertexStart:0 vertexCount:a.draw_count];
        }
    }

    void Copy(const Surface&, const Surface&, uint32_t, uint32_t, uint32_t) override {}

    void Present(const Surface&) override {
        if (!layer_ || !queue_) return;
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
    }

    void Sync(uint32_t, uint32_t) override {}
    void SyncLate(uint32_t) override {}

    void Flush() override {
        if (last_cmd_buf_) {
            [last_cmd_buf_ waitUntilCompleted];
            last_cmd_buf_ = nil;
        }
    }

    void SetGamma(const uint8_t*) override {}

private:
    struct CachedTex {
        id<MTLTexture> tex = nil;
        uint32_t format = 0;
        uint32_t w = 0, h = 0;
        uint64_t epoch = ~0ull;
    };

    id<MTLRenderPipelineState> GetPipeline(bool blend, uint32_t src_b, uint32_t dst_b) {
        const uint64_t key = (uint64_t(blend) << 32) | (uint64_t(src_b) << 16) | uint64_t(dst_b);
        if (auto it = pso_cache_.find(key); it != pso_cache_.end()) return it->second;

        MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.vertexFunction = vs_func_;
        desc.fragmentFunction = fs_func_;
        desc.vertexDescriptor = vertex_desc_;
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        if (blend) {
            desc.colorAttachments[0].blendingEnabled = YES;
            desc.colorAttachments[0].sourceRGBBlendFactor = ToMetalBlend(src_b, true);
            desc.colorAttachments[0].destinationRGBBlendFactor = ToMetalBlend(dst_b, false);
            desc.colorAttachments[0].sourceAlphaBlendFactor = ToMetalBlend(src_b, true);
            desc.colorAttachments[0].destinationAlphaBlendFactor = ToMetalBlend(dst_b, false);
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

    id<MTLTexture> ResolveTexture(uint32_t header_va, uint32_t palette_va) {
        TextureDesc d;
        if (!Describe(header_va, d) || !d.data || !d.width || !d.height) return nil;
        const auto& fi = Format(d.format);
        MTLPixelFormat mtl_fmt = MTLPixelFormatBGRA8Unorm;
        if (fi.host == Host::R32F) mtl_fmt = MTLPixelFormatR32Float;
        else if (fi.host == Host::R16Unorm) mtl_fmt = MTLPixelFormatR16Unorm;
        else if (fi.host != Host::BGRA8) return nil;

        const uint64_t epoch = DirtyEpoch(d.data);
        auto& entry = tex_cache_[d.data];
        if (entry.tex && entry.format == d.format && entry.w == d.width && entry.h == d.height &&
            entry.epoch == epoch) {
            return entry.tex;
        }

        const uint8_t* guest = static_cast<const uint8_t*>(kernel::HostPtr(d.data));
        const uint32_t* pal = palette_va ? static_cast<const uint32_t*>(kernel::HostPtr(palette_va)) : nullptr;
        std::vector<uint8_t> decoded;
        uint32_t pitch = 0;
        DecodeLevel(d, 0, 0, guest, pal, decoded, pitch);
        if (decoded.empty() || !pitch) return nil;

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
        pass.colorAttachments[0].loadAction = has_clear_ ? MTLLoadActionClear : MTLLoadActionLoad;
        pass.colorAttachments[0].clearColor = clear_color_;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        if (depth_tex_) {
            pass.depthAttachment.texture = depth_tex_;
            pass.depthAttachment.loadAction = has_depth_clear_ ? MTLLoadActionClear : MTLLoadActionLoad;
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
    CAMetalLayer* layer_ = nil;
    id<MTLDevice> device_ = nil;
    id<MTLCommandQueue> queue_ = nil;
    id<MTLFunction> vs_func_ = nil;
    id<MTLFunction> fs_func_ = nil;
    MTLVertexDescriptor* vertex_desc_ = nil;
    id<MTLRenderPipelineState> pipeline_ = nil;
    id<MTLTexture> white_tex_ = nil;
    id<MTLTexture> depth_tex_ = nil;
    id<MTLSamplerState> sampler_ = nil;
    std::unordered_map<uint64_t, id<MTLRenderPipelineState>> pso_cache_;
    std::unordered_map<uint32_t, id<MTLDepthStencilState>> dss_cache_;
    std::unordered_map<uint32_t, CachedTex> tex_cache_;

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
