// 定位 Codex 桌面宠物窗口，并把 Quartz 坐标转换为 AppKit 可使用的屏幕坐标。
// 旧版完整覆盖层优先使用实时窗口；新版直接保存桌宠锚点时优先使用保存状态。

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
        let hasExactOverlayBounds: Bool
    }

    private struct ParsedStoredOverlayState {
        let overlayOpen: Bool?
        let activeDisplayID: String?
        let locations: [StoredOverlayLocation]
    }

    private struct StoredStateFileSignature: Equatable {
        let path: String
        let modificationDate: Date?
        let fileSize: Int?
    }

    private var cachedWindowID: CGWindowID?
    private var cachedMascotMetrics: StoredMascotMetrics?
    private var lastVisualProbeAt: CFAbsoluteTime = 0
    private var lastOverlayStateCheckAt: CFAbsoluteTime = 0
    private var storedStateFileSignature: StoredStateFileSignature?
    private var storedOverlayLocations: [StoredOverlayLocation] = []
    private var storedDisplayID: String?
    private(set) var overlayOpen: Bool?

    private static let overlayStateCheckInterval: CFTimeInterval = 0.25
    private static let visualProbeRetryInterval: CFTimeInterval = 1.0
    // 现行 Codex 状态在缺少窗口尺寸时保存的是桌宠锚点；其原生桌宠尺寸为 112 x 121。
    private static let compactAnchorSize = CGSize(width: 112, height: 121)
    private static let panelWindowOwnerNames: Set<String> = {
        var names: Set<String> = ["Codex 状态面板", ProcessInfo.processInfo.processName]
        if let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String {
            names.insert(bundleName)
        }
        return names
    }()

    func locate() -> LocatedPet? {
        let now = CFAbsoluteTimeGetCurrent()
        // 保存状态变化较慢；先按文件签名检查，内容未变化时不读取和解析 JSON。
        if now - lastOverlayStateCheckAt >= Self.overlayStateCheckInterval {
            lastOverlayStateCheckAt = now
            refreshStoredOverlayState()
        }

        // 新版 Codex 已不再暴露可匹配的透明覆盖层窗口，保存的就是最终桌宠锚点。
        // 此时窗口列表可能包含状态面板自身，不能让探测结果覆盖这个更可靠的来源。
        if hasCompactStoredAnchor {
            return storedOverlayLocation()
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
        refreshStoredOverlayState(force: true)
        return storedOverlayLocation()
    }

    func reset() {
        cachedWindowID = nil
        cachedMascotMetrics = nil
        lastVisualProbeAt = 0
        lastOverlayStateCheckAt = 0
        storedStateFileSignature = nil
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
           Self.metricsAreValid(cachedMascotMetrics, for: quartzRect.size)
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
        if now - lastVisualProbeAt >= Self.visualProbeRetryInterval {
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

    private var hasCompactStoredAnchor: Bool {
        storedOverlayLocations.contains { !$0.hasExactOverlayBounds }
    }

    private func refreshStoredOverlayState(force: Bool = false) {
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

        let resourceValues = try? stateURL.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey,
        ])
        let signature = StoredStateFileSignature(
            path: stateURL.standardizedFileURL.path,
            modificationDate: resourceValues?.contentModificationDate,
            fileSize: resourceValues?.fileSize
        )
        if !force, signature == storedStateFileSignature {
            return
        }

        guard let data = try? Data(contentsOf: stateURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        storedStateFileSignature = signature

        let parsed = Self.parseStoredOverlayState(root)
        overlayOpen = parsed.overlayOpen
        if parsed.activeDisplayID != storedDisplayID {
            storedDisplayID = parsed.activeDisplayID
            cachedWindowID = nil
            cachedMascotMetrics = nil
        }
        storedOverlayLocations = parsed.locations
    }

    private static func parseStoredOverlayState(
        _ root: [String: Any]
    ) -> ParsedStoredOverlayState {
        let overlayOpen = root["electron-avatar-overlay-open"] as? Bool
        guard let overlay = root["electron-avatar-overlay-bounds"] as? [String: Any] else {
            return ParsedStoredOverlayState(
                overlayOpen: overlayOpen,
                activeDisplayID: nil,
                locations: []
            )
        }

        let activeDisplayID = Self.displayID(from: overlay)
        var locations: [StoredOverlayLocation] = []

        func addEntry(
            _ entry: [String: Any],
            displayID: String? = nil,
            isPrimary: Bool = false
        ) {
            if !isPrimary, let activeDisplayID, displayID != activeDisplayID {
                return
            }
            guard let location = Self.storedLocation(from: entry, isPrimary: isPrimary) else {
                return
            }
            locations.append(location)
        }

        // 根节点表示最近活跃的显示器，是最可靠的回退项。
        addEntry(overlay, isPrimary: true)
        if let byDisplayID = overlay["byDisplayId"] as? [String: Any] {
            for (key, value) in byDisplayID {
                guard let entry = value as? [String: Any] else { continue }
                addEntry(
                    entry,
                    displayID: Self.displayID(from: entry) ?? key
                )
            }
        }
        // 旧版 Codex 有时只保留按分辨率索引的副本，也一并兼容。
        if let byResolution = overlay["byResolution"] as? [String: Any] {
            for value in byResolution.values {
                guard let entry = value as? [String: Any] else { continue }
                addEntry(entry, displayID: Self.displayID(from: entry))
            }
        }

        return ParsedStoredOverlayState(
            overlayOpen: overlayOpen,
            activeDisplayID: activeDisplayID,
            locations: locations
        )
    }

    private static func storedLocation(
        from entry: [String: Any],
        isPrimary: Bool
    ) -> StoredOverlayLocation? {
        if let overlayRect = Self.positiveRect(from: entry) {
            return StoredOverlayLocation(
                rect: overlayRect,
                mascot: Self.mascotMetrics(from: entry, overlayRect: overlayRect),
                isPrimary: isPrimary,
                hasExactOverlayBounds: true
            )
        }

        // 新版状态省略透明覆盖窗口大小，改为保存桌宠锚点和所在显示器。
        guard let displayBounds = entry["displayBounds"] as? [String: Any],
              Self.positiveRect(from: displayBounds) != nil,
              let x = entry["x"] as? NSNumber,
              let y = entry["y"] as? NSNumber
        else { return nil }

        if let anchorPayload = entry["anchor"] as? [String: Any],
           let anchor = Self.positiveRect(from: anchorPayload)
        {
            return Self.directMascotLocation(
                rect: anchor,
                source: "state-anchor",
                isPrimary: isPrimary
            )
        }

        if let mascot = entry["mascot"] as? [String: Any],
           let left = mascot["left"] as? NSNumber,
           let top = mascot["top"] as? NSNumber,
           let width = mascot["width"] as? NSNumber,
           width.doubleValue > 0
        {
            let height = (mascot["height"] as? NSNumber)?.doubleValue
                ?? width.doubleValue * 177 / 163
            guard height > 0 else { return nil }
            return Self.directMascotLocation(
                rect: CGRect(
                    x: x.doubleValue + left.doubleValue,
                    y: y.doubleValue + top.doubleValue,
                    width: width.doubleValue,
                    height: height
                ),
                source: "state-mascot-anchor",
                isPrimary: isPrimary
            )
        }

        return Self.directMascotLocation(
            rect: CGRect(
                x: x.doubleValue,
                y: y.doubleValue,
                width: Self.compactAnchorSize.width,
                height: Self.compactAnchorSize.height
            ),
            source: "state-compact-anchor",
            isPrimary: isPrimary
        )
    }

    private static func directMascotLocation(
        rect: CGRect,
        source: String,
        isPrimary: Bool
    ) -> StoredOverlayLocation {
        let mascot = StoredMascotMetrics(
            left: 0,
            top: 0,
            width: rect.width,
            height: rect.height,
            source: source
        )
        return StoredOverlayLocation(
            rect: rect,
            mascot: mascot,
            isPrimary: isPrimary,
            hasExactOverlayBounds: false
        )
    }

    private static func positiveRect(from entry: [String: Any]) -> CGRect? {
        guard let x = entry["x"] as? NSNumber,
              let y = entry["y"] as? NSNumber,
              let width = entry["width"] as? NSNumber,
              let height = entry["height"] as? NSNumber,
              width.doubleValue > 0,
              height.doubleValue > 0
        else { return nil }
        return CGRect(
            x: x.doubleValue,
            y: y.doubleValue,
            width: width.doubleValue,
            height: height.doubleValue
        )
    }

    private static func displayID(from entry: [String: Any]) -> String? {
        if let number = entry["displayId"] as? NSNumber {
            return number.stringValue
        }
        return entry["displayId"] as? String
    }

    private static func mascotMetrics(
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
            if Self.metricsAreValid(metrics, for: overlayRect.size) { return metrics }
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
            if Self.metricsAreValid(metrics, for: overlayRect.size) { return metrics }
        }
        return nil
    }

    private static func metricsAreValid(_ metrics: StoredMascotMetrics, for size: CGSize) -> Bool {
        metrics.width >= 40
            && metrics.height >= 40
            && metrics.left >= -2
            && metrics.top >= -2
            && metrics.left + metrics.width <= size.width + 2
            && metrics.top + metrics.height <= size.height + 2
    }

    private func bestStoredMetrics(matching liveRect: CGRect) -> StoredMascotMetrics? {
        let matches = storedOverlayLocations.compactMap { stored -> (StoredMascotMetrics, Double)? in
            guard stored.hasExactOverlayBounds,
                  let metrics = stored.mascot
            else { return nil }
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
            guard let converted = convertToAppKit(stored.rect) else { continue }
            if let mascot = stored.mascot {
                if stored.hasExactOverlayBounds {
                    cachedMascotMetrics = mascot
                }
                return LocatedPet(
                    overlayRect: converted.0,
                    visibleRect: visibleRect(in: converted.0, metrics: mascot),
                    screen: converted.1,
                    source: "saved-\(mascot.source)"
                )
            }
            if let visibleRect = geometricFallbackVisibleRect(in: converted.0) {
                return LocatedPet(
                    overlayRect: converted.0,
                    visibleRect: visibleRect,
                    screen: converted.1,
                    source: "saved-geometry-fallback"
                )
            }
        }
        return nil
    }

    private func probeTopVisualInset(windowID: CGWindowID) -> CGFloat? {
        // 预检只读取当前 TCC 状态，不触发授权弹窗；未授权时让调用方使用几何回退。
        guard CGPreflightScreenCaptureAccess() else { return nil }

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
        if Self.isPanelWindow(window) {
            return nil
        }

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

        if let distance = storedOverlayLocations.compactMap({ stored -> CGFloat? in
            guard stored.hasExactOverlayBounds else { return nil }
            return hypot(bounds.midX - stored.rect.midX, bounds.midY - stored.rect.midY)
        }).min() {
            score += Double(distance * 0.08)
        }
        return (bounds, score)
    }

    private static func isPanelWindow(_ window: [String: Any]) -> Bool {
        if let ownerPID = window[kCGWindowOwnerPID as String] as? NSNumber,
           ownerPID.int32Value == ProcessInfo.processInfo.processIdentifier
        {
            return true
        }

        if let ownerName = window[kCGWindowOwnerName as String] as? String,
           panelWindowOwnerNames.contains(ownerName)
        {
            return true
        }

        guard let ownerPID = window[kCGWindowOwnerPID as String] as? NSNumber,
              let panelBundleIdentifier = Bundle.main.bundleIdentifier,
              let application = NSRunningApplication(processIdentifier: ownerPID.int32Value)
        else { return false }
        return application.bundleIdentifier == panelBundleIdentifier
    }

    /// 只输出 Codex/ChatGPT 自身的窗口元数据，不暴露任务标题或其他应用窗口。
    func windowDiagnostics() -> [String] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return ["pet-window-diagnostics: Quartz 查询失败"]
        }

        return windows.compactMap { window in
            guard let ownerName = window[kCGWindowOwnerName as String] as? String else {
                return nil
            }
            let normalizedOwner = ownerName.lowercased()
            guard normalizedOwner.contains("codex") || normalizedOwner.contains("chatgpt") else {
                return nil
            }

            let windowID = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -999
            let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? -1
            let rawBounds = window[kCGWindowBounds as String] as? NSDictionary
            let bounds = rawBounds.flatMap(CGRect.init(dictionaryRepresentation:))
            let rawName = window[kCGWindowName as String] as? String ?? ""
            let nameKind: String
            if rawName.isEmpty {
                nameKind = "empty"
            } else if rawName == "Codex" || rawName == "ChatGPT" {
                nameKind = "app"
            } else {
                nameKind = "other"
            }
            let candidate = candidate(from: window)
            let size = bounds.map {
                "\(Int($0.width.rounded()))x\(Int($0.height.rounded()))"
            } ?? "unknown"
            return "pet-window: id=\(windowID) owner=\(ownerName) title=\(nameKind) layer=\(layer) alpha=\(String(format: "%.2f", alpha)) size=\(size) candidate=\(candidate == nil ? "no" : "yes")"
        }
    }

    static func stateCompatibilitySelfTest() -> Bool {
        let legacyRoot: [String: Any] = [
            "electron-avatar-overlay-open": true,
            "electron-avatar-overlay-bounds": [
                "x": 500,
                "y": 300,
                "width": 408,
                "height": 400,
                "mascot": ["left": 221, "top": 196, "width": 107, "height": 116],
            ],
        ]
        let compactRoot: [String: Any] = [
            "electron-avatar-overlay-open": true,
            "electron-avatar-overlay-bounds": [
                "x": 1_199,
                "y": 452,
                "displayId": 1,
                "displayBounds": ["x": 0, "y": 0, "width": 1_512, "height": 945],
                "placement": "top-end",
            ],
        ]
        let anchorRoot: [String: Any] = [
            "electron-avatar-overlay-open": true,
            "electron-avatar-overlay-bounds": [
                "x": 500,
                "y": 300,
                "displayId": 1,
                "displayBounds": ["x": 0, "y": 0, "width": 1_512, "height": 945],
                "anchor": ["x": 520, "y": 318, "width": 120, "height": 130],
            ],
        ]

        let legacy = Self.parseStoredOverlayState(legacyRoot).locations.first
        let compact = Self.parseStoredOverlayState(compactRoot).locations.first
        let anchor = Self.parseStoredOverlayState(anchorRoot).locations.first

        return legacy?.hasExactOverlayBounds == true
            && legacy?.rect == CGRect(x: 500, y: 300, width: 408, height: 400)
            && legacy?.mascot?.source == "state-mascot"
            && compact?.hasExactOverlayBounds == false
            && compact?.rect == CGRect(x: 1_199, y: 452, width: 112, height: 121)
            && compact?.mascot?.source == "state-compact-anchor"
            && anchor?.hasExactOverlayBounds == false
            && anchor?.rect == CGRect(x: 520, y: 318, width: 120, height: 130)
            && anchor?.mascot?.source == "state-anchor"
    }

    static func candidateOwnershipSelfTest() -> Bool {
        let locator = PetWindowLocator()
        let bounds = CGRect(x: 100, y: 200, width: 356, height: 320)
            .dictionaryRepresentation
        let foreignWindow: [String: Any] = [
            kCGWindowOwnerName as String: "ChatGPT",
            kCGWindowOwnerPID as String: NSNumber(
                value: ProcessInfo.processInfo.processIdentifier + 1
            ),
            kCGWindowLayer as String: NSNumber(value: 3),
            kCGWindowAlpha as String: NSNumber(value: 1.0),
            kCGWindowBounds as String: bounds,
        ]
        var ownWindow = foreignWindow
        ownWindow[kCGWindowOwnerName as String] = "Codex 状态面板"
        ownWindow[kCGWindowOwnerPID as String] = NSNumber(
            value: ProcessInfo.processInfo.processIdentifier
        )
        var separatePanelWindow = foreignWindow
        separatePanelWindow[kCGWindowOwnerName as String] = "Codex 状态面板"
        return locator.candidate(from: foreignWindow) != nil
            && locator.candidate(from: ownWindow) == nil
            && locator.candidate(from: separatePanelWindow) == nil
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
