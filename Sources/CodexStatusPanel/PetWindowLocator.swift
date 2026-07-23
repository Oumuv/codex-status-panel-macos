// 定位 Codex 桌面宠物窗口，并把 Quartz 坐标转换为 AppKit 可使用的屏幕坐标。
// 优先使用实时窗口；实时信息暂缺时，再回退到 Codex 保存的窗口状态。

import AppKit
import CoreGraphics
import Foundation

/// 一次定位结果同时包含覆盖窗口、真正可见的桌宠区域，以及它所在的屏幕。
struct LocatedPet {
    let overlayRect: NSRect
    let visibleRect: NSRect
    let screen: NSScreen
    let source: String
}

/// 负责在多个数据源之间选择最可信的桌宠位置，并缓存短时间内可复用的几何信息。
final class PetWindowLocator {
    private struct StoredMascotMetrics {
        let left: CGFloat
        let top: CGFloat
        let width: CGFloat
        let height: CGFloat
        let source: String
    }

    private struct StoredOverlayLocation {
        let rect: CGRect
        let mascot: StoredMascotMetrics?
        let isPrimary: Bool
    }

    private var cachedWindowID: CGWindowID?
    private var cachedMascotMetrics: StoredMascotMetrics?
    private var lastVisualProbeAt: CFAbsoluteTime = 0
    private var lastOverlayStateReadAt: CFAbsoluteTime = 0
    private var storedOverlayLocations: [StoredOverlayLocation] = []
    private var storedDisplayID: String?
    private(set) var overlayOpen: Bool?

    func locate() -> LocatedPet? {
        let now = CFAbsoluteTimeGetCurrent()
        // 保存状态变化较慢，100 ms 内无需重复读取同一 JSON 文件。
        if now - lastOverlayStateReadAt >= 0.10 {
            lastOverlayStateReadAt = now
            refreshStoredOverlayState()
        }

        if let cachedWindowID,
           let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, cachedWindowID) as? [[String: Any]],
           let window = windows.first,
           let candidate = candidate(from: window),
           let location = makeLocation(from: candidate.rect, windowID: cachedWindowID)
        {
            return location
        }

        cachedWindowID = nil
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return storedOverlayLocation()
        }

        let candidates: [(id: CGWindowID, rect: CGRect, score: Double)] = windows.compactMap { window in
            guard let number = window[kCGWindowNumber as String] as? NSNumber,
                  let candidate = candidate(from: window)
            else { return nil }
            return (number.uint32Value, candidate.rect, candidate.score)
        }

        guard let best = candidates.min(by: { $0.score < $1.score }) else {
            return storedOverlayLocation()
        }
        cachedWindowID = best.id
        return makeLocation(from: best.rect, windowID: best.id) ?? storedOverlayLocation()
    }

    func locateSavedState() -> LocatedPet? {
        refreshStoredOverlayState()
        return storedOverlayLocation()
    }

    func reset() {
        cachedWindowID = nil
        cachedMascotMetrics = nil
        lastVisualProbeAt = 0
        lastOverlayStateReadAt = 0
        storedOverlayLocations = []
        storedDisplayID = nil
        overlayOpen = nil
    }

    private func makeLocation(from quartzRect: CGRect, windowID: CGWindowID) -> LocatedPet? {
        guard let converted = convertToAppKit(quartzRect) else { return nil }

        if let matched = bestStoredMetrics(matching: quartzRect) {
            cachedMascotMetrics = matched
            return LocatedPet(
                overlayRect: converted.0,
                visibleRect: visibleRect(in: converted.0, metrics: matched),
                screen: converted.1,
                source: "window-\(matched.source)"
            )
        }

        // 实时窗口已经移动、Codex 尚未来得及保存新边界的短暂间隔内，
        // 继续使用上一次验证过的相对锚点，防止面板瞬间跳动。
        if let cachedMascotMetrics,
           metricsAreValid(cachedMascotMetrics, for: quartzRect.size)
        {
            return LocatedPet(
                overlayRect: converted.0,
                visibleRect: visibleRect(in: converted.0, metrics: cachedMascotMetrics),
                screen: converted.1,
                source: "window-cached-anchor"
            )
        }

        // 这只用于无法识别的 Codex 状态文件版本。没有录屏权限时截图可能不可用，
        // 因此不会使用未经验证的固定透明窗口边距来猜测位置。
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastVisualProbeAt >= 0.12 {
            lastVisualProbeAt = now
            if let probedInset = probeTopVisualInset(windowID: windowID) {
                let width = min(224, max(80, quartzRect.width * 163 / 356))
                let height = width * 177 / 163
                let metrics = StoredMascotMetrics(
                    left: max(0, (quartzRect.width - width) / 2),
                    top: max(0, probedInset - petSpriteTopPaddingInsideAnchor),
                    width: width,
                    height: height,
                    source: "image-probe"
                )
                cachedMascotMetrics = metrics
                return LocatedPet(
                    overlayRect: converted.0,
                    visibleRect: visibleRect(in: converted.0, metrics: metrics),
                    screen: converted.1,
                    source: "window-image-probe"
                )
            }
        }

        if let visibleRect = geometricFallbackVisibleRect(in: converted.0) {
            return LocatedPet(
                overlayRect: converted.0,
                visibleRect: visibleRect,
                screen: converted.1,
                source: "window-geometry-fallback"
            )
        }

        return nil
    }

    private func refreshStoredOverlayState() {
        let stateURL: URL
        if let override = ProcessInfo.processInfo.environment["CODEX_STATUS_PANEL_STATE_FILE"],
           !override.isEmpty
        {
            stateURL = URL(fileURLWithPath: override)
        } else if let override = ProcessInfo.processInfo.environment["CODEX_PANEL_STATE_FILE"],
           !override.isEmpty
        {
            stateURL = URL(fileURLWithPath: override)
        } else {
            stateURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/.codex-global-state.json")
        }
        guard let data = try? Data(contentsOf: stateURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        overlayOpen = root["electron-avatar-overlay-open"] as? Bool
        guard let overlay = root["electron-avatar-overlay-bounds"] as? [String: Any] else {
            storedOverlayLocations = []
            return
        }

        let activeDisplayID: String?
        if let number = overlay["displayId"] as? NSNumber {
            activeDisplayID = number.stringValue
        } else {
            activeDisplayID = overlay["displayId"] as? String
        }
        if activeDisplayID != storedDisplayID {
            storedDisplayID = activeDisplayID
            cachedWindowID = nil
            cachedMascotMetrics = nil
        }

        var locations: [StoredOverlayLocation] = []

        func addEntry(
            _ entry: [String: Any],
            displayID: String? = nil,
            isPrimary: Bool = false
        ) {
            if !isPrimary, let activeDisplayID, displayID != activeDisplayID {
                return
            }
            guard let x = entry["x"] as? NSNumber,
                  let y = entry["y"] as? NSNumber,
                  let width = entry["width"] as? NSNumber,
                  let height = entry["height"] as? NSNumber,
                  width.doubleValue > 0,
                  height.doubleValue > 0
            else { return }

            let rect = CGRect(
                x: x.doubleValue,
                y: y.doubleValue,
                width: width.doubleValue,
                height: height.doubleValue
            )
            let mascot = mascotMetrics(from: entry, overlayRect: rect)
            locations.append(StoredOverlayLocation(rect: rect, mascot: mascot, isPrimary: isPrimary))
        }

        // 根节点表示最近活跃的显示器，是最可靠的回退项。
        addEntry(overlay, isPrimary: true)
        if let byDisplayID = overlay["byDisplayId"] as? [String: Any] {
            for (key, value) in byDisplayID {
                if let entry = value as? [String: Any] {
                    let entryDisplayID: String
                    if let number = entry["displayId"] as? NSNumber {
                        entryDisplayID = number.stringValue
                    } else {
                        entryDisplayID = entry["displayId"] as? String ?? key
                    }
                    addEntry(entry, displayID: entryDisplayID)
                }
            }
        }
        // 旧版 Codex 有时只保留按分辨率索引的副本，也一并兼容。
        if let byResolution = overlay["byResolution"] as? [String: Any] {
            for value in byResolution.values {
                if let entry = value as? [String: Any] {
                    let entryDisplayID: String?
                    if let number = entry["displayId"] as? NSNumber {
                        entryDisplayID = number.stringValue
                    } else {
                        entryDisplayID = entry["displayId"] as? String
                    }
                    addEntry(entry, displayID: entryDisplayID)
                }
            }
        }

        storedOverlayLocations = locations
    }

    private func mascotMetrics(
        from entry: [String: Any],
        overlayRect: CGRect
    ) -> StoredMascotMetrics? {
        if let mascot = entry["mascot"] as? [String: Any],
           let left = mascot["left"] as? NSNumber,
           let top = mascot["top"] as? NSNumber,
           let width = mascot["width"] as? NSNumber
        {
            let derivedHeight = width.doubleValue * 177 / 163
            let height = (mascot["height"] as? NSNumber)?.doubleValue ?? derivedHeight
            let metrics = StoredMascotMetrics(
                left: CGFloat(left.doubleValue),
                top: CGFloat(top.doubleValue),
                width: CGFloat(width.doubleValue),
                height: CGFloat(height),
                source: "state-mascot"
            )
            if metricsAreValid(metrics, for: overlayRect.size) { return metrics }
        }

        // 兼容只保存绝对 anchor 矩形、没有保存相对 mascot 尺寸的 Codex 版本。
        if let anchor = entry["anchor"] as? [String: Any],
           let x = anchor["x"] as? NSNumber,
           let y = anchor["y"] as? NSNumber,
           let width = anchor["width"] as? NSNumber,
           let height = anchor["height"] as? NSNumber
        {
            let metrics = StoredMascotMetrics(
                left: CGFloat(x.doubleValue - overlayRect.minX),
                top: CGFloat(y.doubleValue - overlayRect.minY),
                width: CGFloat(width.doubleValue),
                height: CGFloat(height.doubleValue),
                source: "state-anchor"
            )
            if metricsAreValid(metrics, for: overlayRect.size) { return metrics }
        }
        return nil
    }

    private func metricsAreValid(_ metrics: StoredMascotMetrics, for size: CGSize) -> Bool {
        metrics.width >= 40
            && metrics.height >= 40
            && metrics.left >= -2
            && metrics.top >= -2
            && metrics.left + metrics.width <= size.width + 2
            && metrics.top + metrics.height <= size.height + 2
    }

    private func bestStoredMetrics(matching liveRect: CGRect) -> StoredMascotMetrics? {
        let matches = storedOverlayLocations.compactMap { stored -> (StoredMascotMetrics, Double)? in
            guard let metrics = stored.mascot else { return nil }
            let widthDelta = abs(stored.rect.width - liveRect.width)
            let heightDelta = abs(stored.rect.height - liveRect.height)
            guard widthDelta <= max(24, liveRect.width * 0.15),
                  heightDelta <= max(24, liveRect.height * 0.15)
            else { return nil }

            // Electron 显示器 ID 不保证等于 CGDirectDisplayID，不能直接用 ID 对应。
            // 改用 Quartz 实时矩形匹配最近的已保存矩形，对 Retina 缩放和屏幕顺序更稳。
            let centerDistance = hypot(stored.rect.midX - liveRect.midX, stored.rect.midY - liveRect.midY)
            let primaryBonus = stored.isPrimary ? -1.0 : 0.0
            let score = Double(widthDelta * 5 + heightDelta * 5 + centerDistance * 0.08) + primaryBonus
            return (metrics, score)
        }
        return matches.min(by: { $0.1 < $1.1 })?.0
    }

    private func visibleRect(in overlayRect: NSRect, metrics: StoredMascotMetrics) -> NSRect {
        let visibleHeight = max(1, metrics.height - petSpriteTopPaddingInsideAnchor)
        return NSRect(
            x: overlayRect.minX + metrics.left,
            y: overlayRect.maxY - metrics.top - metrics.height,
            width: metrics.width,
            height: visibleHeight
        )
    }

    private func storedOverlayLocation() -> LocatedPet? {
        guard overlayOpen != false else { return nil }

        for stored in storedOverlayLocations.sorted(by: { $0.isPrimary && !$1.isPrimary }) {
            guard let mascot = stored.mascot else { continue }
            guard let converted = convertToAppKit(stored.rect) else { continue }
            cachedMascotMetrics = mascot
            return LocatedPet(
                overlayRect: converted.0,
                visibleRect: visibleRect(in: converted.0, metrics: mascot),
                screen: converted.1,
                source: "saved-\(mascot.source)"
            )
        }
        return nil
    }

    private func probeTopVisualInset(windowID: CGWindowID) -> CGFloat? {
        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming]
        ), image.width >= 250, image.height >= 170,
        let data = image.dataProvider?.data,
        let bytes = CFDataGetBytePtr(data)
        else { return nil }

        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        let bytesPerRow = image.bytesPerRow
        let minX = max(0, Int(Double(image.width) * 0.50))
        let maxX = min(image.width, Int(Double(image.width) * 0.85))
        let maxY = image.height
        let roiWidth = maxX - minX
        guard bytesPerPixel >= 4, roiWidth > 0 else { return nil }

        for y in 0..<maxY {
            var visiblePixels = 0
            for x in minX..<maxX {
                let offset = y * bytesPerRow + x * bytesPerPixel
                var isVisible = false
                for channel in 0..<min(bytesPerPixel, 4) where bytes[offset + channel] > 20 {
                    isVisible = true
                    break
                }
                if isVisible { visiblePixels += 1 }
            }

            // 桌宠顶部装饰最初只有少量像素；接近纯色的行通常表示截图受隐私权限阻止。
            if visiblePixels >= 4 && visiblePixels < Int(Double(roiWidth) * 0.80) {
                return CGFloat(y)
            }
        }
        return nil
    }

    private func candidate(from window: [String: Any]) -> (rect: CGRect, score: Double)? {
        guard let ownerName = window[kCGWindowOwnerName as String] as? String,
              let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
              layer >= 0,
              layer < 50,
              let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
              alpha > 0.05,
              let rawBounds = window[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: rawBounds),
              bounds.width >= 160,
              bounds.width <= 900,
              bounds.height >= 120,
              bounds.height <= 1_000
        else { return nil }

        let normalizedOwner = ownerName.lowercased()
        guard normalizedOwner.contains("codex") || normalizedOwner.contains("chatgpt") else {
            return nil
        }

        let name = window[kCGWindowName as String] as? String ?? ""
        var score = Double(abs(bounds.width - 356) + abs(bounds.height - 320) * 0.35)
        score += Double(abs(layer - 3) * 50)
        if name == "ChatGPT" || name == "Codex" { score -= 80 }

        if let distance = storedOverlayLocations.map({ stored in
            hypot(bounds.midX - stored.rect.midX, bounds.midY - stored.rect.midY)
        }).min() {
            score += Double(distance * 0.08)
        }
        return (bounds, score)
    }

    private func convertToAppKit(_ quartzRect: CGRect) -> (NSRect, NSScreen)? {
        let center = CGPoint(x: quartzRect.midX, y: quartzRect.midY)

        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayBounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            guard displayBounds.contains(center) || displayBounds.intersects(quartzRect) else {
                continue
            }

            let x = screen.frame.minX + (quartzRect.minX - displayBounds.minX)
            let y = screen.frame.maxY - (quartzRect.minY - displayBounds.minY) - quartzRect.height
            return (NSRect(x: x, y: y, width: quartzRect.width, height: quartzRect.height), screen)
        }
        return nil
    }
}
