import Foundation
import Metal

public enum RasterComputeBackend: String, Sendable { case automatic, cpu, metal }

/// Float display calculations only. Coordinates and measurement totals remain Double.
public enum RasterCompute {
    public static let metalAvailable = MetalRasterEngine.shared != nil
    private static let preference = RasterComputeBackend(rawValue: ProcessInfo.processInfo.environment["EUCLID_COMPUTE_BACKEND"] ?? "") ?? .automatic
    private static func engine(_ backend: RasterComputeBackend, count: Int, acceleratesAutomatically: Bool = true) -> MetalRasterEngine? {
        let chosen = backend == .automatic ? preference : backend
        guard chosen != .cpu, !Task.isCancelled,
              chosen == .metal || (acceleratesAutomatically && count >= 1_000_000 && !Thread.isMainThread) else { return nil }
        return MetalRasterEngine.shared
    }
    public static func slope(values: [Float], width: Int, height: Int, spacing: Double,
                             backend: RasterComputeBackend = .automatic) -> [Float]? {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384, values.count == width * height,
              spacing.isFinite, spacing > 0 else { return nil }
        if let engine = engine(backend, count: values.count), spacing <= Double(Float.greatestFiniteMagnitude) / 2, Float(spacing).isFinite, Float(spacing) > 0,
           let output: [Float] = engine.run("slope", inputs: [values], dimensions: [UInt32(width), UInt32(height)],
                                            scale: Float(spacing), count: values.count) { return output }
        var output = [Float](repeating: .nan, count: values.count)
        for row in 0..<height {
            if Task.isCancelled { return nil }
            for column in 0..<width {
                let index = row * width + column, center = values[index]
                guard center.isFinite else { continue }
                let left = column > 0 ? values[index - 1] : .nan
                let right = column + 1 < width ? values[index + 1] : .nan
                let before = row > 0 ? values[index - width] : .nan
                let after = row + 1 < height ? values[index + width] : .nan
                func derivative(_ a: Float, _ b: Float) -> Double? {
                    if a.isFinite, b.isFinite { return (Double(b) - Double(a)) / (2 * spacing) }
                    if b.isFinite { return (Double(b) - Double(center)) / spacing }
                    if a.isFinite { return (Double(center) - Double(a)) / spacing }
                    return nil
                }
                if let x = derivative(left, right), let y = derivative(before, after) {
                    output[index] = Float(atan((x * x + y * y).squareRoot()) * 180 / .pi)
                }
            }
        }
        return output
    }
    /// Latitude-dependent row metrics keep the common north-up case compact on CPU and GPU.
    package static func slope(values: [Float], width: Int, height: Int,
                              rowMetrics: [RasterGroundMetric], backend: RasterComputeBackend = .automatic) -> [Float]? {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              values.count == width * height, rowMetrics.count == height else { return nil }
        if let engine = engine(backend, count: values.count) {
            var coefficients: [Float] = []
            coefficients.reserveCapacity(height * 4)
            for metric in rowMetrics {
                guard let c = metric.inverseBasis else { return nil }
                coefficients.append(contentsOf: [Float(c.0), Float(c.1), Float(c.2), Float(c.3)])
            }
            if coefficients.allSatisfy({ $0.isFinite }),
               let output: [Float] = engine.run("slope_metric", inputs: [values, coefficients],
                                               dimensions: [UInt32(width), UInt32(height)], scale: 1, count: values.count) {
                return output
            }
        }
        return slope(values: values, width: width, height: height) { _, row in rowMetrics[row] }
    }

    /// A general affine/projection metric can vary in both directions; keep coordinate work in Double.
    package static func slope(values: [Float], width: Int, height: Int,
                              metric: (Int, Int) -> RasterGroundMetric?) -> [Float]? {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              values.count == width * height else { return nil }
        var output = [Float](repeating: .nan, count: values.count)
        for row in 0..<height {
            if Task.isCancelled { return nil }
            for column in 0..<width {
                let index = row * width + column, center = values[index]
                guard center.isFinite else { continue }
                func derivative(_ before: Float, _ after: Float) -> Double? {
                    if before.isFinite, after.isFinite { return (Double(after) - Double(before)) / 2 }
                    if after.isFinite { return Double(after) - Double(center) }
                    if before.isFinite { return Double(center) - Double(before) }
                    return nil
                }
                guard let dx = derivative(column > 0 ? values[index - 1] : .nan,
                                          column + 1 < width ? values[index + 1] : .nan),
                      let dy = derivative(row > 0 ? values[index - width] : .nan,
                                          row + 1 < height ? values[index + width] : .nan),
                      let c = metric(column, row)?.inverseBasis else { continue }
                let east = c.0 * dx + c.1 * dy
                let north = c.2 * dx + c.3 * dy
                output[index] = Float(atan(hypot(east, north)) * 180 / .pi)
            }
        }
        return output
    }

    /// Returns idle shared Metal buffers under memory pressure; active command buffers own theirs.
    public static func trimMetalBuffers() { MetalRasterEngine.shared?.trimBuffers() }
    package static var metalBufferStatistics: (allocations: Int, reuses: Int, idleBytes: Int) {
        MetalRasterEngine.shared?.bufferStatistics ?? (0, 0, 0)
    }

    public static func differences(first: [Float], firstWidth: Int, firstHeight: Int,
                                   second: [Float], secondWidth: Int, secondHeight: Int,
                                   width: Int, height: Int, backend: RasterComputeBackend = .automatic) -> [Float]? {
        let dimensions = [firstWidth, firstHeight, secondWidth, secondHeight, width, height]
        guard dimensions.allSatisfy({ $0 > 0 && $0 <= 16_384 }),
              first.count == firstWidth * firstHeight, second.count == secondWidth * secondHeight else { return nil }
        let count = width * height
        if let engine = engine(backend, count: count, acceleratesAutomatically: false),
           let output: [Float] = engine.run("difference", inputs: [first, second], dimensions: dimensions.map(UInt32.init), scale: 1, count: count) { return output }
        var output = [Float](repeating: .nan, count: count)
        for row in 0..<height {
            if Task.isCancelled { return nil }
            for column in 0..<width {
                let a = first[(row * firstHeight / height) * firstWidth + column * firstWidth / width]
                let b = second[(row * secondHeight / height) * secondWidth + column * secondWidth / width]
                if a.isFinite, b.isFinite { output[row * width + column] = a - b }
            }
        }
        return output
    }
    public static func color(values: [Float], scale: Double, difference: Bool,
                             backend: RasterComputeBackend = .automatic) -> [UInt8]? {
        guard scale.isFinite, scale > 0, values.count <= 64_000_000 else { return nil }
        if Float(scale).isFinite, Float(scale) > 0, let engine = engine(backend, count: values.count),
           let output: [UInt8] = engine.run("colorize", inputs: [values], dimensions: [UInt32(values.count), difference ? 1 : 0], scale: Float(scale), count: values.count, bytesPerElement: 4) { return output }
        var output = [UInt8](repeating: 0, count: values.count * 4)
        for index in values.indices {
            if index % 4096 == 0, Task.isCancelled { return nil }
            guard values[index].isFinite else { continue }
            let t = min(max(Double(values[index]) / scale, difference ? -1 : 0), 1)
            let color = difference ? (t >= 0 ? (230.0, 74.0, 54.0) : (46.0, 116.0, 230.0)) : DEMAnalysis.terrainColor(t)
            let alpha = UInt8(min(235, (difference ? 40 : 60) + abs(t) * (difference ? 195 : 175)))
            DEMAnalysis.write(&output, at: index, color, alpha: alpha)
        }
        return output
    }
}

private final class MetalRasterEngine: @unchecked Sendable {
    static let shared = MetalRasterEngine()
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let pipelines: [String: any MTLComputePipelineState]
    private let bufferLock = NSLock()
    private var idleBuffers: [any MTLBuffer] = []
    private var idleBytes = 0
    private var allocations = 0
    private var reuses = 0
    private var bufferGeneration: UInt64 = 0
    #if os(iOS)
    private let maximumIdleBytes = 16 << 20
    #else
    private let maximumIdleBytes = 64 << 20
    #endif
    var bufferStatistics: (allocations: Int, reuses: Int, idleBytes: Int) {
        bufferLock.withLock { (allocations, reuses, idleBytes) }
    }
    func trimBuffers() {
        bufferLock.withLock {
            idleBuffers.removeAll()
            idleBytes = 0
            bufferGeneration &+= 1
        }
    }
    private func borrow(length: Int) -> (buffer: any MTLBuffer, generation: UInt64)? {
        let state: ((any MTLBuffer)?, UInt64) = bufferLock.withLock {
            if let index = idleBuffers.firstIndex(where: { $0.length >= length && $0.length <= length * 2 }) {
                let buffer = idleBuffers.remove(at: index)
                idleBytes -= buffer.length
                reuses += 1
                return (buffer, bufferGeneration)
            }
            return (nil, bufferGeneration)
        }
        if let buffer = state.0 { return (buffer, state.1) }
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
        bufferLock.withLock { allocations += 1 }
        return (buffer, state.1)
    }
    private func recycle(_ buffer: any MTLBuffer, generation: UInt64) {
        bufferLock.withLock {
            guard generation == bufferGeneration, idleBuffers.count < 12,
                  buffer.length <= maximumIdleBytes - idleBytes else { return }
            idleBuffers.append(buffer)
            idleBytes += buffer.length
        }
    }
    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), device.hasUnifiedMemory,
              let queue = device.makeCommandQueue() else { return nil }
        let options = MTLCompileOptions()
        options.fastMathEnabled = false
        guard let library = try? device.makeLibrary(source: Self.source, options: options) else { return nil }
        var pipelines: [String: any MTLComputePipelineState] = [:]
        for name in ["slope", "slope_metric", "difference", "colorize"] {
            guard let function = library.makeFunction(name: name), let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
            pipelines[name] = pipeline
        }
        self.device = device; self.queue = queue; self.pipelines = pipelines
    }
    func run<T>(_ name: String, inputs: [[Float]], dimensions: [UInt32], scale: Float,
                count: Int, bytesPerElement: Int = 4) -> [T]? {
        guard count > 0, count <= 64_000_000, !Task.isCancelled, let pipeline = pipelines[name] else { return nil }
        return TilePerformance.measure("Metal raster compute") {
            var borrowed: [(buffer: any MTLBuffer, generation: UInt64)] = []
            defer { for entry in borrowed { recycle(entry.buffer, generation: entry.generation) } }
            for input in inputs {
                guard let entry = borrow(length: input.count * MemoryLayout<Float>.stride) else { return nil }
                input.withUnsafeBytes { bytes in
                    if let base = bytes.baseAddress { entry.buffer.contents().copyMemory(from: base, byteCount: bytes.count) }
                }
                borrowed.append(entry)
            }
            guard !borrowed.isEmpty, let outputEntry = borrow(length: count * bytesPerElement) else { return nil }
            borrowed.append(outputEntry)
            let buffers = borrowed.dropLast().map(\.buffer)
            let output = outputEntry.buffer
            guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { return nil }
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(buffers[0], offset: 0, index: 0)
            encoder.setBuffer(buffers.count > 1 ? buffers[1] : buffers[0], offset: 0, index: 1)
            encoder.setBuffer(output, offset: 0, index: 2)
            dimensions.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 3) }
            var scalar = scale
            encoder.setBytes(&scalar, length: MemoryLayout<Float>.size, index: 4)
            let size = min(pipeline.maxTotalThreadsPerThreadgroup, max(32, pipeline.threadExecutionWidth * 4))
            encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: size, height: 1, depth: 1))
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            guard command.status == .completed, !Task.isCancelled else { return nil }
            let length = count * bytesPerElement / MemoryLayout<T>.stride
            return Array(UnsafeBufferPointer(start: output.contents().assumingMemoryBound(to: T.self), count: length))
        }
    }
    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    float derivative(float center, float before, float after, float spacing) {
        if(isfinite(before) && isfinite(after)) return (after-before)/(2*spacing);
        if(isfinite(after)) return (after-center)/spacing;
        if(isfinite(before)) return (center-before)/spacing;
        return NAN;
    }
    kernel void slope(device const float* a [[buffer(0)]], device const float* b [[buffer(1)]],
        device float* out [[buffer(2)]], constant uint* d [[buffer(3)]], constant float& spacing [[buffer(4)]], uint i [[thread_position_in_grid]]) {
        uint w=d[0],h=d[1],x=i%w,y=i/w; if(i>=w*h) return;
        float c=a[i]; if(!isfinite(c)) { out[i]=NAN; return; }
        float dx=derivative(c,x>0?a[i-1]:NAN,x+1<w?a[i+1]:NAN,spacing);
        float dy=derivative(c,y>0?a[i-w]:NAN,y+1<h?a[i+w]:NAN,spacing);
        out[i]=!isnan(dx)&&!isnan(dy) ? atan(length(float2(dx,dy)))*57.29577951308232f : NAN;
    }
    kernel void slope_metric(device const float* a [[buffer(0)]], device const float4* metric [[buffer(1)]],
        device float* out [[buffer(2)]], constant uint* d [[buffer(3)]], constant float& scale [[buffer(4)]], uint i [[thread_position_in_grid]]) {
        uint w=d[0],h=d[1],x=i%w,y=i/w; if(i>=w*h) return;
        float c=a[i]; if(!isfinite(c)) { out[i]=NAN; return; }
        float dx=derivative(c,x>0?a[i-1]:NAN,x+1<w?a[i+1]:NAN,1.0f);
        float dy=derivative(c,y>0?a[i-w]:NAN,y+1<h?a[i+w]:NAN,1.0f);
        float4 g=metric[y];
        float2 gradient=float2(dot(g.xy,float2(dx,dy)),dot(g.zw,float2(dx,dy)));
        out[i]=!isnan(dx)&&!isnan(dy) ? atan(length(gradient))*57.29577951308232f : NAN;
    }
    kernel void difference(device const float* a [[buffer(0)]], device const float* b [[buffer(1)]],
        device float* out [[buffer(2)]], constant uint* d [[buffer(3)]], constant float& scale [[buffer(4)]], uint i [[thread_position_in_grid]]) {
        uint w=d[4],h=d[5]; if(i>=w*h) return; uint x=i%w,y=i/w;
        float av=a[(y*d[1]/h)*d[0]+x*d[0]/w],bv=b[(y*d[3]/h)*d[2]+x*d[2]/w];
        out[i]=isfinite(av)&&isfinite(bv) ? av-bv : NAN;
    }
    kernel void colorize(device const float* a [[buffer(0)]], device const float* b [[buffer(1)]],
        device uchar4* out [[buffer(2)]], constant uint* d [[buffer(3)]], constant float& scale [[buffer(4)]], uint i [[thread_position_in_grid]]) {
        if(i>=d[0]) return; if(!isfinite(a[i])) { out[i]=uchar4(0); return; }
        bool diff=d[1]!=0; float t=clamp(a[i]/scale,diff?-1.0f:0.0f,1.0f); float3 c;
        if(diff) c=t>=0?float3(230,74,54):float3(46,116,230);
        else if(t<0.5f) c=mix(float3(56,142,60),float3(255,213,79),t*2);
        else c=mix(float3(255,213,79),float3(211,47,47),(t-0.5f)*2);
        uchar alpha=uchar(min(235.0f,(diff?40.0f:60.0f)+abs(t)*(diff?195.0f:175.0f)));
        out[i]=uchar4(uchar3(round(c*(float(alpha)/255.0f))),alpha);
    }
    """
}
