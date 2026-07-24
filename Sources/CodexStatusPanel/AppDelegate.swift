// 应用编排层：创建状态栏和面板，并协调额度、任务、行情与宠物窗口定位。
// 这里负责“何时调用”，具体读取、定位和绘制分别交给其他文件中的类型。

import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // 这些服务对象各自封装一种数据来源；AppDelegate 只负责编排刷新时机和界面状态。
    private let quotaProvider = makeQuotaUsageProvider(
        configuration: panelConfig.usageProvider
    )
    private let taskProgressReader = CodexTaskProgressReader()
    private let btcPriceClient = MarketPriceClient(symbol: "BTCUSDT")
    private let ethPriceClient = MarketPriceClient(symbol: "ETHUSDT")
    private let locator = PetWindowLocator()
    private let healthWriter = RuntimeHealthWriter()
    private let quotaView = QuotaPanelView(frame: NSRect(origin: .zero, size: expandedPanelSize))
    private var currentExpandedPanelSize = expandedPanelSize
    // `!` 是隐式解包可选值：属性初始化时尚无窗口，但 applicationDidFinishLaunching 会立即创建。
    private var panel: NSPanel!
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private let codexStatusMenuItem = NSMenuItem()
    private let followStatusMenuItem = NSMenuItem()
    private let showPanelMenuItem = NSMenuItem(title: "显示面板", action: #selector(showPanelFromMenu(_:)), keyEquivalent: "")
    private let hidePanelMenuItem = NSMenuItem(title: "隐藏面板", action: #selector(hidePanelFromMenu(_:)), keyEquivalent: "")
    private let collapsePanelMenuItem = NSMenuItem(title: "折叠面板", action: #selector(toggleCollapsedFromMenu(_:)), keyEquivalent: "")
    private let refreshQuotaMenuItem = NSMenuItem(title: "立即刷新额度", action: #selector(refreshQuotaFromMenu(_:)), keyEquivalent: "r")
    private let toggleMarketPricesMenuItem = NSMenuItem(
        title: "显示行情列表",
        action: #selector(toggleMarketPricesFromMenu(_:)),
        keyEquivalent: ""
    )
    private let resetFollowMenuItem = NSMenuItem(title: "重置跟随位置", action: #selector(resetFollowPositionFromMenu(_:)), keyEquivalent: "")
    private let openConfigMenuItem = NSMenuItem(title: "打开配置文件", action: #selector(openConfigFileFromMenu(_:)), keyEquivalent: ",")
    private var refreshTimer: Timer?
    private var taskProgressTimer: Timer?
    private var btcRefreshTimer: Timer?
    private var followTimer: Timer?
    private var isRefreshing = false
    private var isRefreshingTaskProgress = false
    private var isRefreshingBTCPrice = false
    private var isRefreshingETHPrice = false
    private var showsMarketPrices = initialMarketPricesEnabled
    private var lastBTCPrice: Double?
    private var lastETHPrice: Double?
    private var codexConnectionStatus = "disconnected"
    private var followHealthStatus = "waiting-for-pet"
    private var lastLocationSource: String?
    private var lastQuotaUpdatedAt: Date?
    private var isPanelHiddenByUser = false
    private var isManualStandaloneEnabled = false
    private var lastStatusMenuSignature = ""
    private var lastStatusBarDisplayState: MenuBarDisplayState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // accessory 模式不会在 Dock 中显示普通 App 图标，只保留菜单栏状态项和浮动面板。
        NSApp.setActivationPolicy(.accessory)
        reportPanelConfigWarnings()
        quotaView.quotaSourceName = quotaProvider.sourceDisplayName
        makeStatusItem()
        makePanel()
        quotaView.showsMarketPrices = showsMarketPrices
        writeHealth(status: "started", panelVisible: false, locationSource: nil, force: true)
        followPet()
        refreshQuota()
        refreshTaskProgress()
        if showsMarketPrices {
            refreshBTCPrice()
            refreshETHPrice()
        }

        // 定时器会持有闭包；使用 weak self 避免闭包反过来强持有 AppDelegate。
        followTimer = Timer.scheduledTimer(withTimeInterval: followInterval, repeats: true) { [weak self] _ in
            self?.followPet()
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshQuota()
        }
        taskProgressTimer = Timer.scheduledTimer(
            withTimeInterval: taskProgressRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            self?.refreshTaskProgress()
        }
        if showsMarketPrices {
            btcRefreshTimer = Timer.scheduledTimer(withTimeInterval: btcRefreshInterval, repeats: true) { [weak self] _ in
                self?.refreshBTCPrice()
                self?.refreshETHPrice()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        quotaView.setRunningTaskBadgeAnimationsEnabled(false)
        refreshTimer?.invalidate()
        taskProgressTimer?.invalidate()
        btcRefreshTimer?.invalidate()
        followTimer?.invalidate()
        writeHealth(status: "terminated", panelVisible: false, locationSource: nil, force: true)
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateStatusMenu(force: true)
    }

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusMenu.delegate = self

        codexStatusMenuItem.isEnabled = false
        followStatusMenuItem.isEnabled = false
        statusMenu.addItem(codexStatusMenuItem)
        statusMenu.addItem(followStatusMenuItem)
        statusMenu.addItem(.separator())

        for item in [
            showPanelMenuItem,
            hidePanelMenuItem,
            collapsePanelMenuItem,
            refreshQuotaMenuItem,
            toggleMarketPricesMenuItem,
            resetFollowMenuItem,
            openConfigMenuItem,
        ] {
            item.target = self
            statusMenu.addItem(item)
        }

        statusMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitFromMenu(_:)), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)

        if let button = statusItem?.button {
            button.imagePosition = .imageOnly
        }
        statusItem?.menu = statusMenu
        updateStatusMenu(force: true)
    }

    private func updateStatusMenu(force: Bool = false) {
        let quotaUpdatedText: String
        if isRefreshing {
            quotaUpdatedText = "读取中"
        } else if let lastQuotaUpdatedAt {
            quotaUpdatedText = Self.timeFormatter.string(from: lastQuotaUpdatedAt)
        } else {
            quotaUpdatedText = quotaView.statusText
        }

        let quotaTitle = "\(quotaView.quotaSourceName)：\(quotaView.connectionText) · 额度：\(quotaUpdatedText)"
        let followTitle: String
        if isPanelHiddenByUser {
            followTitle = "面板：已隐藏"
        } else if let lastLocationSource {
            followTitle = "跟随：\(quotaView.followStatusText) · \(lastLocationSource)"
        } else {
            followTitle = "跟随：\(quotaView.followStatusText)"
        }
        let controlState = panelMenuControlState(
            isPanelVisible: panel?.isVisible ?? false,
            isPanelHiddenByUser: isPanelHiddenByUser,
            isCollapsed: quotaView.isCollapsed,
            isRefreshing: isRefreshing,
            showsMarketPrices: showsMarketPrices
        )
        // 只有菜单显示内容真正变化时才更新 AppKit 对象，减少高频跟随期间的无效工作。
        let signature = [
            quotaTitle,
            followTitle,
            String(controlState.showPanelEnabled),
            String(controlState.hidePanelEnabled),
            controlState.collapseTitle,
            String(controlState.refreshQuotaEnabled),
            String(controlState.marketPricesEnabled),
        ].joined(separator: "|")

        if force || signature != lastStatusMenuSignature {
            codexStatusMenuItem.title = quotaTitle
            followStatusMenuItem.title = followTitle
            showPanelMenuItem.isEnabled = controlState.showPanelEnabled
            hidePanelMenuItem.isEnabled = controlState.hidePanelEnabled
            collapsePanelMenuItem.title = controlState.collapseTitle
            refreshQuotaMenuItem.isEnabled = controlState.refreshQuotaEnabled
            toggleMarketPricesMenuItem.state = controlState.marketPricesEnabled
                ? .on
                : .off
            lastStatusMenuSignature = signature
        }
        updateStatusBarIcon()
    }

    private func updateStatusBarIcon() {
        guard let button = statusItem?.button else { return }
        let iconFollowStatus = isPanelHiddenByUser ? "following-pet" : followHealthStatus
        let state = menuBarDisplayState(
            isRefreshing: isRefreshing,
            codexConnectionStatus: codexConnectionStatus,
            followHealthStatus: iconFollowStatus
        )
        guard state != lastStatusBarDisplayState else { return }
        let tooltip = statusBarTooltip(
            for: state,
            quotaSourceName: quotaView.quotaSourceName
        )

        if let image = NSImage(systemSymbolName: statusBarSymbolName(for: state), accessibilityDescription: tooltip) {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = "Codex"
        }
        button.toolTip = tooltip
        lastStatusBarDisplayState = state
    }

    private func makePanel() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: currentExpandedPanelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = quotaView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        quotaView.onToggleCollapsed = { [weak self] in
            self?.toggleCollapsed()
        }
    }

    private func toggleCollapsed() {
        setCollapsed(!quotaView.isCollapsed)
    }

    private func setCollapsed(_ isCollapsed: Bool) {
        guard quotaView.isCollapsed != isCollapsed else {
            updateStatusMenu()
            return
        }
        quotaView.isCollapsed = isCollapsed
        panel.setContentSize(
            quotaView.isCollapsed
                ? collapsedPanelSize
                : currentExpandedPanelSize
        )
        panel.invalidateShadow()
        if !isPanelHiddenByUser {
            followPet(forceStandaloneFallback: isManualStandaloneEnabled)
        }
        updateStatusMenu()
    }

    @objc private func showPanelFromMenu(_ sender: Any?) {
        isPanelHiddenByUser = false
        isManualStandaloneEnabled = true
        followPet(forceStandaloneFallback: true)
        updateStatusMenu()
    }

    @objc private func hidePanelFromMenu(_ sender: Any?) {
        isManualStandaloneEnabled = false
        isPanelHiddenByUser = true
        quotaView.setRunningTaskBadgeAnimationsEnabled(false)
        if panel.isVisible {
            panel.orderOut(nil)
        }
        quotaView.followStatusText = "已隐藏"
        followHealthStatus = "hidden-by-user"
        lastLocationSource = nil
        writeHealth(status: "hidden-by-user", panelVisible: false, locationSource: nil, force: true)
        updateStatusMenu()
    }

    @objc private func toggleCollapsedFromMenu(_ sender: Any?) {
        setCollapsed(!quotaView.isCollapsed)
    }

    @objc private func refreshQuotaFromMenu(_ sender: Any?) {
        refreshQuota()
        updateStatusMenu()
    }

    @objc private func toggleMarketPricesFromMenu(_ sender: Any?) {
        setMarketPricesEnabled(!showsMarketPrices)
    }

    private func setMarketPricesEnabled(_ enabled: Bool) {
        guard showsMarketPrices != enabled else {
            updateStatusMenu()
            return
        }

        showsMarketPrices = enabled
        UserDefaults.standard.set(enabled, forKey: marketPricesPreferenceKey)
        quotaView.showsMarketPrices = enabled

        if enabled {
            refreshBTCPrice()
            refreshETHPrice()
            if btcRefreshTimer == nil {
                btcRefreshTimer = Timer.scheduledTimer(
                    withTimeInterval: btcRefreshInterval,
                    repeats: true
                ) { [weak self] _ in
                    self?.refreshBTCPrice()
                    self?.refreshETHPrice()
                }
            }
        } else {
            btcRefreshTimer?.invalidate()
            btcRefreshTimer = nil
        }

        currentExpandedPanelSize = panelSizeForTaskRows(
            quotaView.taskProgress.rowCount,
            showsMarketPrices: enabled
        )
        if !quotaView.isCollapsed {
            panel.setContentSize(currentExpandedPanelSize)
        }
        if !isPanelHiddenByUser {
            followPet(forceStandaloneFallback: isManualStandaloneEnabled)
        }
        writeHealth(
            status: enabled ? "market-prices-shown" : "market-prices-hidden",
            panelVisible: panel.isVisible,
            locationSource: lastLocationSource,
            force: true
        )
        updateStatusMenu(force: true)
    }

    @objc private func resetFollowPositionFromMenu(_ sender: Any?) {
        locator.reset()
        isPanelHiddenByUser = false
        isManualStandaloneEnabled = false
        followPet()
        updateStatusMenu()
    }

    @objc private func openConfigFileFromMenu(_ sender: Any?) {
        if let editableConfigURL = ensureEditablePanelConfigFile() {
            NSWorkspace.shared.open(editableConfigURL)
        } else {
            NSWorkspace.shared.open(editablePanelConfigFileURL.deletingLastPathComponent())
        }
    }

    @objc private func quitFromMenu(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    private func followPet(forceStandaloneFallback: Bool = false) {
        // 这是跟随功能的状态分支：用户隐藏 → 找不到桌宠时回退/等待 → 找到后精确跟随。
        guard !isPanelHiddenByUser else {
            quotaView.setRunningTaskBadgeAnimationsEnabled(false)
            if panel.isVisible {
                panel.orderOut(nil)
            }
            quotaView.followStatusText = "已隐藏"
            followHealthStatus = "hidden-by-user"
            lastLocationSource = nil
            writeHealth(status: "hidden-by-user", panelVisible: false, locationSource: nil)
            updateStatusMenu()
            return
        }

        guard let pet = locator.locate() else {
            lastLocationSource = nil
            if forceStandaloneFallback || isManualStandaloneEnabled || shouldShowStandalonePanel() {
                showStandalonePanel()
                quotaView.followStatusText = "固定显示"
                followHealthStatus = "screen-fallback"
                lastLocationSource = "screen-fallback"
                writeHealth(
                    status: "fallback-visible",
                    panelVisible: true,
                    locationSource: "screen-fallback"
                )
            } else {
                quotaView.setRunningTaskBadgeAnimationsEnabled(false)
                panel.orderOut(nil)
                quotaView.followStatusText = "等待桌宠"
                followHealthStatus = "waiting-for-pet"
                writeHealth(status: "waiting-for-codex", panelVisible: false, locationSource: nil)
            }
            updateStatusMenu()
            return
        }

        quotaView.followStatusText = "跟随中"
        followHealthStatus = "following-pet"
        lastLocationSource = pet.source
        let currentPanelSize = quotaView.isCollapsed
            ? collapsedPanelSize
            : currentExpandedPanelSize
        // 定位器只给出桌宠区域；最终面板原点和指针位置由纯几何函数计算。
        let placement = panelPlacement(
            petVisibleRect: pet.visibleRect,
            panelSize: currentPanelSize,
            screenVisibleFrame: pet.screen.visibleFrame
        )

        quotaView.pointerSide = .bottom
        quotaView.pointerCenterX = placement.pointerCenterX
        let targetOrigin = placement.origin
        if panel.frame.origin != targetOrigin {
            panel.setFrameOrigin(targetOrigin)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        quotaView.setRunningTaskBadgeAnimationsEnabled(true)
        writeHealth(
            status: "following-pet",
            panelVisible: true,
            locationSource: pet.source,
            gap: placement.actualGap,
            centerError: placement.centerError
        )
        updateStatusMenu()
    }

    private func shouldShowStandalonePanel() -> Bool {
        if let overlayOpen = locator.overlayOpen { return overlayOpen }

        return NSWorkspace.shared.runningApplications.contains { application in
            let name = application.localizedName?.lowercased() ?? ""
            let bundleID = application.bundleIdentifier?.lowercased() ?? ""
            return name == "codex"
                || name == "chatgpt"
                || bundleID.contains("openai.codex")
                || bundleID.contains("openai.chat")
        }
    }

    private func showStandalonePanel() {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let visible = screen.visibleFrame
        let currentPanelSize = quotaView.isCollapsed
            ? collapsedPanelSize
            : currentExpandedPanelSize
        let origin = NSPoint(
            x: (visible.maxX - currentPanelSize.width - 24).rounded(),
            y: (visible.maxY - currentPanelSize.height - 24).rounded()
        )
        quotaView.pointerSide = .bottom
        quotaView.pointerCenterX = currentPanelSize.width / 2
        if panel.frame.origin != origin {
            panel.setFrameOrigin(origin)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        quotaView.setRunningTaskBadgeAnimationsEnabled(true)
    }

    private func refreshQuota() {
        guard !isRefreshing else { return }
        isRefreshing = true
        if quotaView.quotaPresentation == nil {
            quotaView.errorText = nil
            quotaView.statusText = "正在读取额度…"
        } else {
            quotaView.statusText = "正在更新…"
        }
        updateStatusMenu()

        // 客户端在后台队列回调；先准备错误文案，再切回主线程修改 AppKit 界面。
        quotaProvider.fetch { [weak self] result in
            let errorText: String?
            if case .failure(let error) = result {
                errorText = quotaErrorDisplayText(error) {
                    CodexConfigurationReader.modelProvider(
                        at: codexConfigurationURL()
                    )
                }
            } else {
                errorText = nil
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshing = false
                self.quotaView.quotaPresentation = quotaPresentationAfterRefresh(
                    previous: self.quotaView.quotaPresentation,
                    result: result
                )
                switch result {
                case .success(let presentation):
                    self.quotaView.quotaSourceName = presentation.sourceName
                    self.quotaView.errorText = nil
                    self.codexConnectionStatus = "connected"
                    self.quotaView.connectionText = "已连接"
                    let now = Date()
                    self.lastQuotaUpdatedAt = now
                    self.quotaView.statusText = Self.timeFormatter.string(from: now)
                case .failure(let error):
                    self.codexConnectionStatus = "disconnected"
                    self.quotaView.connectionText = "未连接"
                    if self.quotaView.quotaPresentation == nil {
                        self.quotaView.errorText = errorText
                            ?? error.localizedDescription
                    } else {
                        self.quotaView.errorText = nil
                    }
                    self.quotaView.statusText = "重试中"
                }
                self.updateStatusMenu()
            }
        }
    }

    private func refreshTaskProgress() {
        guard !isRefreshingTaskProgress else { return }
        isRefreshingTaskProgress = true

        // 日志扫描可能访问较多文件，放到 utility 队列，避免阻塞菜单和面板绘制。
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let snapshot = self.taskProgressReader.read()
            // 所有 NSView / NSPanel 状态都必须回到主线程更新。
            DispatchQueue.main.async {
                self.isRefreshingTaskProgress = false
                self.quotaView.taskProgress = snapshot
                let nextSize = panelSizeForTaskRows(
                    snapshot.rowCount,
                    showsMarketPrices: self.showsMarketPrices
                )
                guard nextSize != self.currentExpandedPanelSize else {
                    return
                }

                self.currentExpandedPanelSize = nextSize
                if !self.quotaView.isCollapsed {
                    self.panel.setContentSize(nextSize)
                }
                if !self.isPanelHiddenByUser {
                    self.followPet(
                        forceStandaloneFallback: self.isManualStandaloneEnabled
                    )
                }
            }
        }
    }

    private func writeHealth(
        status: String,
        panelVisible: Bool,
        locationSource: String?,
        gap: CGFloat? = nil,
        centerError: CGFloat? = nil,
        force: Bool = false
    ) {
        healthWriter.write(
            status: status,
            panelVisible: panelVisible,
            locationSource: locationSource,
            codexConnectionStatus: codexConnectionStatus,
            followStatus: followHealthStatus,
            marketPricesEnabled: showsMarketPrices,
            panelHeight: currentExpandedPanelSize.height,
            gap: gap,
            centerError: centerError,
            force: force
        )
    }

    private func refreshBTCPrice() {
        guard showsMarketPrices, !isRefreshingBTCPrice else { return }
        isRefreshingBTCPrice = true

        btcPriceClient.fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshingBTCPrice = false
                guard self.showsMarketPrices else { return }
                switch result {
                case .success(let price):
                    if let previousPrice = self.lastBTCPrice {
                        self.quotaView.btcPriceDirection = price > previousPrice ? 1 : (price < previousPrice ? -1 : 0)
                    } else {
                        self.quotaView.btcPriceDirection = 0
                    }
                    self.lastBTCPrice = price
                    self.quotaView.btcPrice = price
                    self.quotaView.btcStatusText = "5秒"
                case .failure:
                    self.quotaView.btcStatusText = self.quotaView.btcPrice == nil ? "重试中" : "暂离线"
                }
            }
        }
    }

    private func refreshETHPrice() {
        guard showsMarketPrices, !isRefreshingETHPrice else { return }
        isRefreshingETHPrice = true

        ethPriceClient.fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshingETHPrice = false
                guard self.showsMarketPrices else { return }
                switch result {
                case .success(let price):
                    if let previousPrice = self.lastETHPrice {
                        self.quotaView.ethPriceDirection = price > previousPrice ? 1 : (price < previousPrice ? -1 : 0)
                    } else {
                        self.quotaView.ethPriceDirection = 0
                    }
                    self.lastETHPrice = price
                    self.quotaView.ethPrice = price
                    self.quotaView.ethStatusText = "5秒"
                case .failure:
                    self.quotaView.ethStatusText = self.quotaView.ethPrice == nil ? "重试中" : "暂离线"
                }
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

}
