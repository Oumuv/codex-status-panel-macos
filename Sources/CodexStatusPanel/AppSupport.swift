// App 运行期间使用的基础设施：单实例锁、菜单状态、定位计算和健康状态缓存。
// 这些类型不直接绘制界面，而是为 AppDelegate 提供可复用的小块能力。

import AppKit
import Darwin
import Foundation

enum SingleInstanceLockError: LocalizedError {
    case alreadyRunning
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "已有 Codex 状态面板实例正在运行"
        case .unavailable(let detail):
            return "无法创建单实例锁：\(detail)"
        }
    }
}

/// 用非阻塞文件锁保证同一用户只运行一个面板实例。
/// 对象释放时 `deinit` 自动解锁并关闭文件描述符，因此调用方必须持有这个对象。
final class SingleInstanceLock {
    private let fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    static func acquire() throws -> SingleInstanceLock {
        let lockDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/\(defaultBundleIdentifier)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        } catch {
            throw SingleInstanceLockError.unavailable(error.localizedDescription)
        }

        let lockURL = lockDirectory.appendingPathComponent("instance.lock")
        // Darwin.open 需要 C 字符串；withCString 只在闭包执行期间提供安全指针。
        let fileDescriptor = lockURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard fileDescriptor >= 0 else {
            throw SingleInstanceLockError.unavailable(String(cString: strerror(errno)))
        }

        // LOCK_NB 表示立即返回；已有进程持锁时不会卡住第二个启动过程。
        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            _ = Darwin.close(fileDescriptor)
            if lockError == EWOULDBLOCK {
                throw SingleInstanceLockError.alreadyRunning
            }
            throw SingleInstanceLockError.unavailable(String(cString: strerror(lockError)))
        }

        return SingleInstanceLock(fileDescriptor: fileDescriptor)
    }

    deinit {
        _ = flock(fileDescriptor, LOCK_UN)
        _ = Darwin.close(fileDescriptor)
    }
}

enum MenuBarDisplayState: Equatable {
    case normal
    case refreshing
    case disconnected
    case followAttention
}

struct PanelMenuControlState: Equatable {
    let showPanelEnabled: Bool
    let hidePanelEnabled: Bool
    let collapseTitle: String
    let refreshQuotaEnabled: Bool
    let marketPricesEnabled: Bool
}

/// 纯函数：把当前运行状态转换成菜单项是否可用及其文案，便于独立自测。
func panelMenuControlState(
    isPanelVisible: Bool,
    isPanelHiddenByUser: Bool,
    isCollapsed: Bool,
    isRefreshing: Bool,
    showsMarketPrices: Bool
) -> PanelMenuControlState {
    PanelMenuControlState(
        showPanelEnabled: isPanelHiddenByUser || !isPanelVisible,
        hidePanelEnabled: isPanelVisible && !isPanelHiddenByUser,
        collapseTitle: collapsedMenuItemTitle(isCollapsed: isCollapsed),
        refreshQuotaEnabled: !isRefreshing,
        marketPricesEnabled: showsMarketPrices
    )
}

func menuBarDisplayState(
    isRefreshing: Bool,
    codexConnectionStatus: String,
    followHealthStatus: String
) -> MenuBarDisplayState {
    if isRefreshing { return .refreshing }
    if codexConnectionStatus != "connected" { return .disconnected }
    if followHealthStatus == "screen-fallback" || followHealthStatus == "waiting-for-pet" {
        return .followAttention
    }
    return .normal
}

func statusBarSymbolName(for state: MenuBarDisplayState) -> String {
    switch state {
    case .normal:
        return "bolt.circle"
    case .refreshing:
        return "arrow.clockwise.circle"
    case .disconnected:
        return "bolt.slash.circle"
    case .followAttention:
        return "location.slash.circle"
    }
}

func statusBarTooltip(for state: MenuBarDisplayState) -> String {
    switch state {
    case .normal:
        return "Codex 状态面板：正常"
    case .refreshing:
        return "Codex 状态面板：正在读取"
    case .disconnected:
        return "Codex 状态面板：Codex 未连接"
    case .followAttention:
        return "Codex 状态面板：跟随目标不可用"
    }
}

func collapsedMenuItemTitle(isCollapsed: Bool) -> String {
    isCollapsed ? "展开面板" : "折叠面板"
}

struct PanelPlacement {
    let origin: NSPoint
    let pointerCenterX: CGFloat
    let actualGap: CGFloat
    let centerError: CGFloat
}

/// 让面板指针尽量对准桌宠可见区域的水平中心，并维持配置中的垂直间距。
/// 全部计算使用 AppKit 逻辑点，因此 Retina 或缩放屏幕上的视觉距离保持一致。
func panelPlacement(
    petVisibleRect: NSRect,
    panelSize: NSSize,
    screenVisibleFrame: NSRect
) -> PanelPlacement {
    let minX = screenVisibleFrame.minX + panelScreenMargin
    let maxX = max(minX, screenVisibleFrame.maxX - panelSize.width - panelScreenMargin)
    let desiredX = petVisibleRect.midX - panelSize.width / 2
    let x = min(max(desiredX, minX), maxX)

    let minY = screenVisibleFrame.minY + panelScreenMargin
    let maxY = max(minY, screenVisibleFrame.maxY - panelSize.height - panelScreenMargin)
    let desiredTipY = petVisibleRect.maxY + panelPetGap
    let desiredY = desiredTipY - pointerTipBottomInset
    let y = min(max(desiredY, minY), maxY)

    let originX = x
    let originY = y
    let rawPointerCenterX = petVisibleRect.midX - originX
    let safeMinX = min(pointerHorizontalSafeInset, panelSize.width / 2)
    let safeMaxX = max(safeMinX, panelSize.width - safeMinX)
    let pointerCenterX = min(max(rawPointerCenterX, safeMinX), safeMaxX)
    let actualPointerX = originX + pointerCenterX
    let actualPointerTipY = originY + pointerTipBottomInset

    return PanelPlacement(
        origin: NSPoint(x: originX, y: originY),
        pointerCenterX: pointerCenterX,
        actualGap: actualPointerTipY - petVisibleRect.maxY,
        centerError: actualPointerX - petVisibleRect.midX
    )
}

func geometricFallbackVisibleRect(in overlayRect: NSRect) -> NSRect? {
    let aspectRatio = overlayRect.width / max(1, overlayRect.height)
    guard overlayRect.width >= 360,
          overlayRect.height >= 360,
          abs(aspectRatio - (408.0 / 400.0)) <= 0.12
    else { return nil }

    let estimatedWidth = overlayRect.width * (107.0 / 408.0)
    let estimatedHeight = max(1, estimatedWidth * (177.0 / 163.0) - petSpriteTopPaddingInsideAnchor)
    let visibleTop = overlayRect.maxY - overlayRect.height * (274.0 / 400.0)
    return NSRect(
        x: overlayRect.midX - estimatedWidth / 2,
        y: visibleTop - estimatedHeight,
        width: estimatedWidth,
        height: estimatedHeight
    )
}

final class RuntimeHealthWriter {
    private let fileURL: URL = {
        if let override = ProcessInfo.processInfo.environment["CODEX_STATUS_PANEL_HEALTH_FILE"],
           !override.isEmpty
        {
            return URL(fileURLWithPath: override)
        }
        if let override = ProcessInfo.processInfo.environment["CODEX_PANEL_HEALTH_FILE"],
           !override.isEmpty
        {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/\(defaultBundleIdentifier)/panel-health.json")
    }()
    private var lastSignature = ""
    private var lastWriteAt: CFAbsoluteTime = 0

    func write(
        status: String,
        panelVisible: Bool,
        locationSource: String?,
        codexConnectionStatus: String,
        followStatus: String,
        marketPricesEnabled: Bool,
        panelHeight: CGFloat,
        gap: CGFloat? = nil,
        centerError: CGFloat? = nil,
        force: Bool = false
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        // 签名没有变化时最多 15 秒写一次，避免高频跟随逻辑持续刷新磁盘文件。
        let signature = [
            status,
            String(panelVisible),
            locationSource ?? "none",
            codexConnectionStatus,
            followStatus,
            String(marketPricesEnabled),
            String(format: "%.1f", panelHeight),
        ].joined(separator: "|")
        guard force || signature != lastSignature || now - lastWriteAt >= 15 else { return }

        var payload: [String: Any] = [
            "codexConnectionStatus": codexConnectionStatus,
            "followStatus": followStatus,
            "locationSource": locationSource ?? NSNull(),
            "version": panelVersion,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "status": status,
            "panelVisible": panelVisible,
            "marketPricesEnabled": marketPricesEnabled,
            "panelHeightPoints": panelHeight,
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let gap { payload["petGapPoints"] = gap }
        if let centerError { payload["pointerCenterErrorPoints"] = centerError }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try data.write(to: fileURL, options: .atomic)
            lastSignature = signature
            lastWriteAt = now
        } catch {
            // 健康缓存只是诊断信息；受管 Mac 禁止写缓存时，面板主体仍应继续工作。
        }
    }
}
