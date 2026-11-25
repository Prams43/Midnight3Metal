#include "gpu/backend.h"
#include "gpu/metal.h"
#include "gpu/vertex.h"
#include "core/log.h"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <algorithm>
#include <bit>
#include <cstdint>
#include <cstring>
#include <memory>
#include <vector>

namespace gpu {

namespace {

CAMetalLayer* g_metal_layer = nil;

struct MetalVertex {
    float pos[4];
    float col[4];
};

static const char* kMetalPassthroughShader = R"(
#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float4 position [[attribute(0)]];
    float4 color [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
};

vertex VertexOut vertex_main(VertexIn in [[stage_in]]) {
    VertexOut out;
    out.position = in.position;
    out.color = in.color;
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]]) {
    return in.color;
}
)";

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

        vd.layouts[0].stride = sizeof(MetalVertex);
        vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

        MTLRenderPipelineDescriptor* psoDesc = [[MTLRenderPipelineDescriptor alloc] init];
        psoDesc.vertexFunction = vs;
        psoDesc.fragmentFunction = fs;
        psoDesc.vertexDescriptor = vd;
        psoDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

        pipeline_ = [device_ newRenderPipelineStateWithDescriptor:psoDesc error:&err];
        if (!pipeline_) {
            LOGE("metal: pipeline creation failed: %s", [[err localizedDescription] UTF8String]);
            return false;
        }

        LOGI("metal: backend initialized (%ux%u, device=%s)", guest_width_, guest_height_,
             [device_.name UTF8String]);
        return true;
    }

    void Clear(const State&, uint32_t, const uint8_t*, uint32_t flags, uint32_t color, float, uint32_t) override {
        if (flags & kClearTarget) {
            const double a = ((color >> 24) & 0xFF) / 255.0;
            const double r = ((color >> 16) & 0xFF) / 255.0;
            const double g = ((color >> 8) & 0xFF) / 255.0;
            const double b = (color & 0xFF) / 255.0;
            clear_color_ = MTLClearColorMake(r, g, b, a);
            has_clear_ = true;
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
                verts[i].pos[0] = p[0];
                verts[i].pos[1] = p[1];
                verts[i].pos[2] = p[2];
                verts[i].pos[3] = p[3] != 0.0f ? p[3] : 1.0f;
            }

            if (!read_attr(3, i, verts[i].col)) {
                verts[i].col[0] = 1.0f;
                verts[i].col[1] = 1.0f;
                verts[i].col[2] = 1.0f;
                verts[i].col[3] = 1.0f;
            }
        }

        if (!EnsureEncoder()) return;

        const size_t vb_bytes = verts.size() * sizeof(MetalVertex);
        id<MTLBuffer> vb = [device_ newBufferWithBytes:verts.data()
                                               length:vb_bytes
                                              options:MTLResourceStorageModeShared];
        if (!vb) return;

        [encoder_ setRenderPipelineState:pipeline_];
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
    bool EnsureEncoder() {
        if (encoder_) return true;
        drawable_ = [layer_ nextDrawable];
        if (!drawable_) return false;
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
    id<MTLRenderPipelineState> pipeline_ = nil;

    id<CAMetalDrawable> drawable_ = nil;
    id<MTLCommandBuffer> cmd_buf_ = nil;
    id<MTLRenderCommandEncoder> encoder_ = nil;
    id<MTLCommandBuffer> last_cmd_buf_ = nil;
    MTLClearColor clear_color_ = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    bool has_clear_ = true;
};

}  // namespace

void SetMetalLayer(void* ca_metal_layer) {
    g_metal_layer = (__bridge CAMetalLayer*)ca_metal_layer;
}

std::unique_ptr<Backend> CreateBackend() {
    return std::make_unique<MetalBackend>();
}

}  // namespace gpu
