import CoreVideo
import Darwin
import Foundation
import Metal

struct MonitorOSDamageRefinementResult {
    let decision: MonitorOSDamageDecision
    let durationSeconds: Double
    let applied: Bool
    let changedPairCount: Int
    let changedWireByteCount: Int
    let meanWireByteDelta: Double
    let maxWireByteDelta: Int
}

private struct MonitorOSTileRunKey: Hashable {
    let x: Int
    let width: Int
}

func monitorOSDamageRegionsFromTileFlags(
    _ flags: [UInt32],
    tileSize: Int = 64,
    frameWidth: Int = YUV422Converter.width,
    frameHeight: Int = YUV422Converter.height,
    maximumRegions: Int? = nil
) -> [MonitorOSDamageRegion] {
    precondition(tileSize > 0)
    precondition(frameWidth > 0)
    precondition(frameHeight > 0)
    if let maximumRegions {
        precondition(maximumRegions > 0)
    }

    let baseColumns = (frameWidth + tileSize - 1) / tileSize
    let baseRows = (frameHeight + tileSize - 1) / tileSize
    precondition(flags.count == baseColumns * baseRows)

    var groupFactor = 1
    while true {
        let regions = monitorOSDamageRegionsFromGroupedTileFlags(
            flags,
            baseTileSize: tileSize,
            groupFactor: groupFactor,
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            baseColumns: baseColumns,
            baseRows: baseRows
        )

        guard let maximumRegions,
              regions.count > maximumRegions else {
            return regions
        }

        groupFactor *= 2
    }
}

private func monitorOSDamageRegionsFromGroupedTileFlags(
    _ flags: [UInt32],
    baseTileSize: Int,
    groupFactor: Int,
    frameWidth: Int,
    frameHeight: Int,
    baseColumns: Int,
    baseRows: Int
) -> [MonitorOSDamageRegion] {
    let groupedColumns =
        (baseColumns + groupFactor - 1) / groupFactor
    let groupedRows =
        (baseRows + groupFactor - 1) / groupFactor
    let groupedTileSize = baseTileSize * groupFactor

    func groupChanged(row: Int, column: Int) -> Bool {
        let baseRowStart = row * groupFactor
        let baseColumnStart = column * groupFactor
        let baseRowEnd = min(baseRows, baseRowStart + groupFactor)
        let baseColumnEnd = min(
            baseColumns,
            baseColumnStart + groupFactor
        )

        for baseRow in baseRowStart..<baseRowEnd {
            let rowOffset = baseRow * baseColumns
            for baseColumn in baseColumnStart..<baseColumnEnd
            where flags[rowOffset + baseColumn] != 0 {
                return true
            }
        }
        return false
    }

    var regions: [MonitorOSDamageRegion] = []
    var activeRuns: [MonitorOSTileRunKey: Int] = [:]

    for row in 0..<groupedRows {
        var currentRuns: [MonitorOSTileRunKey: Int] = [:]
        var column = 0

        while column < groupedColumns {
            guard groupChanged(row: row, column: column) else {
                column += 1
                continue
            }

            let runStart = column
            repeat {
                column += 1
            } while column < groupedColumns
                && groupChanged(row: row, column: column)

            let x = runStart * groupedTileSize
            let xEnd = min(frameWidth, column * groupedTileSize)
            let y = row * groupedTileSize
            let yEnd = min(frameHeight, y + groupedTileSize)
            let key = MonitorOSTileRunKey(
                x: x,
                width: xEnd - x
            )

            if let existingIndex = activeRuns[key] {
                let existing = regions[existingIndex]
                regions[existingIndex] = MonitorOSDamageRegion(
                    x: existing.x,
                    y: existing.y,
                    width: existing.width,
                    height: existing.height + (yEnd - y)
                )
                currentRuns[key] = existingIndex
            } else {
                regions.append(
                    MonitorOSDamageRegion(
                        x: x,
                        y: y,
                        width: xEnd - x,
                        height: yEnd - y
                    )
                )
                currentRuns[key] = regions.count - 1
            }
        }

        activeRuns = currentRuns
    }

    return regions
}

final class YUV422Converter: @unchecked Sendable {
    static let width = 5120
    static let height = 2880
    static let stride = width * 2
    static let byteCount = stride * height

    private static let tileSize = 64
    private static let tileColumns = width / tileSize
    private static let tileRows = height / tileSize
    private static let tileCount = tileColumns * tileRows
    private static let refinementThresholdPixels =
        width * height / 4
    private static let maximumRefinementRegions = 64

    private struct ShaderRegion {
        var x: UInt32
        var y: UInt32
        var width: UInt32
        var height: UInt32
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct DamageRegion {
        uint x;
        uint y;
        uint width;
        uint height;
    };

    inline uchar pack_unorm(float value)
    {
        return uchar(clamp(value * 255.0f + 0.5f, 0.0f, 255.0f));
    }

    kernel void bgra_to_yuv422(
        texture2d<float, access::read> source [[texture(0)]],
        device uchar4 *destination [[buffer(0)]],
        constant DamageRegion &region [[buffer(1)]],
        uint2 position [[thread_position_in_grid]])
    {
        const uint pairsWide = region.width / 2u;
        if (position.x >= pairsWide || position.y >= region.height) {
            return;
        }

        const uint x = region.x + position.x * 2u;
        const uint y = region.y + position.y;

        const float3 rgb0 = source.read(uint2(x, y)).rgb;
        const float3 rgb1 = source.read(uint2(x + 1u, y)).rgb;
        const float3 chromaRGB = (rgb0 + rgb1) * 0.5f;

        const float y0 = dot(
            rgb0,
            float3(0.2126f, 0.7152f, 0.0722f)
        );
        const float y1 = dot(
            rgb1,
            float3(0.2126f, 0.7152f, 0.0722f)
        );
        const float cb =
            dot(
                chromaRGB,
                float3(-0.114572f, -0.385428f, 0.5f)
            ) + 0.5f;
        const float cr =
            dot(
                chromaRGB,
                float3(0.5f, -0.454153f, -0.045847f)
            ) + 0.5f;

        const uint pairIndex =
            y * 2560u + x / 2u;
        destination[pairIndex] = uchar4(
            pack_unorm(y0),
            pack_unorm(cb),
            pack_unorm(y1),
            pack_unorm(cr)
        );
    }

    kernel void mark_changed_tiles(
        device const uchar4 *current [[buffer(0)]],
        device const uchar4 *reference [[buffer(1)]],
        device uint *tileMetrics [[buffer(2)]],
        constant DamageRegion *regions [[buffer(3)]],
        constant uint &regionCount [[buffer(4)]],
        uint threadIndex [[thread_index_in_threadgroup]],
        uint3 groupPosition [[threadgroup_position_in_grid]])
    {
        constexpr uint tileSize = 64u;
        constexpr uint tilesWide = 80u;
        constexpr uint tilesHigh = 45u;
        constexpr uint tileCount = tilesWide * tilesHigh;
        constexpr uint frameWidth = 5120u;
        constexpr uint frameHeight = 2880u;
        constexpr uint pairsPerRow = frameWidth / 2u;

        const uint tileIndex = groupPosition.x;
        if (tileIndex >= tileCount) {
            return;
        }

        threadgroup uint rowChangedPairs[tileSize];
        threadgroup uint rowChangedBytes[tileSize];
        threadgroup uint rowDeltaSums[tileSize];
        threadgroup uint rowMaxDeltas[tileSize];
        threadgroup uint tileCandidate;

        const uint tileColumn = tileIndex % tilesWide;
        const uint tileRow = tileIndex / tilesWide;
        const uint x0 = tileColumn * tileSize;
        const uint y0 = tileRow * tileSize;
        const uint x1 = min(x0 + tileSize, frameWidth);
        const uint y1 = min(y0 + tileSize, frameHeight);

        if (threadIndex == 0u) {
            tileCandidate = 0u;
            for (uint i = 0u; i < regionCount; ++i) {
                const DamageRegion region = regions[i];
                const uint regionX1 = region.x + region.width;
                const uint regionY1 = region.y + region.height;
                if (x0 < regionX1 && region.x < x1 &&
                    y0 < regionY1 && region.y < y1) {
                    tileCandidate = 1u;
                    break;
                }
            }
        }

        rowChangedPairs[threadIndex] = 0u;
        rowChangedBytes[threadIndex] = 0u;
        rowDeltaSums[threadIndex] = 0u;
        rowMaxDeltas[threadIndex] = 0u;
        threadgroup_barrier(mem_flags::mem_threadgroup);

        if (tileCandidate != 0u) {
            const uint y = y0 + threadIndex;
            if (y < y1) {
                uint changedPairs = 0u;
                uint changedBytes = 0u;
                uint deltaSum = 0u;
                uint maxDelta = 0u;

                for (uint x = x0; x < x1; x += 2u) {
                    const uint pairIndex = y * pairsPerRow + x / 2u;
                    const uchar4 now = current[pairIndex];
                    const uchar4 before = reference[pairIndex];
                    const uint4 delta = uint4(
                        abs(int(now.x) - int(before.x)),
                        abs(int(now.y) - int(before.y)),
                        abs(int(now.z) - int(before.z)),
                        abs(int(now.w) - int(before.w))
                    );

                    const uint pairMax = max(
                        max(delta.x, delta.y),
                        max(delta.z, delta.w)
                    );
                    if (pairMax != 0u) {
                        changedPairs += 1u;
                        if (delta.x != 0u) {
                            changedBytes += 1u;
                            deltaSum += delta.x;
                        }
                        if (delta.y != 0u) {
                            changedBytes += 1u;
                            deltaSum += delta.y;
                        }
                        if (delta.z != 0u) {
                            changedBytes += 1u;
                            deltaSum += delta.z;
                        }
                        if (delta.w != 0u) {
                            changedBytes += 1u;
                            deltaSum += delta.w;
                        }
                        maxDelta = max(maxDelta, pairMax);
                    }
                }

                rowChangedPairs[threadIndex] = changedPairs;
                rowChangedBytes[threadIndex] = changedBytes;
                rowDeltaSums[threadIndex] = deltaSum;
                rowMaxDeltas[threadIndex] = maxDelta;
            }
        }

        threadgroup_barrier(mem_flags::mem_threadgroup);

        if (threadIndex == 0u) {
            uint changedPairs = 0u;
            uint changedBytes = 0u;
            uint deltaSum = 0u;
            uint maxDelta = 0u;
            for (uint i = 0u; i < tileSize; ++i) {
                changedPairs += rowChangedPairs[i];
                changedBytes += rowChangedBytes[i];
                deltaSum += rowDeltaSums[i];
                maxDelta = max(maxDelta, rowMaxDeltas[i]);
            }

            tileMetrics[tileIndex] = changedPairs;
            tileMetrics[tileCount + tileIndex] = changedBytes;
            tileMetrics[tileCount * 2u + tileIndex] = deltaSum;
            tileMetrics[tileCount * 3u + tileIndex] = maxDelta;
        }
    }

    kernel void copy_yuv422_region(
        device const uchar4 *source [[buffer(0)]],
        device uchar4 *destination [[buffer(1)]],
        constant DamageRegion &region [[buffer(2)]],
        uint2 position [[thread_position_in_grid]])
    {
        const uint pairsWide = region.width / 2u;
        if (position.x >= pairsWide || position.y >= region.height) {
            return;
        }

        const uint x = region.x + position.x * 2u;
        const uint y = region.y + position.y;
        const uint pairIndex = y * 2560u + x / 2u;
        destination[pairIndex] = source[pairIndex];
    }
    """

    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let diffPipeline: MTLComputePipelineState
    private let referenceCopyPipeline: MTLComputePipelineState
    private let outputBuffer: MTLBuffer
    private let referenceBuffer: MTLBuffer
    private let tileMetricsBuffer: MTLBuffer
    private let textureCache: CVMetalTextureCache
    private let threadsPerThreadgroup: MTLSize
    private var referenceReady = false

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MonitorOSCaptureError(
                "Metal is unavailable for BGRA->4:2:2 conversion"
            )
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw MonitorOSCaptureError(
                "failed to create Metal command queue for BGRA->4:2:2 conversion"
            )
        }

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(
                source: Self.shaderSource,
                options: nil
            )
        } catch {
            throw MonitorOSCaptureError(
                "failed to compile Metal BGRA->4:2:2 kernel: \(error)"
            )
        }

        guard let function = library.makeFunction(name: "bgra_to_yuv422") else {
            throw MonitorOSCaptureError(
                "Metal BGRA->4:2:2 kernel is missing"
            )
        }
        guard let diffFunction = library.makeFunction(
            name: "mark_changed_tiles"
        ) else {
            throw MonitorOSCaptureError(
                "Metal content-damage kernel is missing"
            )
        }
        guard let referenceCopyFunction = library.makeFunction(
            name: "copy_yuv422_region"
        ) else {
            throw MonitorOSCaptureError(
                "Metal 4:2:2 reference-copy kernel is missing"
            )
        }

        let pipeline: MTLComputePipelineState
        do {
            pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            throw MonitorOSCaptureError(
                "failed to create Metal BGRA->4:2:2 pipeline: \(error)"
            )
        }

        let diffPipeline: MTLComputePipelineState
        do {
            diffPipeline = try device.makeComputePipelineState(
                function: diffFunction
            )
        } catch {
            throw MonitorOSCaptureError(
                "failed to create Metal content-damage pipeline: \(error)"
            )
        }

        let referenceCopyPipeline: MTLComputePipelineState
        do {
            referenceCopyPipeline = try device.makeComputePipelineState(
                function: referenceCopyFunction
            )
        } catch {
            throw MonitorOSCaptureError(
                "failed to create Metal reference-copy pipeline: \(error)"
            )
        }

        guard let outputBuffer = device.makeBuffer(
            length: Self.byteCount,
            options: .storageModeShared
        ) else {
            throw MonitorOSCaptureError(
                "failed to allocate shared Metal 4:2:2 output buffer"
            )
        }

        guard let referenceBuffer = device.makeBuffer(
            length: Self.byteCount,
            options: .storageModePrivate
        ) else {
            throw MonitorOSCaptureError(
                "failed to allocate Metal 4:2:2 reference buffer"
            )
        }

        guard let tileMetricsBuffer = device.makeBuffer(
            length: Self.tileCount * 4 * MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ) else {
            throw MonitorOSCaptureError(
                "failed to allocate Metal content-damage tile flags"
            )
        }

        var textureCache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &textureCache
        )
        guard cacheStatus == kCVReturnSuccess,
              let textureCache else {
            throw MonitorOSCaptureError(
                "CVMetalTextureCacheCreate failed: \(cacheStatus)"
            )
        }

        let threadWidth = max(1, pipeline.threadExecutionWidth)
        let threadHeight = max(
            1,
            min(
                8,
                pipeline.maxTotalThreadsPerThreadgroup / threadWidth
            )
        )

        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.diffPipeline = diffPipeline
        self.referenceCopyPipeline = referenceCopyPipeline
        self.outputBuffer = outputBuffer
        self.referenceBuffer = referenceBuffer
        self.tileMetricsBuffer = tileMetricsBuffer
        self.textureCache = textureCache
        threadsPerThreadgroup = MTLSize(
            width: threadWidth,
            height: threadHeight,
            depth: 1
        )
    }

    func conversionDamage(
        for decision: MonitorOSDamageDecision
    ) -> MonitorOSPendingDamage {
        guard referenceReady,
              let candidateRegions = decision.candidateRegions,
              let candidatePixels = decision.pixelCount,
              candidatePixels >= Self.refinementThresholdPixels,
              !candidateRegions.isEmpty,
              candidateRegions.count <= Self.maximumRefinementRegions else {
            return decision.damage
        }

        return .regions(candidateRegions)
    }

    func refineConvertedDamage(
        decision: MonitorOSDamageDecision
    ) throws -> MonitorOSDamageRefinementResult {
        guard referenceReady,
              let candidateRegions = decision.candidateRegions,
              let candidatePixels = decision.pixelCount,
              candidatePixels >= Self.refinementThresholdPixels,
              !candidateRegions.isEmpty,
              candidateRegions.count <= Self.maximumRefinementRegions else {
            return MonitorOSDamageRefinementResult(
                decision: decision,
                durationSeconds: 0,
                applied: false,
                changedPairCount: 0,
                changedWireByteCount: 0,
                meanWireByteDelta: 0,
                maxWireByteDelta: 0
            )
        }

        memset(
            tileMetricsBuffer.contents(),
            0,
            Self.tileCount * 4 * MemoryLayout<UInt32>.stride
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MonitorOSCaptureError(
                "failed to create Metal content-damage command buffer/encoder"
            )
        }

        var shaderRegions = candidateRegions.map {
            ShaderRegion(
                x: UInt32($0.x),
                y: UInt32($0.y),
                width: UInt32($0.width),
                height: UInt32($0.height)
            )
        }
        var regionCount = UInt32(shaderRegions.count)

        encoder.setComputePipelineState(diffPipeline)
        encoder.setBuffer(outputBuffer, offset: 0, index: 0)
        encoder.setBuffer(referenceBuffer, offset: 0, index: 1)
        encoder.setBuffer(tileMetricsBuffer, offset: 0, index: 2)
        shaderRegions.withUnsafeBufferPointer { buffer in
            encoder.setBytes(
                buffer.baseAddress!,
                length: buffer.count * MemoryLayout<ShaderRegion>.stride,
                index: 3
            )
        }
        encoder.setBytes(
            &regionCount,
            length: MemoryLayout<UInt32>.stride,
            index: 4
        )

        let start = DispatchTime.now().uptimeNanoseconds
        encoder.dispatchThreadgroups(
            MTLSize(width: Self.tileCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: Self.tileSize,
                height: 1,
                depth: 1
            )
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let end = DispatchTime.now().uptimeNanoseconds

        guard commandBuffer.status == .completed else {
            let detail = commandBuffer.error.map {
                String(describing: $0)
            } ?? "status=\(commandBuffer.status.rawValue)"
            throw MonitorOSCaptureError(
                "Metal 4:2:2 content refinement failed: \(detail)"
            )
        }

        let metricsPointer = tileMetricsBuffer.contents()
            .bindMemory(
                to: UInt32.self,
                capacity: Self.tileCount * 4
            )
        let changedPairs = Array(
            UnsafeBufferPointer(
                start: metricsPointer,
                count: Self.tileCount
            )
        )
        let changedBytes = UnsafeBufferPointer(
            start: metricsPointer.advanced(by: Self.tileCount),
            count: Self.tileCount
        )
        let deltaSums = UnsafeBufferPointer(
            start: metricsPointer.advanced(by: Self.tileCount * 2),
            count: Self.tileCount
        )
        let maxDeltas = UnsafeBufferPointer(
            start: metricsPointer.advanced(by: Self.tileCount * 3),
            count: Self.tileCount
        )

        let changedPairCount = changedPairs.reduce(0) {
            $0 + Int($1)
        }
        let changedWireByteCount = changedBytes.reduce(0) {
            $0 + Int($1)
        }
        let totalWireDelta = deltaSums.reduce(UInt64(0)) {
            $0 + UInt64($1)
        }
        let maxWireByteDelta = maxDeltas.reduce(UInt32(0), max)
        let meanWireByteDelta =
            changedWireByteCount > 0
                ? Double(totalWireDelta)
                    / Double(changedWireByteCount)
                : 0

        let refinedRegions = monitorOSDamageRegionsFromTileFlags(
            changedPairs,
            maximumRegions: Self.maximumRefinementRegions
        )
        let refinedDecision = monitorOSAnalyzeRegions(
            refinedRegions,
            rectLimitReason: .contentRectLimit,
            coverageReason: .contentCoverageThreshold
        )

        return MonitorOSDamageRefinementResult(
            decision: refinedDecision,
            durationSeconds: Double(end - start) / 1_000_000_000,
            applied: true,
            changedPairCount: changedPairCount,
            changedWireByteCount: changedWireByteCount,
            meanWireByteDelta: meanWireByteDelta,
            maxWireByteDelta: Int(maxWireByteDelta)
        )
    }

    func convert(
        pixelBuffer: CVPixelBuffer,
        damage: MonitorOSPendingDamage
    ) throws -> (base: UnsafeRawPointer, durationSeconds: Double) {
        try validate(pixelBuffer)

        let regions = try damageRegions(damage)

        let cvTexture = try makeSourceCVTexture(pixelBuffer)
        guard let sourceTexture = CVMetalTextureGetTexture(cvTexture) else {
            throw MonitorOSCaptureError(
                "failed to access ScreenCaptureKit Metal texture"
            )
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MonitorOSCaptureError(
                "failed to create Metal command buffer/encoder"
            )
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setBuffer(outputBuffer, offset: 0, index: 0)

        let start = DispatchTime.now().uptimeNanoseconds
        for region in regions {
            var shaderRegion = ShaderRegion(
                x: UInt32(region.x),
                y: UInt32(region.y),
                width: UInt32(region.width),
                height: UInt32(region.height)
            )
            encoder.setBytes(
                &shaderRegion,
                length: MemoryLayout<ShaderRegion>.stride,
                index: 1
            )
            encoder.dispatchThreads(
                MTLSize(
                    width: region.width / 2,
                    height: region.height,
                    depth: 1
                ),
                threadsPerThreadgroup: threadsPerThreadgroup
            )
        }
        encoder.endEncoding()

        commandBuffer.commit()
        withExtendedLifetime(cvTexture) {
            commandBuffer.waitUntilCompleted()
        }
        let end = DispatchTime.now().uptimeNanoseconds

        guard commandBuffer.status == .completed else {
            let detail = commandBuffer.error.map {
                String(describing: $0)
            } ?? "status=\(commandBuffer.status.rawValue)"
            throw MonitorOSCaptureError(
                "Metal BGRA->4:2:2 conversion failed: \(detail)"
            )
        }

        return (
            UnsafeRawPointer(outputBuffer.contents()),
            Double(end - start) / 1_000_000_000
        )
    }

    func commitReference(
        damage: MonitorOSPendingDamage
    ) throws {
        let regions = try damageRegions(damage)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MonitorOSCaptureError(
                "failed to create Metal reference-update command buffer/encoder"
            )
        }

        encoder.setComputePipelineState(referenceCopyPipeline)
        encoder.setBuffer(outputBuffer, offset: 0, index: 0)
        encoder.setBuffer(referenceBuffer, offset: 0, index: 1)

        for region in regions {
            var shaderRegion = ShaderRegion(
                x: UInt32(region.x),
                y: UInt32(region.y),
                width: UInt32(region.width),
                height: UInt32(region.height)
            )
            encoder.setBytes(
                &shaderRegion,
                length: MemoryLayout<ShaderRegion>.stride,
                index: 2
            )
            encoder.dispatchThreads(
                MTLSize(
                    width: region.width / 2,
                    height: region.height,
                    depth: 1
                ),
                threadsPerThreadgroup: threadsPerThreadgroup
            )
        }

        encoder.endEncoding()
        commandBuffer.commit()
        referenceReady = true
    }

    private func damageRegions(
        _ damage: MonitorOSPendingDamage
    ) throws -> [MonitorOSDamageRegion] {
        let regions: [MonitorOSDamageRegion]
        switch damage {
        case .full:
            regions = [
                MonitorOSDamageRegion(
                    x: 0,
                    y: 0,
                    width: Self.width,
                    height: Self.height
                ),
            ]
        case let .regions(damageRegions):
            guard !damageRegions.isEmpty else {
                throw MonitorOSCaptureError(
                    "Metal 4:2:2 damage has no regions"
                )
            }
            regions = damageRegions
        }

        for region in regions {
            guard region.x >= 0,
                  region.y >= 0,
                  region.width > 0,
                  region.height > 0,
                  region.x % 2 == 0,
                  region.width % 2 == 0,
                  region.x + region.width <= Self.width,
                  region.y + region.height <= Self.height else {
                throw MonitorOSCaptureError(
                    "invalid normalized 4:2:2 damage region " +
                    "x=\(region.x) y=\(region.y) " +
                    "w=\(region.width) h=\(region.height)"
                )
            }
        }

        return regions
    }

    private func validate(_ pixelBuffer: CVPixelBuffer) throws {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer)
                == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(pixelBuffer) == Self.width,
              CVPixelBufferGetHeight(pixelBuffer) == Self.height,
              CVPixelBufferGetPlaneCount(pixelBuffer) == 0 else {
            throw MonitorOSCaptureError(
                "Metal 4:2:2 converter expected packed 5120x2880 BGRA"
            )
        }
    }

    private func makeSourceCVTexture(
        _ pixelBuffer: CVPixelBuffer
    ) throws -> CVMetalTexture {
        var cvTexture: CVMetalTexture?
        let textureStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            Self.width,
            Self.height,
            0,
            &cvTexture
        )
        guard textureStatus == kCVReturnSuccess,
              let cvTexture else {
            throw MonitorOSCaptureError(
                "failed to map ScreenCaptureKit BGRA into Metal: " +
                "\(textureStatus)"
            )
        }
        return cvTexture
    }
}
