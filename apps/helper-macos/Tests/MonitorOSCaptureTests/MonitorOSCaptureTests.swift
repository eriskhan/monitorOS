import CoreVideo
import Darwin
import Metal
import XCTest
@testable import MonitorOSCapture

final class MonitorOSCaptureTests: XCTestCase {
    func testTransportEndpointAcceptsScopedIPv6() throws {
        let endpoint = try MonitorOSTransportEndpoint(
            target: "[fe80::1234%bridge0]:5202"
        )
        XCTAssertEqual(endpoint.host, "fe80::1234%bridge0")
        XCTAssertEqual(endpoint.port, "5202")
    }

    func testTransportEndpointRejectsNonProductionTargets() {
        for target in [
            "192.0.2.1:5202",
            "monitoros.local:5202",
            "fe80::1234:5202",
            "[fe80::1234%bridge0]5202",
            "[]:5202",
            "[fe80::1234%bridge0]:not-a-port",
            "[fe80::1234%bridge0]:70000",
        ] {
            XCTAssertThrowsError(
                try MonitorOSTransportEndpoint(target: target),
                target
            )
        }
    }

    func testVirtualDisplayConfigurationUsesRetinaBacking() {
        let configuration = MonitorOSVirtualDisplayConfiguration(
            name: "test",
            serialNumber: 7
        )

        XCTAssertEqual(configuration.logicalWidth, 2560)
        XCTAssertEqual(configuration.logicalHeight, 1440)
        XCTAssertEqual(configuration.physicalWidth, 5120)
        XCTAssertEqual(configuration.physicalHeight, 2880)
        XCTAssertEqual(configuration.maximumBackingWidth, 7680)
        XCTAssertEqual(configuration.maximumBackingHeight, 4320)
        XCTAssertEqual(configuration.flexibleScalingBackingSizes.count, 100)
        XCTAssertEqual(
            configuration.flexibleScalingBackingSizes.first?.width,
            1280
        )
        XCTAssertEqual(
            configuration.flexibleScalingBackingSizes.first?.height,
            720
        )
        XCTAssertEqual(
            configuration.flexibleScalingBackingSizes.dropLast().last?.width,
            7552
        )
        XCTAssertEqual(
            configuration.flexibleScalingBackingSizes.dropLast().last?.height,
            4248
        )
        XCTAssertEqual(
            configuration.flexibleScalingBackingSizes.last?.width,
            7680
        )
        XCTAssertEqual(
            configuration.flexibleScalingBackingSizes.last?.height,
            4320
        )
        XCTAssertTrue(
            configuration.flexibleScalingBackingSizes.contains {
                $0.width == 5120 && $0.height == 2880
            }
        )
        XCTAssertTrue(
            configuration.flexibleScalingBackingSizes.contains {
                $0.width == 5888 && $0.height == 3312
            }
        )
        XCTAssertEqual(configuration.serialNumber, 7)
    }

    func testDamageRectsExpandHorizontallyTo422Pairs() {
        let regions = monitorOSNormalizeDamageRects([
            CGRect(x: 1.2, y: 2.4, width: 3.2, height: 3.1),
        ])

        XCTAssertEqual(
            regions,
            [
                MonitorOSDamageRegion(
                    x: 0,
                    y: 2,
                    width: 6,
                    height: 4
                ),
            ]
        )
    }

    func testDamageRectsCoalesceOverlapsAndClampToFrame() {
        let regions = monitorOSNormalizeDamageRects([
            CGRect(x: -4, y: -3, width: 14, height: 13),
            CGRect(x: 8, y: 8, width: 12, height: 12),
            CGRect(x: 6000, y: 3000, width: 10, height: 10),
        ])

        XCTAssertEqual(
            regions,
            [
                MonitorOSDamageRegion(
                    x: 0,
                    y: 0,
                    width: 20,
                    height: 20
                ),
            ]
        )
    }


    func testDamageAtEightyPercentFallsBackToFullFrame() {
        let decision = monitorOSDamageDecision(
            from: [
                CGRect(x: 0, y: 0, width: 4096, height: 2880),
            ]
        )

        XCTAssertEqual(decision.damage, .full)
        XCTAssertEqual(decision.fullReason, .coverageThreshold)
        XCTAssertEqual(decision.rectCount, 1)
        XCTAssertEqual(decision.pixelCount, 4096 * 2880)
    }

    func testMissingDirtyRectsReportsUnknownFullDamage() {
        let decision = monitorOSDamageDecision(from: nil)

        XCTAssertEqual(decision.damage, .full)
        XCTAssertEqual(decision.fullReason, .missingMetadata)
        XCTAssertNil(decision.pixelCount)
        XCTAssertEqual(decision.rectCount, 0)
    }

    func testMergedPendingDamagePreservesDisjointChanges() {
        let first = monitorOSDamageState(
            from: [
                CGRect(x: 10, y: 20, width: 100, height: 50),
            ]
        )
        let second = monitorOSDamageState(
            from: [
                CGRect(x: 1000, y: 1200, width: 80, height: 40),
            ]
        )

        XCTAssertEqual(
            monitorOSMergeDamage(first, second),
            .regions([
                MonitorOSDamageRegion(
                    x: 10,
                    y: 20,
                    width: 100,
                    height: 50
                ),
                MonitorOSDamageRegion(
                    x: 1000,
                    y: 1200,
                    width: 80,
                    height: 40
                ),
            ])
        )
    }

    func testFullDamageDominatesPendingDelta() {
        let delta = monitorOSDamageState(
            from: [
                CGRect(x: 10, y: 10, width: 20, height: 20),
            ]
        )

        XCTAssertEqual(
            monitorOSMergeDamage(.full, delta),
            .full
        )
    }

    func testMergedCoverageFallbackPreservesCandidateUnion() {
        let large = monitorOSDamageDecision(
            from: [
                CGRect(x: 0, y: 0, width: 4300, height: 2880),
            ]
        )
        let later = monitorOSDamageDecision(
            from: [
                CGRect(x: 4800, y: 100, width: 100, height: 100),
            ]
        )

        let merged = monitorOSMergeDamageDecision(large, later)

        XCTAssertEqual(merged.damage, .full)
        XCTAssertEqual(
            merged.fullReason,
            .mergedCoverageThreshold
        )
        XCTAssertEqual(
            merged.candidateRegions,
            [
                MonitorOSDamageRegion(
                    x: 0,
                    y: 0,
                    width: 4300,
                    height: 2880
                ),
                MonitorOSDamageRegion(
                    x: 4800,
                    y: 100,
                    width: 100,
                    height: 100
                ),
            ]
        )
    }

    func testMergedDamageReportsCoverageFallbackReason() {
        let first = monitorOSDamageDecision(
            from: [
                CGRect(x: 0, y: 0, width: 2200, height: 2880),
            ]
        )
        let second = monitorOSDamageDecision(
            from: [
                CGRect(x: 2200, y: 0, width: 2200, height: 2880),
            ]
        )

        let merged = monitorOSMergeDamageDecision(first, second)

        XCTAssertEqual(merged.damage, .full)
        XCTAssertEqual(merged.fullReason, .mergedCoverageThreshold)
        XCTAssertEqual(merged.rectCount, 2)
        XCTAssertEqual(merged.pixelCount, 4400 * 2880)
    }

    func testTileFlagsMergeIntoExactRectangles() {
        let regions = monitorOSDamageRegionsFromTileFlags(
            [
                1, 1, 0, 0,
                1, 1, 0, 1,
            ],
            tileSize: 64,
            frameWidth: 256,
            frameHeight: 128
        )

        XCTAssertEqual(
            regions,
            [
                MonitorOSDamageRegion(
                    x: 0,
                    y: 0,
                    width: 128,
                    height: 128
                ),
                MonitorOSDamageRegion(
                    x: 192,
                    y: 64,
                    width: 64,
                    height: 64
                ),
            ]
        )
    }

    func testTileFlagsCoarsenInsteadOfExceedingWireRectLimit() {
        let tileSize = 64
        let frameWidth = 1024
        let frameHeight = 1024
        let columns = frameWidth / tileSize
        let rows = frameHeight / tileSize
        var flags = [UInt32](repeating: 0, count: columns * rows)

        for row in 0..<rows {
            for column in 0..<columns
            where (row + column).isMultiple(of: 2) {
                flags[row * columns + column] = 1
            }
        }

        let regions = monitorOSDamageRegionsFromTileFlags(
            flags,
            tileSize: tileSize,
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            maximumRegions: 64
        )

        XCTAssertLessThanOrEqual(regions.count, 64)

        for row in 0..<rows {
            for column in 0..<columns
            where flags[row * columns + column] != 0 {
                let tileX = column * tileSize
                let tileY = row * tileSize
                XCTAssertTrue(
                    regions.contains { region in
                        region.x <= tileX
                            && region.y <= tileY
                            && region.x + region.width
                                >= tileX + tileSize
                            && region.y + region.height
                                >= tileY + tileSize
                    },
                    "changed tile \(column),\(row) was dropped"
                )
            }
        }
    }

    func testMetalContentDiffRefinesLargeFalseDamage() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable")
        }

        let baseline = try makeMetalBGRAFrame()
        let unchanged = try makeMetalBGRAFrame()
        let alphaOnly = try makeMetalBGRAFrame()
        let changed = try makeMetalBGRAFrame()

        let converter = try YUV422Converter()
        _ = try converter.convert(
            pixelBuffer: baseline,
            damage: .full
        )
        try converter.commitReference(damage: .full)

        let largeDecision = monitorOSDamageDecision(
            from: [
                CGRect(
                    x: 0,
                    y: 0,
                    width: 5120,
                    height: 2820
                ),
            ]
        )
        XCTAssertEqual(largeDecision.damage, .full)
        XCTAssertEqual(
            largeDecision.fullReason,
            .coverageThreshold
        )

        let conversionDamage = converter.conversionDamage(
            for: largeDecision
        )
        XCTAssertEqual(
            conversionDamage,
            .regions([
                MonitorOSDamageRegion(
                    x: 0,
                    y: 0,
                    width: 5120,
                    height: 2820
                ),
            ])
        )

        _ = try converter.convert(
            pixelBuffer: unchanged,
            damage: conversionDamage
        )
        let unchangedRefinement =
            try converter.refineConvertedDamage(
                decision: largeDecision
            )
        XCTAssertTrue(unchangedRefinement.applied)
        XCTAssertEqual(
            unchangedRefinement.decision.damage,
            .regions([])
        )
        XCTAssertEqual(
            unchangedRefinement.decision.pixelCount,
            0
        )
        XCTAssertEqual(
            unchangedRefinement.changedPairCount,
            0
        )
        XCTAssertEqual(
            unchangedRefinement.changedWireByteCount,
            0
        )
        XCTAssertEqual(
            unchangedRefinement.meanWireByteDelta,
            0
        )
        XCTAssertEqual(
            unchangedRefinement.maxWireByteDelta,
            0
        )

        try fillBGRA(
            alphaOnly,
            rect: CGRect(
                x: 100,
                y: 100,
                width: 16,
                height: 16
            ),
            b: 0,
            g: 0,
            r: 0,
            a: 255
        )
        _ = try converter.convert(
            pixelBuffer: alphaOnly,
            damage: conversionDamage
        )
        let alphaRefinement =
            try converter.refineConvertedDamage(
                decision: largeDecision
            )
        XCTAssertTrue(alphaRefinement.applied)
        XCTAssertEqual(
            alphaRefinement.decision.damage,
            .regions([])
        )
        XCTAssertEqual(
            alphaRefinement.changedPairCount,
            0
        )
        XCTAssertEqual(
            alphaRefinement.changedWireByteCount,
            0
        )

        try fillBGRA(
            changed,
            rect: CGRect(
                x: 100,
                y: 100,
                width: 16,
                height: 16
            ),
            b: 255,
            g: 255,
            r: 255,
            a: 255
        )
        _ = try converter.convert(
            pixelBuffer: changed,
            damage: conversionDamage
        )
        let changedRefinement =
            try converter.refineConvertedDamage(
                decision: largeDecision
            )
        XCTAssertTrue(changedRefinement.applied)
        XCTAssertEqual(
            changedRefinement.decision.damage,
            .regions([
                MonitorOSDamageRegion(
                    x: 64,
                    y: 64,
                    width: 64,
                    height: 64
                ),
            ])
        )
        XCTAssertEqual(
            changedRefinement.decision.pixelCount,
            64 * 64
        )
        XCTAssertEqual(
            changedRefinement.changedPairCount,
            16 * 16 / 2
        )
        XCTAssertEqual(
            changedRefinement.changedWireByteCount,
            16 * 16
        )
        XCTAssertEqual(
            changedRefinement.meanWireByteDelta,
            255
        )
        XCTAssertEqual(
            changedRefinement.maxWireByteDelta,
            255
        )
    }

    func testWireDomainRefinementDropsRGBChangesThatQuantizeIdentically() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable")
        }

        let baseline = try makeMetalBGRAFrame()
        let quantizedSame = try makeMetalBGRAFrame()
        let patch = CGRect(x: 100, y: 100, width: 16, height: 16)

        try fillBGRA(
            baseline,
            rect: patch,
            b: 8,
            g: 0,
            r: 0,
            a: 0
        )
        try fillBGRA(
            quantizedSame,
            rect: patch,
            b: 9,
            g: 0,
            r: 0,
            a: 0
        )

        let converter = try YUV422Converter()
        _ = try converter.convert(
            pixelBuffer: baseline,
            damage: .full
        )
        try converter.commitReference(damage: .full)

        let largeDecision = monitorOSDamageDecision(
            from: [
                CGRect(
                    x: 0,
                    y: 0,
                    width: 5120,
                    height: 2820
                ),
            ]
        )
        let conversionDamage = converter.conversionDamage(
            for: largeDecision
        )
        _ = try converter.convert(
            pixelBuffer: quantizedSame,
            damage: conversionDamage
        )
        let refinement = try converter.refineConvertedDamage(
            decision: largeDecision
        )

        XCTAssertTrue(refinement.applied)
        XCTAssertEqual(
            refinement.decision.damage,
            .regions([])
        )
        XCTAssertEqual(refinement.changedPairCount, 0)
        XCTAssertEqual(refinement.changedWireByteCount, 0)
    }

    func testMetalYUV422ConverterPacksRedBluePairAsBT709FullRange() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable")
        }

        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
        ]
        var pixelBuffer: CVPixelBuffer?
        let createStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            YUV422Converter.width,
            YUV422Converter.height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        XCTAssertEqual(createStatus, kCVReturnSuccess)

        let buffer = try XCTUnwrap(pixelBuffer)
        let lockStatus = CVPixelBufferLockBaseAddress(buffer, [])
        XCTAssertEqual(lockStatus, kCVReturnSuccess)
        guard lockStatus == kCVReturnSuccess else {
            return
        }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTFail("failed to access test BGRA pixel buffer")
            return
        }

        let sourceX = 2
        let sourceY = 1
        let sourceOffset =
            sourceY * CVPixelBufferGetBytesPerRow(buffer)
            + sourceX * 4
        let bytes = base
            .advanced(by: sourceOffset)
            .assumingMemoryBound(to: UInt8.self)
        // BGRA memory: red followed by blue.
        bytes[0] = 0
        bytes[1] = 0
        bytes[2] = 255
        bytes[3] = 255
        bytes[4] = 255
        bytes[5] = 0
        bytes[6] = 0
        bytes[7] = 255
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let converter = try YUV422Converter()
        let converted = try converter.convert(
            pixelBuffer: buffer,
            damage: .regions([
                MonitorOSDamageRegion(
                    x: sourceX,
                    y: sourceY,
                    width: 2,
                    height: 1
                ),
            ])
        )

        let pairIndex =
            sourceY * (YUV422Converter.width / 2)
            + sourceX / 2
        let output = converted.base
            .advanced(by: pairIndex * 4)
            .assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(
            Array(UnsafeBufferPointer(start: output, count: 4)),
            [54, 177, 18, 185]
        )
    }

    private func makeMetalBGRAFrame() throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            YUV422Converter.width,
            YUV422Converter.height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)

        let buffer = try XCTUnwrap(pixelBuffer)
        let lockStatus = CVPixelBufferLockBaseAddress(buffer, [])
        XCTAssertEqual(lockStatus, kCVReturnSuccess)
        guard lockStatus == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw MonitorOSCaptureError(
                "failed to initialize test BGRA frame"
            )
        }
        memset(
            base,
            0,
            CVPixelBufferGetBytesPerRow(buffer)
                * CVPixelBufferGetHeight(buffer)
        )
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func fillBGRA(
        _ buffer: CVPixelBuffer,
        rect: CGRect,
        b: UInt8,
        g: UInt8,
        r: UInt8,
        a: UInt8
    ) throws {
        let x0 = Int(rect.minX)
        let y0 = Int(rect.minY)
        let x1 = Int(rect.maxX)
        let y1 = Int(rect.maxY)

        let lockStatus = CVPixelBufferLockBaseAddress(buffer, [])
        XCTAssertEqual(lockStatus, kCVReturnSuccess)
        guard lockStatus == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw MonitorOSCaptureError(
                "failed to access test BGRA frame"
            )
        }
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, [])
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in y0..<y1 {
            let row = base
                .advanced(by: y * bytesPerRow)
                .assumingMemoryBound(to: UInt8.self)
            for x in x0..<x1 {
                let offset = x * 4
                row[offset] = b
                row[offset + 1] = g
                row[offset + 2] = r
                row[offset + 3] = a
            }
        }
    }

}
