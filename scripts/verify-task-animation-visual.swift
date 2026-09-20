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
        && red < 40
        && green > 70
        && blue > 80
        && green - red > 45
        && blue - red > 60
        && abs(green - blue) < 30
}

private func ringExtrema(
    in image: PixelImage,
    searchX: Range<Int>,
    searchY: Range<Int>,
    around center: CGPoint
) throws -> PixelBounds {
    let sampleX = min(
        searchX.upperBound - 1,
        max(searchX.lowerBound, Int(floor(center.x)))
    )
    let sampleY = min(
        searchY.upperBound - 1,
        max(searchY.lowerBound, Int(floor(center.y)))
    )
    var result = PixelBounds(
        minX: image.width,
        minY: image.height,
        maxX: -1,
        maxY: -1
    )

    for x in searchX {
        let pixel = image.rgba(x: x, y: sampleY)
        if isOuterRingPixel(
            red: pixel.red,
            green: pixel.green,
            blue: pixel.blue,
            alpha: pixel.alpha
        ) {
            result.minX = min(result.minX, x)
            result.maxX = max(result.maxX, x)
        }
    }
    for y in searchY {
        let pixel = image.rgba(x: sampleX, y: y)
        if isOuterRingPixel(
            red: pixel.red,
            green: pixel.green,
            blue: pixel.blue,
            alpha: pixel.alpha
        ) {
            result.minY = min(result.minY, y)
            result.maxY = max(result.maxY, y)
        }
    }

    guard result.maxX >= result.minX, result.maxY >= result.minY else {
        throw VerificationError.detection("没有在绿球中心轴线上检测到完整外环")
    }
    return result
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
    let ringBounds = try ringExtrema(
        in: preview,
        searchX: searchX,
        searchY: searchY,
        around: ballBounds.center
    )

    let scale = CGFloat(Double(preview.width) / options.logicalPanelWidth)
    guard scale > 0 else {
        throw VerificationError.verification("无法从预览宽度计算 backing scale")
    }
    let centerErrorPixels = hypot(
        ballBounds.center.x - ringBounds.center.x,
        ballBounds.center.y - ringBounds.center.y
    )
    let centerErrorPoints = centerErrorPixels / scale
    let ringWidthPixels = CGFloat(ringBounds.maxX - ringBounds.minX + 1)
    let ringHeightPixels = CGFloat(ringBounds.maxY - ringBounds.minY + 1)
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
        "outerRingExtrema=x[\(ringBounds.minX),\(ringBounds.maxX)]"
            + " y[\(ringBounds.minY),\(ringBounds.maxY)]"
            + " center=(\(format(ringBounds.center.x)),"
            + "\(format(ringBounds.center.y)))px"
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
