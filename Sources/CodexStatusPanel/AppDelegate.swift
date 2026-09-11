// 应用编排层：创建状态栏和面板，并协调额度、任务、行情与宠物窗口定位。
// 这里负责“何时调用”，具体读取、定位和绘制分别交给其他文件中的类型。

import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // 这些服务对象各自封装一种数据来源；AppDelegate 只负责编排刷新时机和界面状态。
    private var quotaProvider = makeQuotaUsageProvider(
        configuration: panelConfig.usageProvider
    )
    private let taskProgressReader = CodexTaskProgressReader()
    private let btcPriceClient = MarketPriceClient(symbol: "BTCUSDT")
    private let ethPriceClient = MarketPriceClient(symbol: "ETHUSDT")
    private let stockMarketClient = EastMoneyMarketClient()
    private let stockQuoteCache = StockQuoteCache()
    private let locator = PetWindowLocator()
    private let healthWriter = RuntimeHealthWriter()
    private let quotaView = QuotaPanelView(frame: NSRect(origin: .zero, size: expandedPanelSize))
    private var currentExpandedPanelSize = expandedPanelSize
    // `!` 是隐式解包可选值：属性初始化时尚无窗口，但 applicationDidFinishLaunching 会立即创建。
    private var panel: NSPanel!
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private let statusDetailsMenuItem = NSMenuItem(
        title: "状态",
        action: nil,
        keyEquivalent: ""
    )
    private let statusDetailsMenu = NSMenu(title: "状态")
    private let codexStatusMenuItem = NSMenuItem()
    private let followStatusMenuItem = NSMenuItem()
    private let stockStatusMenuItem = NSMenuItem()
    private let panelMenuItem = NSMenuItem(
        title: "面板",
        action: nil,
        keyEquivalent: ""
    )
    private let panelMenu = NSMenu(title: "面板")
    private let togglePanelVisibilityMenuItem = NSMenuItem(
        title: "隐藏面板",
        action: #selector(togglePanelVisibilityFromMenu(_:)),
        keyEquivalent: ""
    )
    private let collapsePanelMenuItem = NSMenuItem(title: "折叠面板", action: #selector(toggleCollapsedFromMenu(_:)), keyEquivalent: "")
    private let refreshQuotaMenuItem = NSMenuItem(title: "立即刷新额度", action: #selector(refreshQuotaFromMenu(_:)), keyEquivalent: "r")
    private let quotaMenuItem = NSMenuItem(
        title: "额度",
        action: nil,
        keyEquivalent: ""
    )
    private let quotaMenu = NSMenu(title: "额度")
    private let displayContentMenuItem = NSMenuItem(
        title: "显示内容",
        action: nil,
        keyEquivalent: ""
    )
    private let displayContentMenu = NSMenu(title: "显示内容")
    private let toggleMarketPricesMenuItem = NSMenuItem(
        title: "显示币价（BTC/ETH）",
        action: #selector(toggleMarketPricesFromMenu(_:)),
        keyEquivalent: ""
    )
    private let toggleStockPricesMenuItem = NSMenuItem(
        title: "显示 A 股行情",
        action: #selector(toggleStockPricesFromMenu(_:)),
        keyEquivalent: ""
    )
    private let resetFollowMenuItem = NSMenuItem(title: "重置跟随位置", action: #selector(resetFollowPositionFromMenu(_:)), keyEquivalent: "")
    private let configurationMenuItem = NSMenuItem(
        title: "配置",
        action: nil,
        keyEquivalent: ""
    )
    private let configurationMenu = NSMenu(title: "配置")
    private let openConfigMenuItem = NSMenuItem(title: "打开配置文件", action: #selector(openConfigFileFromMenu(_:)), keyEquivalent: ",")
    private let reloadConfigMenuItem = NSMenuItem(title: "重新加载配置", action: #selector(reloadConfigFromMenu(_:)), keyEquivalent: "")
    private var refreshTimer: Timer?
    private var taskProgressTimer: Timer?
    private var btcRefreshTimer: Timer?
    private var stockRefreshTimer: Timer?
    private var stockCacheWriteTimer: Timer?
    private var followTimer: Timer?
    private var isRefreshing = false
    private var quotaRefreshGeneration = 0
    private var isRefreshingTaskProgress = false
    private var isRefreshingBTCPrice = false
    private var isRefreshingETHPrice = false
    private var isRefreshingStockPrices = false
    private var showsMarketPrices = initialMarketPricesEnabled
    private var showsStockPrices = initialStockPricesEnabled
    private var lastBTCPrice: Double?
    private var lastETHPrice: Double?
    private var stockRefreshGeneration = 0
    private var pendingStockRequestCount = 0
    private var stockBatchSuccessCount = 0
    private var stockBatchHadMarketChange = false
    private var stockRequestTasks: [HTTPDataTasking] = []
    private var stockQuotesBySecID: [String: StockQuote] = [:]
    private var stockCachedSecIDs = Set<String>()
    private var stockOfflineSecIDs = Set<String>()
    private var stockMarketState: StockMarketDisplayState = .loading
    private var stockActivityTracker = StockActivityTracker()
    private var lastStockUpdatedAt: Date?
    private var stockCacheDirty = false
    private var lastStockCacheWriteAt: Date?
    private var codexConnectionStatus = "disconnected"
    private var followHealthStatus = "waiting-for-pet"
    private var lastLocationSource: String?
    private var lastQuotaUpdatedAt: Date?
    private var cachedCodexDesktopRunning = false
    private var nextCodexDesktopCheckAt: CFAbsoluteTime = 0
    private var isPanelHiddenByUser = false
    private var isStandalonePanelActive = false
    private var lastStatusMenuSignature = ""
    private var lastStatusBarDisplayState: MenuBarDisplayState?
    private lazy var statusBarIconImage: NSImage? = {
        guard let imageURL = Bundle.main.url(forResource: "03-pink", withExtension: "png"),
              let image = NSImage(contentsOf: imageURL) else {
            return nil
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = false
        return image
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // accessory 模式不会在 Dock 中显示普通 App 图标，只保留菜单栏状态项和浮动面板。
        NSApp.setActivationPolicy(.accessory)
        reportPanelConfigWarnings()
        quotaView.quotaSourceName = quotaProvider.sourceDisplayName
        quotaView.showsMarketPrices = showsMarketPrices
        quotaView.showsStockPrices = showsStockPrices
        applyStockConfiguration(loadCache: true)
        makeStatusItem()
        makePanel()
        writeHealth(status: "started", panelVisible: false, locationSource: nil, force: true)
        followPet()
        refreshQuota()
        refreshTaskProgress()
        if showsMarketPrices {
            refreshBTCPrice()
            refreshETHPrice()
        }

        taskProgressTimer = Timer.scheduledTimer(
            withTimeInterval: taskProgressRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            self?.refreshTaskProgress()
        }
        restartConfigurableTimers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        quotaView.setRunningTaskBadgeAnimationsEnabled(false)
        refreshTimer?.invalidate()
        taskProgressTimer?.invalidate()
        btcRefreshTimer?.invalidate()
        stockRefreshTimer?.invalidate()
        stockCacheWriteTimer?.invalidate()
        cancelStockRequests()
        followTimer?.invalidate()
        writeHealth(status: "terminated", panelVisible: false, locationSource: nil, force: true)
    }

    private func restartConfigurableTimers() {
        followTimer?.invalidate()
        refreshTimer?.invalidate()
        btcRefreshTimer?.invalidate()
        btcRefreshTimer = nil
        stockRefreshTimer?.invalidate()
        stockRefreshTimer = nil
        stockCacheWriteTimer?.invalidate()
        stockCacheWriteTimer = nil

        // 定时器会持有闭包；使用 weak self 避免闭包反过来强持有 AppDelegate。
        followTimer = Timer.scheduledTimer(
            withTimeInterval: followInterval,
            repeats: true
        ) { [weak self] _ in
            self?.followPet()
        }
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: refreshInterval,
            repeats: true
        ) { [weak self] _ in
            self?.refreshQuota()
        }
        if showsMarketPrices {
            btcRefreshTimer = Timer.scheduledTimer(
                withTimeInterval: cryptoRefreshInterval,
                repeats: true
            ) { [weak self] _ in
                self?.refreshBTCPrice()
                self?.refreshETHPrice()
            }
        }
        if showsStockPrices {
            refreshStockPrices()
        }
        if stockCacheDirty {
            scheduleStockCacheWriteIfNeeded()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateStatusMenu(force: true)
    }

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusMenu.delegate = self

        for item in [
            togglePanelVisibilityMenuItem,
            collapsePanelMenuItem,
            refreshQuotaMenuItem,
            toggleMarketPricesMenuItem,
            toggleStockPricesMenuItem,
            resetFollowMenuItem,
            openConfigMenuItem,
            reloadConfigMenuItem,
        ] {
            item.target = self
        }

        for item in [
            codexStatusMenuItem,
            followStatusMenuItem,
            stockStatusMenuItem,
        ] {
            item.isEnabled = false
            statusDetailsMenu.addItem(item)
        }
        statusDetailsMenuItem.submenu = statusDetailsMenu

        panelMenu.addItem(togglePanelVisibilityMenuItem)
        panelMenu.addItem(collapsePanelMenuItem)
        panelMenu.addItem(resetFollowMenuItem)
        panelMenuItem.submenu = panelMenu

        quotaMenuItem.submenu = quotaMenu

        displayContentMenu.addItem(toggleMarketPricesMenuItem)
        displayContentMenu.addItem(toggleStockPricesMenuItem)
        displayContentMenuItem.submenu = displayContentMenu

        configurationMenu.addItem(openConfigMenuItem)
        configurationMenu.addItem(reloadConfigMenuItem)
        configurationMenuItem.submenu = configurationMenu

        for item in [
            statusDetailsMenuItem,
            panelMenuItem,
            quotaMenuItem,
            displayContentMenuItem,
            configurationMenuItem,
        ] {
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

        let statusSummaryTitle = "状态：\(quotaView.quotaSourceName) \(quotaView.connectionText)"
        let quotaTitle = "\(quotaView.quotaSourceName)：\(quotaView.connectionText) · 额度：\(quotaUpdatedText)"
        let stockTitle: String
        if showsStockPrices {
            let updated = lastStockUpdatedAt.map(Self.stockTimeFormatter.string)
                ?? "--"
            stockTitle = "A股：\(stockMarketState.text) · \(updated)"
        } else {
            stockTitle = "A股：未显示"
        }
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
            showsMarketPrices: showsMarketPrices,
            showsStockPrices: showsStockPrices
        )
        let rateLimitOptions = quotaView.quotaPresentation?.rateLimitOptions
            ?? []
        let selectedRateLimitID = quotaView.quotaPresentation?
            .selectedRateLimitID
        let panelVisibilityTitle = panelVisibilityMenuItemTitle(
            showPanelEnabled: controlState.showPanelEnabled
        )
        let rateLimitSignature = rateLimitOptions.map {
            "\($0.id):\($0.displayName)"
        }.joined(separator: ",") + "|" + (selectedRateLimitID ?? "")
        // 只有菜单显示内容真正变化时才更新 AppKit 对象，减少高频跟随期间的无效工作。
        let signature = [
            statusSummaryTitle,
            quotaTitle,
            followTitle,
            stockTitle,
            panelVisibilityTitle,
            controlState.collapseTitle,
            String(controlState.refreshQuotaEnabled),
            String(controlState.marketPricesEnabled),
            String(controlState.stockPricesEnabled),
            rateLimitSignature,
        ].joined(separator: "|")

        if force || signature != lastStatusMenuSignature {
            statusDetailsMenuItem.title = statusSummaryTitle
            codexStatusMenuItem.title = quotaTitle
            followStatusMenuItem.title = followTitle
            stockStatusMenuItem.title = stockTitle
            togglePanelVisibilityMenuItem.title = panelVisibilityTitle
            togglePanelVisibilityMenuItem.isEnabled = controlState.showPanelEnabled
                || controlState.hidePanelEnabled
            collapsePanelMenuItem.title = controlState.collapseTitle
            refreshQuotaMenuItem.isEnabled = controlState.refreshQuotaEnabled
            toggleMarketPricesMenuItem.state = controlState.marketPricesEnabled
                ? .on
                : .off
            toggleStockPricesMenuItem.state = controlState.stockPricesEnabled
                ? .on
                : .off
            updateQuotaRateLimitMenu(
                options: rateLimitOptions,
                selectedID: selectedRateLimitID
            )
            lastStatusMenuSignature = signature
        }
        updateStatusBarIcon()
    }

    private func updateQuotaRateLimitMenu(
        options: [QuotaRateLimitOption],
        selectedID: String?
    ) {
        quotaMenu.removeAllItems()
        quotaMenu.addItem(refreshQuotaMenuItem)

        guard !options.isEmpty else {
            quotaMenuItem.title = "额度"
            return
        }

        let selected = options.first { $0.id == selectedID }
            ?? options[0]
        quotaMenuItem.title = "额度：\(selected.displayName)"
        guard options.count > 1 else { return }

        quotaMenu.addItem(.separator())

        for option in options {
            let item = NSMenuItem(
                title: "\(option.displayName)额度",
                action: #selector(selectQuotaRateLimitFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = option.id
            item.state = option.id == selected.id ? .on : .off
            quotaMenu.addItem(item)
        }
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

        button.imageScaling = .scaleProportionallyDown
        if let image = statusBarIconImage {
            image.accessibilityDescription = tooltip
            button.image = image
            button.title = ""
        } else if let image = NSImage(systemSymbolName: statusBarSymbolName(for: state), accessibilityDescription: tooltip) {
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
        panel.isMovable = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        quotaView.onToggleCollapsed = { [weak self] in
            self?.toggleCollapsed()
        }
        quotaView.onCycleRateLimit = { [weak self] in
            self?.cycleQuotaRateLimit()
        }
        quotaView.onWindowDragCompleted = { [weak self] in
            self?.saveStandalonePanelOrigin()
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
            followPet()
        }
        updateStatusMenu()
    }

    @objc private func togglePanelVisibilityFromMenu(_ sender: Any?) {
        if isPanelHiddenByUser || panel?.isVisible != true {
            showPanelFromMenu(sender)
        } else {
            hidePanelFromMenu(sender)
        }
    }

    private func showPanelFromMenu(_ sender: Any?) {
        isPanelHiddenByUser = false
        followPet()
        updateStatusMenu()
    }

    private func hidePanelFromMenu(_ sender: Any?) {
        isPanelHiddenByUser = true
        isStandalonePanelActive = false
        quotaView.allowsWindowDragging = false
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

    @objc private func selectQuotaRateLimitFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        selectQuotaRateLimit(id: id)
    }

    private func selectQuotaRateLimit(id: String) {
        guard let current = quotaView.quotaPresentation else { return }
        let selected = current.selectingRateLimit(id: id)
        guard selected.selectedRateLimitID != current.selectedRateLimitID else {
            updateStatusMenu(force: true)
            return
        }
        quotaView.quotaPresentation = selected
        updateStatusMenu(force: true)
    }

    private func cycleQuotaRateLimit() {
        guard let current = quotaView.quotaPresentation else { return }
        let selected = current.cyclingRateLimit()
        guard selected.selectedRateLimitID != current.selectedRateLimitID else {
            return
        }
        quotaView.quotaPresentation = selected
        updateStatusMenu(force: true)
    }

    @objc private func toggleMarketPricesFromMenu(_ sender: Any?) {
        setMarketPricesEnabled(!showsMarketPrices)
    }

    @objc private func toggleStockPricesFromMenu(_ sender: Any?) {
        setStockPricesEnabled(!showsStockPrices)
    }

    private func setMarketPricesEnabled(
        _ enabled: Bool,
        persistPreference: Bool = true
    ) {
        guard showsMarketPrices != enabled else {
            updateStatusMenu()
            return
        }

        showsMarketPrices = enabled
        if persistPreference {
            UserDefaults.standard.set(enabled, forKey: marketPricesPreferenceKey)
        }
        quotaView.showsMarketPrices = enabled

        if enabled {
            refreshBTCPrice()
            refreshETHPrice()
            if btcRefreshTimer == nil {
                btcRefreshTimer = Timer.scheduledTimer(
                    withTimeInterval: cryptoRefreshInterval,
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

        updateExpandedPanelSize()
        if !isPanelHiddenByUser {
            followPet()
        }
        writeHealth(
            status: enabled ? "market-prices-shown" : "market-prices-hidden",
            panelVisible: panel.isVisible,
            locationSource: lastLocationSource,
            force: true
        )
        updateStatusMenu(force: true)
    }

    private func setStockPricesEnabled(
        _ enabled: Bool,
        persistPreference: Bool = true
    ) {
        if showsStockPrices == enabled {
            quotaView.showsStockPrices = enabled
            updateExpandedPanelSize()
            updateStatusMenu()
            return
        }

        showsStockPrices = enabled
        if persistPreference {
            UserDefaults.standard.set(enabled, forKey: stockPricesPreferenceKey)
        }
        quotaView.showsStockPrices = enabled
        stockRefreshGeneration += 1
        isRefreshingStockPrices = false
        pendingStockRequestCount = 0
        cancelStockRequests()
        stockRefreshTimer?.invalidate()
        stockRefreshTimer = nil

        if enabled {
            refreshStockPrices()
        }

        updateExpandedPanelSize()
        if !isPanelHiddenByUser {
            followPet()
        }
        writeHealth(
            status: enabled ? "stock-prices-shown" : "stock-prices-hidden",
            panelVisible: panel.isVisible,
            locationSource: lastLocationSource,
            force: true
        )
        updateStatusMenu(force: true)
    }

    private func updateExpandedPanelSize() {
        let nextSize = panelSizeForTaskRows(
            quotaView.taskProgress.rowCount,
            showsMarketPrices: showsMarketPrices,
            showsStockPrices: showsStockPrices,
            stockRowCount: enabledStockQuoteConfigurations.count
        )
        guard nextSize != currentExpandedPanelSize else { return }
        currentExpandedPanelSize = nextSize
        guard panel != nil else { return }
        if !quotaView.isCollapsed {
            panel.setContentSize(nextSize)
        }
    }

    @objc private func resetFollowPositionFromMenu(_ sender: Any?) {
        locator.reset()
        UserDefaults.standard.removeObject(
            forKey: standalonePanelOriginPreferenceKey
        )
        isPanelHiddenByUser = false
        isStandalonePanelActive = false
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

    @objc private func reloadConfigFromMenu(_ sender: Any?) {
        let previousUsageProvider = panelConfig.usageProvider

        do {
            let reloadedConfig = try reloadPanelConfig()
            quotaRefreshGeneration += 1
            stockRefreshGeneration += 1
            isRefreshing = false
            isRefreshingStockPrices = false
            pendingStockRequestCount = 0
            cancelStockRequests()
            quotaProvider = makeQuotaUsageProvider(
                configuration: reloadedConfig.usageProvider
            )
            quotaView.reloadPanelConfiguration()
            quotaView.quotaSourceName = quotaProvider.sourceDisplayName
            applyStockConfiguration(loadCache: true)

            if previousUsageProvider != reloadedConfig.usageProvider {
                quotaView.quotaPresentation = nil
                quotaView.errorText = nil
                lastQuotaUpdatedAt = nil
                codexConnectionStatus = "disconnected"
                quotaView.connectionText = "连接中"
            }

            let marketPricesEnabled = resolvedMarketPricesEnabled(
                storedValue: UserDefaults.standard.object(
                    forKey: marketPricesPreferenceKey
                ) as? Bool,
                configuredDefault: configuredMarketPricesEnabled(
                    for: reloadedConfig
                )
            )
            setMarketPricesEnabled(
                marketPricesEnabled,
                persistPreference: false
            )
            let stockPricesEnabled = resolvedMarketPricesEnabled(
                storedValue: UserDefaults.standard.object(
                    forKey: stockPricesPreferenceKey
                ) as? Bool,
                configuredDefault: configuredStockPricesEnabled(
                    for: reloadedConfig
                )
            )
            setStockPricesEnabled(
                stockPricesEnabled,
                persistPreference: false
            )
            restartConfigurableTimers()
            locator.reset()
            refreshQuota()
            if !isPanelHiddenByUser {
                followPet()
            }
            updateStatusMenu(force: true)
        } catch {
            fputs(
                "panel-config: 重新加载失败，继续使用当前配置：\(error.localizedDescription)\n",
                stderr
            )
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "无法重新加载配置"
            alert.informativeText = "配置文件没有生效，应用将继续使用当前配置。\n\n\(error.localizedDescription)"
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func quitFromMenu(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    private func followPet() {
        // 这是跟随功能的状态分支：用户隐藏 → 找不到桌宠时独立显示 → 找到后精确跟随。
        guard !isPanelHiddenByUser else {
            isStandalonePanelActive = false
            quotaView.allowsWindowDragging = false
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

        let pet = isCodexDesktopRunning() ? locator.locate() : nil
        guard let pet else {
            showStandalonePanel()
            quotaView.followStatusText = "固定显示"
            followHealthStatus = "screen-fallback"
            lastLocationSource = "screen-fallback"
            writeHealth(
                status: "fallback-visible",
                panelVisible: true,
                locationSource: "screen-fallback"
            )
            updateStatusMenu()
            return
        }

        isStandalonePanelActive = false
        quotaView.allowsWindowDragging = false
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

    private func isCodexDesktopRunning() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        guard now >= nextCodexDesktopCheckAt else {
            return cachedCodexDesktopRunning
        }
        nextCodexDesktopCheckAt = now + 1
        cachedCodexDesktopRunning = NSWorkspace.shared.runningApplications.contains { application in
            let name = application.localizedName?.lowercased() ?? ""
            let bundleID = application.bundleIdentifier?.lowercased() ?? ""
            return name == "codex"
                || name == "chatgpt"
                || bundleID.contains("openai.codex")
                || bundleID.contains("openai.chat")
        }
        return cachedCodexDesktopRunning
    }

    private func showStandalonePanel() {
        let wasAlreadyStandalone = isStandalonePanelActive
        let screens = NSScreen.screens
        let preferredScreen = preferredStandaloneScreen(from: screens)
        let currentPanelSize = quotaView.isCollapsed
            ? collapsedPanelSize
            : currentExpandedPanelSize
        let savedOrigin = wasAlreadyStandalone
            ? panel.frame.origin
            : storedStandalonePanelOrigin()
        guard let origin = standalonePanelOrigin(
            savedOrigin: savedOrigin,
            panelSize: currentPanelSize,
            screenVisibleFrames: screens.map(\.visibleFrame),
            preferredScreenVisibleFrame: preferredScreen?.visibleFrame
        ) else { return }

        isStandalonePanelActive = true
        quotaView.allowsWindowDragging = true
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

    private func preferredStandaloneScreen(from screens: [NSScreen]) -> NSScreen? {
        if panel.isVisible,
           let currentScreen = screens.max(by: {
               visibleArea(of: panel.frame, on: $0)
                   < visibleArea(of: panel.frame, on: $1)
           }),
           visibleArea(of: panel.frame, on: currentScreen) > 0
        {
            return currentScreen
        }
        return screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? screens.first
    }

    private func visibleArea(of rect: NSRect, on screen: NSScreen) -> CGFloat {
        let intersection = screen.visibleFrame.intersection(rect)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private func storedStandalonePanelOrigin() -> NSPoint? {
        guard let rawValue = UserDefaults.standard.string(
            forKey: standalonePanelOriginPreferenceKey
        ) else { return nil }
        let origin = NSPointFromString(rawValue)
        guard origin.x.isFinite, origin.y.isFinite else { return nil }
        return origin
    }

    private func saveStandalonePanelOrigin() {
        guard isStandalonePanelActive else { return }
        UserDefaults.standard.set(
            NSStringFromPoint(panel.frame.origin),
            forKey: standalonePanelOriginPreferenceKey
        )
    }

    private func refreshQuota() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let refreshGeneration = quotaRefreshGeneration
        let provider = quotaProvider
        if quotaView.quotaPresentation == nil {
            quotaView.errorText = nil
            quotaView.statusText = "正在读取额度…"
        } else {
            quotaView.statusText = "正在更新…"
        }
        updateStatusMenu()

        // 客户端在后台队列回调；先准备错误文案，再切回主线程修改 AppKit 界面。
        provider.fetch { [weak self] result in
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
                guard let self,
                      self.quotaRefreshGeneration == refreshGeneration
                else { return }
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
                    showsMarketPrices: self.showsMarketPrices,
                    showsStockPrices: self.showsStockPrices,
                    stockRowCount: enabledStockQuoteConfigurations.count
                )
                guard nextSize != self.currentExpandedPanelSize else {
                    return
                }

                self.currentExpandedPanelSize = nextSize
                if !self.quotaView.isCollapsed {
                    self.panel.setContentSize(nextSize)
                }
                if !self.isPanelHiddenByUser {
                    self.followPet()
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
            stockPricesEnabled: showsStockPrices,
            stockMarketState: stockMarketState.rawValue,
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
                    self.quotaView.btcStatusText = Self.intervalText(
                        cryptoRefreshInterval
                    )
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
                    self.quotaView.ethStatusText = Self.intervalText(
                        cryptoRefreshInterval
                    )
                case .failure:
                    self.quotaView.ethStatusText = self.quotaView.ethPrice == nil ? "重试中" : "暂离线"
                }
            }
        }
    }

    private func applyStockConfiguration(loadCache: Bool) {
        let configurations = enabledStockQuoteConfigurations
        let allowedSecIDs = Set(configurations.map(\.secid))
        stockQuotesBySecID = stockQuotesBySecID.filter {
            allowedSecIDs.contains($0.key)
        }
        stockCachedSecIDs.formIntersection(allowedSecIDs)
        stockOfflineSecIDs.formIntersection(allowedSecIDs)

        if loadCache,
           let snapshot = stockQuoteCache.load(allowedSecIDs: allowedSecIDs)
        {
            for quote in snapshot.quotes where stockQuotesBySecID[quote.secid] == nil {
                stockQuotesBySecID[quote.secid] = quote
                stockCachedSecIDs.insert(quote.secid)
            }
            if !snapshot.quotes.isEmpty {
                lastStockCacheWriteAt = snapshot.savedAt
                lastStockUpdatedAt = snapshot.savedAt
                stockMarketState = .cached
            }
        }

        if configurations.isEmpty {
            stockMarketState = .unconfigured
        } else if stockQuotesBySecID.isEmpty {
            stockMarketState = .loading
        }
        stockActivityTracker.reset(signature: stockActivitySignature(
            configurations: configurations
        ))
        updateStockPresentations()
        updateExpandedPanelSize()
    }

    private func updateStockPresentations() {
        quotaView.stockQuotePresentations = enabledStockQuoteConfigurations.map {
            StockQuotePresentation(
                configuration: $0,
                quote: stockQuotesBySecID[$0.secid],
                isCached: stockCachedSecIDs.contains($0.secid),
                isOffline: stockOfflineSecIDs.contains($0.secid)
            )
        }
        quotaView.stockMarketState = stockMarketState
        quotaView.stockUpdatedText = lastStockUpdatedAt.map(
            Self.stockShortTimeFormatter.string
        ) ?? "--"
    }

    private func refreshStockPrices() {
        guard showsStockPrices, !isRefreshingStockPrices else { return }
        let configurations = enabledStockQuoteConfigurations
        guard !configurations.isEmpty else {
            stockMarketState = .unconfigured
            updateStockPresentations()
            updateStatusMenu()
            return
        }

        isRefreshingStockPrices = true
        let generation = stockRefreshGeneration
        let period = stockSessionPeriod(at: Date())
        if !period.expectsTrading {
            stockMarketState = period.displayState
        } else if stockMarketState != .trading && stockMarketState != .stale {
            stockMarketState = .verifying
        }
        pendingStockRequestCount = configurations.count
        stockBatchSuccessCount = 0
        stockBatchHadMarketChange = false
        updateStockPresentations()

        for configuration in configurations {
            let task = stockMarketClient.fetch(secid: configuration.secid) {
                [weak self] result in
                DispatchQueue.main.async {
                    guard let self,
                          self.stockRefreshGeneration == generation,
                          self.showsStockPrices
                    else { return }

                    self.pendingStockRequestCount -= 1
                    switch result {
                    case .success(let quote):
                        self.stockBatchSuccessCount += 1
                        if let previous = self.stockQuotesBySecID[quote.secid] {
                            if !quote.hasSameMarketValues(as: previous) {
                                self.stockBatchHadMarketChange = true
                            }
                        } else {
                            self.stockBatchHadMarketChange = true
                        }
                        self.stockQuotesBySecID[quote.secid] = quote
                        self.stockCachedSecIDs.remove(quote.secid)
                        self.stockOfflineSecIDs.remove(quote.secid)
                        if self.lastStockUpdatedAt == nil
                            || quote.fetchedAt > self.lastStockUpdatedAt!
                        {
                            self.lastStockUpdatedAt = quote.fetchedAt
                        }
                    case .failure(let error):
                        self.stockOfflineSecIDs.insert(configuration.secid)
                        fputs(
                            "stock-market: \(error.localizedDescription)\n",
                            stderr
                        )
                    }

                    if self.pendingStockRequestCount == 0 {
                        self.finishStockRefresh(
                            period: period,
                            expectedCount: configurations.count
                        )
                    } else {
                        self.updateStockPresentations()
                    }
                }
            }
            if let task {
                stockRequestTasks.append(task)
            }
        }
    }

    private func finishStockRefresh(
        period: StockSessionPeriod,
        expectedCount: Int
    ) {
        isRefreshingStockPrices = false
        stockRequestTasks.removeAll()
        let now = Date()

        if stockBatchSuccessCount == 0 {
            stockMarketState = .offline
        } else if !period.expectsTrading {
            stockMarketState = period.displayState
            stockActivityTracker.reset(
                signature: stockActivitySignature(
                    configurations: enabledStockQuoteConfigurations
                ) ?? stockActivityTracker.lastSignature
            )
        } else if stockBatchSuccessCount < expectedCount {
            stockMarketState = stockActivityTracker.hasObservedActivity
                ? .trading : .verifying
        } else if let signature = stockActivitySignature(
            configurations: enabledStockQuoteConfigurations
        ) {
            stockMarketState = stockActivityTracker.observe(
                signature: signature,
                at: now
            )
        }

        if stockBatchHadMarketChange {
            markStockCacheDirty()
        }
        updateStockPresentations()
        updateStatusMenu(force: true)
        writeHealth(
            status: "stock-market-\(stockMarketState.rawValue)",
            panelVisible: panel.isVisible,
            locationSource: lastLocationSource
        )
        scheduleNextStockRefresh()
    }

    private func stockActivitySignature(
        configurations: [StockQuoteConfiguration]
    ) -> String? {
        let signatures = configurations.compactMap {
            stockQuotesBySecID[$0.secid]?.activitySignature
        }
        guard signatures.count == configurations.count,
              !signatures.isEmpty
        else { return nil }
        return signatures.joined(separator: "||")
    }

    private func cancelStockRequests() {
        stockRequestTasks.forEach { $0.cancel() }
        stockRequestTasks.removeAll()
    }

    private func scheduleNextStockRefresh() {
        stockRefreshTimer?.invalidate()
        stockRefreshTimer = nil
        guard showsStockPrices,
              !enabledStockQuoteConfigurations.isEmpty
        else { return }

        let now = Date()
        var interval = stockMarketState.usesClosedRefreshInterval
            ? stockClosedRefreshInterval
            : stockRefreshInterval
        if let boundary = nextStockSessionBoundary(after: now) {
            interval = min(interval, max(1, boundary.timeIntervalSince(now)))
        }
        stockRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: false
        ) { [weak self] _ in
            self?.stockRefreshTimer = nil
            self?.refreshStockPrices()
        }
    }

    private func markStockCacheDirty() {
        stockCacheDirty = true
        scheduleStockCacheWriteIfNeeded()
    }

    private func scheduleStockCacheWriteIfNeeded() {
        guard stockCacheDirty, stockCacheWriteTimer == nil else { return }
        guard let lastStockCacheWriteAt else {
            flushStockCache()
            return
        }
        let remaining = stockCacheWriteInterval
            - Date().timeIntervalSince(lastStockCacheWriteAt)
        if remaining <= 0 {
            flushStockCache()
            return
        }
        stockCacheWriteTimer = Timer.scheduledTimer(
            withTimeInterval: remaining,
            repeats: false
        ) { [weak self] _ in
            self?.stockCacheWriteTimer = nil
            self?.flushStockCache()
        }
    }

    private func flushStockCache() {
        stockCacheWriteTimer?.invalidate()
        stockCacheWriteTimer = nil
        guard stockCacheDirty else { return }
        let quotes = enabledStockQuoteConfigurations.compactMap {
            stockQuotesBySecID[$0.secid]
        }
        guard !quotes.isEmpty else { return }

        let now = Date()
        do {
            try stockQuoteCache.save(quotes: quotes, savedAt: now)
            stockCacheDirty = false
        } catch {
            fputs(
                "stock-cache: 无法写入：\(error.localizedDescription)\n",
                stderr
            )
        }
        // 成功或失败都从当前时刻重新计时，避免受管目录持续失败时形成写盘循环。
        lastStockCacheWriteAt = now
        if stockCacheDirty {
            scheduleStockCacheWriteIfNeeded()
        }
    }

    private static func intervalText(_ seconds: TimeInterval) -> String {
        if seconds.rounded() == seconds {
            return "\(Int(seconds))秒"
        }
        return String(format: "%.1f秒", seconds)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let stockTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    private static let stockShortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

}
