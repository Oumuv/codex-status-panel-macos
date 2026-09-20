#!/usr/bin/env swift

import AppKit
import Foundation

private struct Options {
    var assetPath: String?
    var previewPath: String?
    var logicalPanelWidth = 232.0
    var alphaThreshold = 128
    var maxCenterErrorPoints = 0.5
    var maxCircleDeltaPoints = 0.5
}

private struct PixelImage {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixels: [UInt8]

    func rgba(x: Int, y: Int) -> (red: Int, green: Int, blue: Int, alpha: Int) {
        let index = y * bytesPerRow + x * 4
        return (
            Int(pixels[index]),
            Int(pixels[index + 1]),
            Int(pixels[index + 2]),
            Int(pixels[index + 3])
        )
    }
}

private struct PixelBounds {
    var minX: Int
    var minY: Int
    var maxX: Int
    var maxY: Int

    var center: CGPoint {
        CGPoint(
            x: (CGFloat(minX + maxX) + 1) / 2,
            y: (CGFloat(minY + maxY) + 1) / 2
        )
    }

    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
}

private struct PixelRegion {
    let bounds: PixelBounds
    let points: [CGPoint]
}

private struct PixelCircle {
    let center: CGPoint
    let radius: CGFloat
}

private struct DetectedRing {
    let bounds: PixelBounds
    let circle: PixelCircle
}

private enum VerificationError: LocalizedError {
    case usage(String)
    case imageLoad(String)
    case pixels(String)
    case detection(String)
    case verification(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message),
             .imageLoad(let message),
             .pixels(let message),
             .detection(let message),
             .verification(let message):
            return message
        }
    }
}

private let usage = """
用法：verify-task-animation-visual.swift \
  --asset <05-green.png> \
  --preview <completed-preview.png> \
  [--logical-panel-width 232] \
  [--max-center-error-pt 0.5] \
  [--max-circle-delta-pt 0.5]
"""

private func parsePositiveDouble(_ value: String, name: String) throws -> Double {
    guard let parsed = Double(value), parsed > 0 else {
        throw VerificationError.usage("\(name) 必须是正数：\(value)\n\(usage)")
    }
    return parsed
}

private func parseOptions() throws -> Options {
    var options = Options()
    let arguments = Array(CommandLine.arguments.dropFirst())
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--help" || argument == "-h" {
            print(usage)
            exit(0)
        }
        guard index + 1 < arguments.count else {
            throw VerificationError.usage("参数缺少值：\(argument)\n\(usage)")
        }
        let value = arguments[index + 1]
        switch argument {
        case "--asset":
            options.assetPath = value
        case "--preview":
            options.previewPath = value
        case "--logical-panel-width":
            options.logicalPanelWidth = try parsePositiveDouble(
                value,
                name: argument
            )
        case "--max-center-error-pt":
            options.maxCenterErrorPoints = try parsePositiveDouble(
                value,
                name: argument
            )
        case "--max-circle-delta-pt":
            options.maxCircleDeltaPoints = try parsePositiveDouble(
                value,
                name: argument
            )
        default:
            throw VerificationError.usage("未知参数：\(argument)\n\(usage)")
        }
        index += 2
    }

    guard options.assetPath != nil, options.previewPath != nil else {
        throw VerificationError.usage(usage)
    }
    return options
}

private func loadPixelImage(at path: String) throws -> PixelImage {
    guard let source = NSImage(contentsOfFile: path),
          let image = source.cgImage(
              forProposedRect: nil,
              context: nil,
              hints: nil
          )
    else {
        throw VerificationError.imageLoad("无法读取图片：\(path)")
    }

    let bytesPerRow = image.width * 4
    var pixels = [UInt8](
        repeating: 0,
        count: image.height * bytesPerRow
    )
    guard let context = CGContext(
        data: &pixels,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw VerificationError.pixels("无法创建像素上下文：\(path)")
    }
    context.draw(
        image,
        in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
    )
    return PixelImage(
        width: image.width,
        height: image.height,
        bytesPerRow: bytesPerRow,
        pixels: pixels
    )
}

private func bounds(
    in image: PixelImage,
    xRange: Range<Int>,
    yRange: Range<Int>,
    matching: (Int, Int, Int, Int) -> Bool
) throws -> PixelBounds {
    var result = PixelBounds(
        minX: image.width,
        minY: image.height,
        maxX: -1,
        maxY: -1
    )
    for y in yRange {
        for x in xRange {
            let pixel = image.rgba(x: x, y: y)
            guard matching(
                pixel.red,
                pixel.green,
                pixel.blue,
                pixel.alpha
            ) else { continue }
            result.minX = min(result.minX, x)
            result.minY = min(result.minY, y)
            result.maxX = max(result.maxX, x)
            result.maxY = max(result.maxY, y)
        }
    }
    guard result.maxX >= result.minX, result.maxY >= result.minY else {
        throw VerificationError.detection("没有检测到符合条件的像素区域")
    }
    return result
}

private func isCompletedBallPixel(
    red: Int,
    green: Int,
    blue: Int,
    alpha: Int
) -> Bool {
    alpha > 0
        && red > 35
        && green > 120
        && blue > 60
        && blue < 180
        && green - blue > 48
        && green - red > 60
}

private func isOuterRingPixel(
    red: Int,
    green: Int,
    blue: Int,
    alpha: Int
) -> Bool {
    alpha > 0
        && red < 80
        && green > 70
        && blue > 70
        && green - red > 45
        && blue - red > 40
        && abs(green - blue) < 45
}

private func median(_ values: [CGFloat]) -> CGFloat? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
}

private func detectOuterRing(
    in image: PixelImage,
    searchX: Range<Int>,
    searchY: Range<Int>
) throws -> DetectedRing {
    var candidates = [Bool](
        repeating: false,
        count: image.width * image.height
    )
    for y in searchY {
        for x in searchX {
            let pixel = image.rgba(x: x, y: y)
            candidates[y * image.width + x] = isOuterRingPixel(
                red: pixel.red,
                green: pixel.green,
                blue: pixel.blue,
                alpha: pixel.alpha
            )
        }
    }

    var visited = [Bool](repeating: false, count: candidates.count)
    var ringRegions: [PixelRegion] = []
    for y in searchY {
        for x in searchX {
            let start = y * image.width + x
            guard candidates[start], !visited[start] else { continue }

            var queue = [start]
            var cursor = 0
            var regionBounds = PixelBounds(
                minX: x,
                minY: y,
                maxX: x,
                maxY: y
            )
            visited[start] = true
            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                let currentX = index % image.width
                let currentY = index / image.width
                regionBounds.minX = min(regionBounds.minX, currentX)
                regionBounds.minY = min(regionBounds.minY, currentY)
                regionBounds.maxX = max(regionBounds.maxX, currentX)
                regionBounds.maxY = max(regionBounds.maxY, currentY)

                for offsetY in -1...1 {
                    for offsetX in -1...1 where offsetX != 0 || offsetY != 0 {
                        let neighborX = currentX + offsetX
                        let neighborY = currentY + offsetY
                        guard searchX.contains(neighborX),
                              searchY.contains(neighborY)
                        else { continue }
                        let neighbor = neighborY * image.width + neighborX
                        guard candidates[neighbor], !visited[neighbor] else {
                            continue
                        }
                        visited[neighbor] = true
                        queue.append(neighbor)
                    }
                }
            }

            guard min(regionBounds.width, regionBounds.height) >= 16 else {
                continue
            }
            ringRegions.append(PixelRegion(
                bounds: regionBounds,
                points: queue.map {
                    CGPoint(
                        x: CGFloat($0 % image.width) + 0.5,
                        y: CGFloat($0 / image.width) + 0.5
                    )
                }
            ))
        }
    }

    guard let firstRegion = ringRegions.first else {
        throw VerificationError.detection("没有独立检测到完整的圆形外环")
    }
    let ringBounds = ringRegions.dropFirst().reduce(firstRegion.bounds) { result, region in
        PixelBounds(
            minX: min(result.minX, region.bounds.minX),
            minY: min(result.minY, region.bounds.minY),
            maxX: max(result.maxX, region.bounds.maxX),
            maxY: max(result.maxY, region.bounds.maxY)
        )
    }
    let ringPoints = ringRegions.flatMap(\.points)
    let edgeBand = max(1, Int(round(CGFloat(ringBounds.width) * 0.02)))
    let leftLimit = CGFloat(ringBounds.minX + edgeBand)
    let rightLimit = CGFloat(ringBounds.maxX - edgeBand + 1)
    guard let leftCenterY = median(
        ringPoints.filter { $0.x <= leftLimit }.map(\.y)
    ), let rightCenterY = median(
        ringPoints.filter { $0.x >= rightLimit }.map(\.y)
    ) else {
        throw VerificationError.detection("无法从外环两侧弧段计算圆心")
    }
    let circle = PixelCircle(
        center: CGPoint(
            x: ringBounds.center.x,
            y: (leftCenterY + rightCenterY) / 2
        ),
        radius: CGFloat(ringBounds.width) / 2
    )
    return DetectedRing(bounds: ringBounds, circle: circle)
}

private func format(_ value: CGFloat) -> String {
    String(format: "%.3f", Double(value))
}

private func run() throws {
    let options = try parseOptions()
    let asset = try loadPixelImage(at: options.assetPath!)
    let preview = try loadPixelImage(at: options.previewPath!)
    let assetBounds = try bounds(
        in: asset,
        xRange: 0..<asset.width,
        yRange: 0..<asset.height
    ) { _, _, _, alpha in
        alpha >= options.alphaThreshold
    }

    let searchXStart = min(preview.width - 1, Int(Double(preview.width) * 0.65))
    let searchYEnd = max(1, min(
        preview.height,
        Int(ceil(Double(preview.height) * 0.36))
    ))
    let searchX = searchXStart..<preview.width
    let searchY = 0..<searchYEnd
    let ballBounds = try bounds(
        in: preview,
        xRange: searchX,
        yRange: searchY,
        matching: isCompletedBallPixel
    )
    let ring = try detectOuterRing(
        in: preview,
        searchX: searchX,
        searchY: searchY
    )
    let ringBounds = ring.bounds

    let scale = CGFloat(Double(preview.width) / options.logicalPanelWidth)
    guard scale > 0 else {
        throw VerificationError.verification("无法从预览宽度计算 backing scale")
    }
    let centerErrorPixels = hypot(
        ballBounds.center.x - ring.circle.center.x,
        ballBounds.center.y - ring.circle.center.y
    )
    let centerErrorPoints = centerErrorPixels / scale
    let ringWidthPixels = CGFloat(ringBounds.width)
    let ringHeightPixels = max(
        0,
        (ring.circle.center.y - CGFloat(ringBounds.minY)) * 2
    )
    let circleDeltaPoints = abs(ringWidthPixels - ringHeightPixels) / scale
    let ringIsClipped = ringBounds.minX <= 0
        || ringBounds.minY <= 0
        || ringBounds.maxX >= preview.width - 1
        || ringBounds.maxY >= preview.height - 1

    let assetCanvasCenter = CGPoint(
        x: CGFloat(asset.width) / 2,
        y: CGFloat(asset.height) / 2
    )
    let assetOffset = CGPoint(
        x: assetBounds.center.x - assetCanvasCenter.x,
        y: assetBounds.center.y - assetCanvasCenter.y
    )

    print(
        "assetAlphaBounds=[\(assetBounds.minX),\(assetBounds.minY)]"
            + "-[\(assetBounds.maxX),\(assetBounds.maxY)]"
    )
    print(
        "assetVisualCenter=(\(format(assetBounds.center.x)),"
            + "\(format(assetBounds.center.y)))px"
            + " canvasOffset=(\(format(assetOffset.x)),"
            + "\(format(assetOffset.y)))px"
    )
    print(
        "renderedBallBounds=[\(ballBounds.minX),\(ballBounds.minY)]"
            + "-[\(ballBounds.maxX),\(ballBounds.maxY)]"
            + " center=(\(format(ballBounds.center.x)),"
            + "\(format(ballBounds.center.y)))px"
    )
    print(
        "outerRingBounds=[\(ringBounds.minX),\(ringBounds.minY)]"
            + "-[\(ringBounds.maxX),\(ringBounds.maxY)]"
            + " fittedCenter=(\(format(ring.circle.center.x)),"
            + "\(format(ring.circle.center.y)))px"
            + " radius=\(format(ring.circle.radius))px"
    )
    print(
        "centerError=\(format(centerErrorPoints))pt/"
            + "\(format(CGFloat(options.maxCenterErrorPoints)))pt"
            + " circleDelta=\(format(circleDeltaPoints))pt/"
            + "\(format(CGFloat(options.maxCircleDeltaPoints)))pt"
            + " clipped=\(ringIsClipped) scale=\(format(scale))x"
    )

    var failures: [String] = []
    if centerErrorPoints > CGFloat(options.maxCenterErrorPoints) {
        failures.append("光环与绿球中心误差超限")
    }
    if circleDeltaPoints > CGFloat(options.maxCircleDeltaPoints) {
        failures.append("光环横纵直径差超限")
    }
    if ringIsClipped {
        failures.append("光环接触预览边界，可能被裁切")
    }
    guard failures.isEmpty else {
        throw VerificationError.verification(
            "task_animation_visual_check: failed: "
                + failures.joined(separator: "；")
        )
    }
    print("task_animation_visual_check: passed")
}

do {
    try run()
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
