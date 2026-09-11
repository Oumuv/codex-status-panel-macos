// 面板的 AppKit 自绘视图。
// 数据由 AppDelegate 写入模块内可见属性；属性的 didSet 会触发重绘或同步任务动画层。

import AppKit
import Foundation

func taskProgressRowRect(index: Int, in bodyRect: NSRect) -> NSRect {
    NSRect(
        x: bodyRect.minX + 14,
        y: bodyRect.minY + 93 + CGFloat(index) * taskProgressRowHeight,
        width: bodyRect.width - 28,
        height: taskProgressRowHeight
    )
}

func taskProgressItemIndex(
    at point: NSPoint,
    taskCount: Int,
    in bodyRect: NSRect
) -> Int? {
    guard taskCount > 0 else { return nil }
    return (0..<taskCount).first {
        taskProgressRowRect(index: $0, in: bodyRect).contains(point)
    }
}

final class QuotaPanelView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayerBacking()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayerBacking()
    }

    private func configureLayerBacking() {
        // GIF 角标必须拥有独立绘制层，否则每一帧都会向上触发整个面板重绘。
        wantsLayer = true
        canDrawSubviewsIntoLayer = false
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    // didSet 是属性观察器：属性被赋新值后自动执行，用于通知 AppKit 重新绘制。
    var quotaPresentation: QuotaPresentation? {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var quotaSourceName = "Codex" { didSet { needsDisplay = true } }
    var statusText = "正在读取额度…" { didSet { needsDisplay = true } }
    var connectionText = "连接中" { didSet { needsDisplay = true } }
    // 仅供状态菜单读取，不参与面板绘制；高频跟随更新不能触发重绘。
    var followStatusText = "定位中"
    var hasUsageProviderConfiguration = panelConfig.usageProvider != nil {
        didSet { needsDisplay = true }
    }
    var errorText: String? { didSet { needsDisplay = true } }
    var taskProgress = TaskProgressSnapshot.reading {
        didSet {
            if taskProgress != oldValue {
                needsDisplay = true
                syncRunningTaskBadges()
                window?.invalidateCursorRects(for: self)
            }
        }
    }
    var showsMarketPrices = initialMarketPricesEnabled {
        didSet { needsDisplay = true }
    }
    var showsStockPrices = initialStockPricesEnabled {
        didSet {
            toolTip = showsStockPrices
                ? "A 股数据来源：东方财富。行情可能延迟，数据不构成投资建议。"
                : nil
            needsDisplay = true
        }
    }
    var stockQuotePresentations: [StockQuotePresentation] = [] {
        didSet { needsDisplay = true }
    }
    var stockMarketState: StockMarketDisplayState = .loading {
        didSet { needsDisplay = true }
    }
    var stockUpdatedText = "--" { didSet { needsDisplay = true } }
    var btcPrice: Double? { didSet { needsDisplay = true } }
    var btcPriceDirection = 0 { didSet { needsDisplay = true } }
    var btcStatusText = "读取中…" { didSet { needsDisplay = true } }
    var ethPrice: Double? { didSet { needsDisplay = true } }
    var ethPriceDirection = 0 { didSet { needsDisplay = true } }
    var ethStatusText = "读取中…" { didSet { needsDisplay = true } }
    var pointerSide: PointerSide = .left {
        didSet {
            guard pointerSide != oldValue else { return }
            needsDisplay = true
            syncRunningTaskBadges()
            window?.invalidateCursorRects(for: self)
            window?.invalidateShadow()
        }
    }
    var pointerCenterX: CGFloat? {
        didSet {
            guard pointerCenterX != oldValue else { return }
            needsDisplay = true
            window?.invalidateShadow()
        }
    }
    var isCollapsed = false {
        didSet {
            needsDisplay = true
            syncRunningTaskBadges()
            window?.invalidateCursorRects(for: self)
            window?.invalidateShadow()
        }
    }
    var allowsWindowDragging = false {
        didSet {
            guard allowsWindowDragging != oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }
    var onToggleCollapsed: (() -> Void)?
    var onCycleRateLimit: (() -> Void)?
    var onOpenTask: ((TaskProgressItem) -> Void)?
    var onWindowDragCompleted: (() -> Void)?
    private var hideButtonTrackingArea: NSTrackingArea?
    private var isHideButtonHovered = false
    private var runningTaskBadgeViews: [NSImageView] = []
    private var runningTaskBadgeAnimationsEnabled = false
    // 临时关闭运行任务 GIF 角标，用于排查动画对 CPU 占用的影响。
    private let showsRunningTaskBadgeAnimation = false
    private var windowVisibilityObservers: [NSObjectProtocol] = []

    // lazy 属性第一次使用时才加载资源；重新加载配置时会主动替换该缓存。
    private lazy var backgroundImage: NSImage? = loadBackgroundImage()

    private func loadBackgroundImage() -> NSImage? {
        guard let resourceURL = Bundle.main.resourceURL?
            .appendingPathComponent(panelConfig.theme.backgroundImage)
        else { return nil }
        return NSImage(contentsOf: resourceURL)
    }

    func reloadPanelConfiguration() {
        hasUsageProviderConfiguration = panelConfig.usageProvider != nil
        backgroundImage = loadBackgroundImage()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private lazy var completedTaskIcon: NSImage? = taskIcon(
        named: "task-completed-icon.png"
    )
    private lazy var runningTaskIcon: NSImage? = taskIcon(
        named: "task-running-icon.png"
    )
    private lazy var runningTaskBadgeAnimation: NSImage? = taskIcon(
        named: "task-running-badge.gif"
    )
    private lazy var waitingTaskIcon: NSImage? = taskIcon(
        named: "task-waiting-icon.png"
    )
    private lazy var failedTaskIcon: NSImage? = taskIcon(
        named: "task-failed-icon.png"
    )

    private func taskIcon(named name: String) -> NSImage? {
        guard let resourceURL = Bundle.main.resourceURL?
            .appendingPathComponent(name)
        else { return nil }
        return NSImage(contentsOf: resourceURL)
    }

    // AppKit 默认原点在左下；翻转后原点位于左上，更符合从上到下排列内容的习惯。
    override var isFlipped: Bool { true }

    deinit {
        runningTaskBadgeViews.forEach { $0.animates = false }
        windowVisibilityObservers.forEach {
            NotificationCenter.default.removeObserver($0)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 视图可能换到另一个窗口，先移除旧观察者，避免重复回调或持有旧窗口。
        windowVisibilityObservers.forEach {
            NotificationCenter.default.removeObserver($0)
        }
        windowVisibilityObservers.removeAll()
        if let window {
            let center = NotificationCenter.default
            windowVisibilityObservers.append(center.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                // weak 防止 NotificationCenter 的闭包与视图互相强引用。
                self?.updateRunningTaskBadgeAnimationState()
            })
        }
        syncRunningTaskBadges()
    }

    func setRunningTaskBadgeAnimationsEnabled(_ enabled: Bool) {
        guard runningTaskBadgeAnimationsEnabled != enabled else { return }
        runningTaskBadgeAnimationsEnabled = enabled
        updateRunningTaskBadgeAnimationState()
    }

    private func syncRunningTaskBadges() {
        for imageView in runningTaskBadgeViews {
            imageView.animates = false
            imageView.removeFromSuperview()
        }
        runningTaskBadgeViews.removeAll(keepingCapacity: true)

        guard showsRunningTaskBadgeAnimation,
              !isCollapsed,
              window != nil,
              let animation = runningTaskBadgeAnimation
        else { return }

        let bodyRect = panelBodyRect()
        let contentX = bodyRect.minX + 14
        let taskItems = taskProgress.items.isEmpty
            ? TaskProgressSnapshot.idle.items
            : taskProgress.items
        for (index, item) in taskItems.enumerated()
            where item.kind == .running
        {
            let rowRect = taskProgressRowRect(index: index, in: bodyRect)
            let iconRect = NSRect(
                x: contentX - 2,
                y: rowRect.minY + 7,
                width: 20,
                height: 15
            )
            let badgeRect = NSRect(
                x: iconRect.minX + 10.6,
                y: iconRect.minY + 0.4,
                width: 8.4,
                height: 8.4
            )
            let imageView = NSImageView(frame: badgeRect)
            imageView.image = animation
            imageView.imageAlignment = .alignCenter
            imageView.imageScaling = .scaleAxesIndependently
            imageView.imageFrameStyle = .none
            imageView.isEditable = false
            imageView.wantsLayer = true
            imageView.canDrawSubviewsIntoLayer = false
            imageView.layerContentsRedrawPolicy = .onSetNeedsDisplay
            imageView.animates = false
            addSubview(imageView)
            runningTaskBadgeViews.append(imageView)
        }

        updateRunningTaskBadgeAnimationState()
    }

    private func updateRunningTaskBadgeAnimationState() {
        let shouldAnimate = shouldAnimateRunningArrow(
            isWindowVisible: runningTaskBadgeAnimationsEnabled
                && window?.isVisible == true,
            isCollapsed: isCollapsed,
            hasRunningTask: !runningTaskBadgeViews.isEmpty
        )
        for imageView in runningTaskBadgeViews
            where imageView.animates != shouldAnimate
        {
            imageView.animates = shouldAnimate
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // NSView 的 draw 是即时绘制入口：状态变化只需设置 needsDisplay，AppKit 会稍后调用这里。
        NSGraphicsContext.current?.imageInterpolation = .high

        let bodyRect = panelBodyRect()

        let background = NSColor(calibratedRed: 0.035, green: 0.045, blue: 0.085, alpha: 0.97)
        let border = NSColor.white.withAlphaComponent(0.22)
        let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 17, yRadius: 17)
        background.setFill()
        bodyPath.fill()

        if !isCollapsed, let backgroundImage {
            NSGraphicsContext.saveGraphicsState()
            bodyPath.addClip()
            drawFiveBallBand(backgroundImage, in: bodyRect)
            NSColor.black.withAlphaComponent(0.08).setFill()
            bodyPath.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        border.setStroke()
        bodyPath.lineWidth = 1
        bodyPath.stroke()

        let arrow = NSBezierPath()
        switch pointerSide {
        case .left:
            let centerY = bodyRect.midY
            arrow.move(to: NSPoint(x: bodyRect.minX + 1, y: centerY - 8))
            arrow.line(to: NSPoint(x: panelVerticalCanvasInset, y: centerY))
            arrow.line(to: NSPoint(x: bodyRect.minX + 1, y: centerY + 8))
        case .right:
            let centerY = bodyRect.midY
            arrow.move(to: NSPoint(x: bodyRect.maxX - 1, y: centerY - 8))
            arrow.line(to: NSPoint(x: bounds.maxX - panelVerticalCanvasInset, y: centerY))
            arrow.line(to: NSPoint(x: bodyRect.maxX - 1, y: centerY + 8))
        case .bottom:
            let requestedCenterX = pointerCenterX ?? bodyRect.midX
            let centerX = min(
                max(requestedCenterX, bodyRect.minX + 12),
                bodyRect.maxX - 12
            )
            arrow.move(to: NSPoint(x: centerX - 8, y: bodyRect.maxY - 1))
            arrow.line(to: NSPoint(x: centerX, y: bounds.maxY - panelVerticalCanvasInset))
            arrow.line(to: NSPoint(x: centerX + 8, y: bodyRect.maxY - 1))
        }
        arrow.close()
        background.setFill()
        arrow.fill()
        border.setStroke()
        arrow.lineWidth = 1
        arrow.stroke()

        if isCollapsed {
            let label = "展开"
            let labelFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
            let labelHeight = (label as NSString).size(withAttributes: [.font: labelFont]).height
            drawText(
                label,
                in: NSRect(
                    x: bodyRect.minX,
                    y: bodyRect.midY - labelHeight / 2,
                    width: bodyRect.width,
                    height: labelHeight
                ),
                font: labelFont,
                color: NSColor.white.withAlphaComponent(0.92),
                alignment: .center
            )
            return
        }

        let contentX = bodyRect.minX + 14
        let contentWidth = bodyRect.width - 28
        let hideButton = hideButtonRect(in: bodyRect)
        let hideButtonPath = NSBezierPath(roundedRect: hideButton, xRadius: 8, yRadius: 8)
        NSColor.white.withAlphaComponent(isHideButtonHovered ? 0.20 : 0.11).setFill()
        hideButtonPath.fill()
        NSColor.white.withAlphaComponent(isHideButtonHovered ? 0.38 : 0.20).setStroke()
        hideButtonPath.lineWidth = 0.75
        hideButtonPath.stroke()
        drawText(
            "折叠",
            in: NSRect(x: hideButton.minX, y: hideButton.minY + 2, width: hideButton.width, height: 15),
            font: .systemFont(ofSize: 9.5, weight: .medium),
            color: NSColor.white.withAlphaComponent(isHideButtonHovered ? 1.0 : 0.86),
            alignment: .center
        )

        if !panelConfig.widgets.codexQuota {
            drawText(
                panelConfig.theme.title,
                in: NSRect(x: contentX, y: bodyRect.minY + 11, width: contentWidth - 48, height: 18),
                font: .systemFont(ofSize: 12.4, weight: .semibold),
                color: NSColor.white.withAlphaComponent(0.88)
            )
        } else if let quotaPresentation {
            draw(
                presentation: quotaPresentation,
                bodyMinY: bodyRect.minY,
                x: contentX,
                width: contentWidth
            )
        } else if !hasUsageProviderConfiguration {
            drawText(
                "暂无用量数据",
                in: NSRect(x: contentX, y: bodyRect.minY + 11, width: contentWidth - 48, height: 18),
                font: .systemFont(ofSize: 12.4, weight: .semibold),
                color: NSColor.white.withAlphaComponent(0.88)
            )
            drawText(
                "配置 usageProvider 后显示额度和 Token",
                in: NSRect(x: contentX, y: bodyRect.minY + 74, width: contentWidth, height: 14),
                font: .systemFont(ofSize: 9.2, weight: .regular),
                color: NSColor.white.withAlphaComponent(0.66)
            )
        } else if let errorText {
            drawText(
                errorText,
                in: NSRect(x: contentX, y: bodyRect.minY + 11, width: contentWidth - 48, height: 38),
                font: .systemFont(ofSize: 12, weight: .medium),
                color: NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.38, alpha: 1)
            )
        } else {
            drawText(
                "正在向 \(quotaSourceName) 查询…",
                in: NSRect(x: contentX, y: bodyRect.minY + 11, width: contentWidth - 48, height: 20),
                font: .systemFont(ofSize: 11.5, weight: .medium),
                color: NSColor.white.withAlphaComponent(0.68)
            )
        }

        let taskItems = taskProgress.items.isEmpty
            ? TaskProgressSnapshot.idle.items
            : taskProgress.items
        for (index, item) in taskItems.enumerated() {
            let rowRect = taskProgressRowRect(index: index, in: bodyRect)
            drawTaskProgressItem(
                item,
                index: index,
                y: rowRect.minY + 7,
                separatorY: rowRect.minY,
                contentX: contentX,
                contentWidth: contentWidth
            )
        }
        let taskSectionHeight = taskProgressRowHeight
            * CGFloat(max(1, taskItems.count))
        var nextMarketY = bodyRect.minY + 100 + taskSectionHeight

        if showsMarketPrices {
            drawMarketPriceRow(
                symbol: "BTC/USDT",
                iconText: "₿",
                iconColor: NSColor(calibratedRed: 0.97, green: 0.58, blue: 0.11, alpha: 1),
                price: btcPrice,
                direction: btcPriceDirection,
                statusText: btcStatusText,
                y: nextMarketY,
                separatorY: bodyRect.minY + 93 + taskSectionHeight,
                contentX: contentX,
                contentWidth: contentWidth
            )
            drawMarketPriceRow(
                symbol: "ETH/USDT",
                iconText: "Ξ",
                iconColor: NSColor(calibratedRed: 0.38, green: 0.45, blue: 0.95, alpha: 1),
                price: ethPrice,
                direction: ethPriceDirection,
                statusText: ethStatusText,
                y: nextMarketY + marketPriceRowHeight,
                separatorY: nextMarketY + marketPriceRowHeight - 7,
                contentX: contentX,
                contentWidth: contentWidth
            )
            nextMarketY += marketPriceRowHeight * 2
        }

        if showsStockPrices {
            drawStockMarketHeader(
                y: nextMarketY,
                separatorY: nextMarketY - 7,
                contentX: contentX,
                contentWidth: contentWidth
            )
            let stockRowY = nextMarketY + stockMarketHeaderHeight
            if stockQuotePresentations.isEmpty {
                drawText(
                    "未配置 A 股行情",
                    in: NSRect(
                        x: contentX,
                        y: stockRowY + 1,
                        width: contentWidth,
                        height: 15
                    ),
                    font: .systemFont(ofSize: 9.5, weight: .medium),
                    color: NSColor.white.withAlphaComponent(0.58)
                )
            } else {
                for (index, presentation) in stockQuotePresentations.enumerated() {
                    drawStockQuoteRow(
                        presentation,
                        y: stockRowY
                            + CGFloat(index) * marketPriceRowHeight,
                        separatorY: stockRowY
                            + CGFloat(index) * marketPriceRowHeight - 7,
                        contentX: contentX,
                        contentWidth: contentWidth
                    )
                }
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hideButtonTrackingArea {
            removeTrackingArea(hideButtonTrackingArea)
        }
        guard !isCollapsed else {
            hideButtonTrackingArea = nil
            return
        }
        let trackingArea = NSTrackingArea(
            rect: hideButtonRect(in: panelBodyRect()),
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hideButtonTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHideButtonHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHideButtonHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let bodyRect = panelBodyRect()
        if !isCollapsed,
           panelConfig.widgets.codexQuota,
           quotaPresentation?.hasSwitchableRateLimits == true,
           quotaValueRect(in: bodyRect).contains(point)
        {
            onCycleRateLimit?()
            return
        }
        if !isCollapsed, hideButtonRect(in: bodyRect).contains(point) {
            onToggleCollapsed?()
            return
        }
        if !isCollapsed,
           let index = taskProgressItemIndex(
               at: point,
               taskCount: taskProgress.items.count,
               in: bodyRect
           ),
           taskProgress.items[index].target != nil
        {
            onOpenTask?(taskProgress.items[index])
            return
        }

        guard allowsWindowDragging, let window else {
            if isCollapsed {
                onToggleCollapsed?()
                return
            }
            super.mouseDown(with: event)
            return
        }

        let initialOrigin = window.frame.origin
        window.performDrag(with: event)
        if window.frame.origin != initialOrigin {
            onWindowDragCompleted?()
        } else if isCollapsed {
            onToggleCollapsed?()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isCollapsed {
            addCursorRect(
                bounds,
                cursor: allowsWindowDragging ? .openHand : .pointingHand
            )
            return
        }
        if allowsWindowDragging {
            addCursorRect(bounds, cursor: .openHand)
        }
        let bodyRect = panelBodyRect()
        addCursorRect(
            hideButtonRect(in: bodyRect),
            cursor: .pointingHand
        )
        if panelConfig.widgets.codexQuota,
           quotaPresentation?.hasSwitchableRateLimits == true
        {
            addCursorRect(
                quotaValueRect(in: bodyRect),
                cursor: .pointingHand
            )
        }
        for (index, item) in taskProgress.items.enumerated()
            where item.target != nil
        {
            addCursorRect(
                taskProgressRowRect(index: index, in: bodyRect),
                cursor: .pointingHand
            )
        }
    }

    private func panelBodyRect() -> NSRect {
        switch pointerSide {
        case .left:
            let x = panelVerticalCanvasInset + panelPointerLength - 1
            return NSRect(
                x: x,
                y: panelVerticalCanvasInset,
                width: bounds.width - x - panelHorizontalCanvasInset,
                height: bounds.height - panelVerticalCanvasInset * 2
            )
        case .right:
            return NSRect(
                x: panelHorizontalCanvasInset,
                y: panelVerticalCanvasInset,
                width: bounds.width - panelHorizontalCanvasInset - panelVerticalCanvasInset - panelPointerLength + 1,
                height: bounds.height - panelVerticalCanvasInset * 2
            )
        case .bottom:
            return NSRect(
                x: panelHorizontalCanvasInset,
                y: panelVerticalCanvasInset,
                width: bounds.width - panelHorizontalCanvasInset * 2,
                height: bounds.height - panelVerticalCanvasInset * 2 - panelPointerLength + 1
            )
        }
    }

    private func hideButtonRect(in bodyRect: NSRect) -> NSRect {
        NSRect(x: bodyRect.maxX - 48, y: bodyRect.minY + 7, width: 38, height: 18)
    }

    private func quotaValueRect(in bodyRect: NSRect) -> NSRect {
        let contentX = bodyRect.minX + 14
        let contentWidth = bodyRect.width - 28
        return quotaValueRect(
            bodyMinY: bodyRect.minY,
            x: contentX,
            width: contentWidth
        )
    }

    private func quotaValueRect(
        bodyMinY: CGFloat,
        x: CGFloat,
        width: CGFloat
    ) -> NSRect {
        let valueStart = x + 56
        let valueRight = x + width - 48
        return NSRect(
            x: valueStart,
            y: bodyMinY + 10,
            width: max(0, valueRight - valueStart),
            height: 16
        )
    }

    private func draw(
        presentation: QuotaPresentation,
        bodyMinY: CGFloat,
        x: CGFloat,
        width: CGFloat
    ) {
        let top = bodyMinY + 10
        let valueRect = quotaValueRect(
            bodyMinY: bodyMinY,
            x: x,
            width: width
        )

        drawText(
            presentation.sourceName,
            in: NSRect(x: x, y: top, width: 52, height: 16),
            font: .systemFont(ofSize: 10.8, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.88)
        )
        let topValueText: String?
        if presentation.showsInlineUsageMetrics {
            topValueText = presentation.progressPercent.map {
                let percent = max(0, min(100, $0))
                if let option = presentation.selectedRateLimitOption {
                    return "\(option.compactDisplayName)·剩余\(percent)%"
                }
                return "剩余 \(percent)%"
            }
        } else {
            topValueText = presentation.valueText
        }
        if let topValueText {
            drawText(
                topValueText,
                in: valueRect,
                font: .monospacedDigitSystemFont(ofSize: 10.8, weight: .semibold),
                color: quotaValueColor(for: presentation),
                alignment: .right
            )
        }

        if let rawPercent = presentation.progressPercent {
            let percent = max(0, min(100, rawPercent))
            let trackRect = NSRect(
                x: x,
                y: top + 55,
                width: width,
                height: 4
            )
            let track = NSBezierPath(
                roundedRect: trackRect,
                xRadius: 2,
                yRadius: 2
            )
            NSColor.black.withAlphaComponent(0.30).setFill()
            track.fill()

            let fillWidth = percent == 0
                ? 0 : max(3, width * CGFloat(percent) / 100)
            if fillWidth > 0 {
                let fill = NSBezierPath(
                    roundedRect: NSRect(
                        x: x,
                        y: top + 55,
                        width: fillWidth,
                        height: 4
                    ),
                    xRadius: 2,
                    yRadius: 2
                )
                progressColor(for: percent).setFill()
                fill.fill()
            }
        }

        if presentation.showsInlineUsageMetrics {
            drawInlineUsageMetrics(
                presentation,
                in: NSRect(x: x, y: top + 64, width: width, height: 14)
            )
        } else {
            let dailyTokenWidth = presentation.dailyTokenText == nil
                ? 0 : min(92, width * 0.46)
            let detailWidth = dailyTokenWidth == 0
                ? width : max(0, width - dailyTokenWidth - 8)
            drawText(
                presentation.detailText,
                in: NSRect(x: x, y: top + 64, width: detailWidth, height: 14),
                font: .systemFont(ofSize: 9.2, weight: .regular),
                color: NSColor.white.withAlphaComponent(0.72)
            )
            if let dailyTokenText = presentation.dailyTokenText {
                drawMetricText(
                    dailyTokenText,
                    in: NSRect(
                        x: x + width - dailyTokenWidth,
                        y: top + 64,
                        width: dailyTokenWidth,
                        height: 14
                    ),
                    valueColor: NSColor(
                        calibratedRed: 1.0,
                        green: 0.34,
                        blue: 0.39,
                        alpha: 1
                    ),
                    alignment: .right,
                    fontSize: 9.2
                )
            }
        }
    }

    private func drawInlineUsageMetrics(
        _ presentation: QuotaPresentation,
        in rect: NSRect
    ) {
        let gap: CGFloat = 3
        let tokenWidth = floor((rect.width - gap * 2) * 0.30)
        let usedWidth = floor((rect.width - gap * 2) * 0.38)
        let remainingWidth = rect.width - gap * 2 - tokenWidth - usedWidth
        let tokenText = (presentation.dailyTokenText ?? "今日Token --")
            .replacingOccurrences(of: "今日Token ", with: "Token ")
        let usedText = presentation.detailText.isEmpty
            ? "今日已用 --" : presentation.detailText

        drawMetricText(
            tokenText,
            in: NSRect(
                x: rect.minX,
                y: rect.minY,
                width: tokenWidth,
                height: rect.height
            ),
            valueColor: NSColor(
                calibratedRed: 1.0,
                green: 0.34,
                blue: 0.39,
                alpha: 1
            ),
            alignment: .left,
            fontSize: 8.2
        )
        drawMetricText(
            usedText,
            in: NSRect(
                x: rect.minX + tokenWidth + gap,
                y: rect.minY,
                width: usedWidth,
                height: rect.height
            ),
            valueColor: NSColor(
                calibratedRed: 1.0,
                green: 0.63,
                blue: 0.20,
                alpha: 1
            ),
            alignment: .center,
            fontSize: 8.2
        )
        drawMetricText(
            presentation.valueText,
            in: NSRect(
                x: rect.maxX - remainingWidth,
                y: rect.minY,
                width: remainingWidth,
                height: rect.height
            ),
            valueColor: NSColor(
                calibratedRed: 0.24,
                green: 0.86,
                blue: 0.58,
                alpha: 1
            ),
            alignment: .right,
            fontSize: 8.2
        )
    }

    private func drawMetricText(
        _ text: String,
        in rect: NSRect,
        valueColor: NSColor,
        alignment: NSTextAlignment,
        fontSize: CGFloat
    ) {
        let separator = " "
        guard let separatorRange = text.range(of: separator) else {
            drawText(
                text,
                in: rect,
                font: .systemFont(ofSize: fontSize, weight: .semibold),
                color: valueColor,
                alignment: alignment
            )
            return
        }

        let label = String(text[..<separatorRange.lowerBound])
        let value = String(text[separatorRange.upperBound...])
        let labelFont = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
        let labelWidth = ceil((label as NSString).size(withAttributes: [.font: labelFont]).width)
        let valueWidth = ceil((value as NSString).size(withAttributes: [.font: valueFont]).width)
        let spacing: CGFloat = 2
        let contentWidth = labelWidth + spacing + valueWidth
        let startX: CGFloat
        switch alignment {
        case .right:
            startX = max(rect.minX, rect.maxX - contentWidth)
        case .center:
            startX = max(rect.minX, rect.midX - contentWidth / 2)
        default:
            startX = rect.minX
        }

        drawText(
            label,
            in: NSRect(x: startX, y: rect.minY, width: labelWidth, height: rect.height),
            font: labelFont,
            color: NSColor.white.withAlphaComponent(0.96)
        )
        drawText(
            value,
            in: NSRect(
                x: startX + labelWidth + spacing,
                y: rect.minY,
                width: valueWidth,
                height: rect.height
            ),
            font: valueFont,
            color: valueColor
        )
    }

    private func quotaValueColor(
        for presentation: QuotaPresentation
    ) -> NSColor {
        quotaColor(for: quotaDisplayTone(for: presentation))
    }

    private func quotaColor(for tone: QuotaDisplayTone) -> NSColor {
        switch tone {
        case .danger:
            return NSColor(
                calibratedRed: 1.0,
                green: 0.34,
                blue: 0.39,
                alpha: 1
            )
        case .warning:
            return NSColor(
                calibratedRed: 1.0,
                green: 0.70,
                blue: 0.22,
                alpha: 1
            )
        case .normal:
            return NSColor(
                calibratedRed: 0.22,
                green: 0.60,
                blue: 1.0,
                alpha: 1
            )
        }
    }

    private func drawFiveBallBand(_ image: NSImage, in destinationRect: NSRect) {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }

        // 原图是竖版海报；中间 32% 只包含黑底五颗角色球，两条 MAYDAY 文字在裁剪区外。
        // 这个裁剪比例也更接近额度面板的横向尺寸。
        let sourceRect = NSRect(
            x: 0,
            y: imageSize.height * 0.34,
            width: imageSize.width,
            height: imageSize.height * 0.32
        )

        let imageRect = NSRect(
            x: destinationRect.minX,
            y: destinationRect.minY,
            width: destinationRect.width,
            height: min(93, destinationRect.height)
        )

        image.draw(
            in: imageRect,
            from: sourceRect,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    private func drawTaskProgressItem(
        _ item: TaskProgressItem,
        index: Int,
        y: CGFloat,
        separatorY: CGFloat,
        contentX: CGFloat,
        contentWidth: CGFloat
    ) {
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: contentX, y: separatorY))
        separator.line(to: NSPoint(
            x: contentX + contentWidth,
            y: separatorY
        ))
        NSColor.white.withAlphaComponent(0.13).setStroke()
        separator.lineWidth = 0.75
        separator.stroke()

        let color = taskProgressColor(for: item.kind)
        let taskIcon: NSImage?
        switch item.kind {
        case .running:
            taskIcon = runningTaskIcon
        case .waitingForInput:
            taskIcon = waitingTaskIcon
        case .completed:
            taskIcon = completedTaskIcon
        case .failed:
            taskIcon = failedTaskIcon
        case .reading, .idle:
            taskIcon = nil
        }

        let usesStatusIcon = taskIcon != nil
        if let taskIcon {
            let iconRect = NSRect(
                x: contentX - 2,
                y: y,
                width: 20,
                height: 15
            )
            taskIcon.draw(
                in: iconRect,
                from: NSRect(origin: .zero, size: taskIcon.size),
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            drawTaskStatusBadge(for: item.kind, iconRect: iconRect)
        } else {
            let dot = NSBezierPath(ovalIn: NSRect(
                x: contentX,
                y: y + 4,
                width: 7,
                height: 7
            ))
            color.setFill()
            dot.fill()
        }

        let titleOffset: CGFloat = usesStatusIcon ? 22 : 13
        let titleReservedWidth: CGFloat = usesStatusIcon ? 89 : 80
        drawText(
            item.title,
            in: NSRect(
                x: contentX + titleOffset,
                y: y,
                width: contentWidth - titleReservedWidth,
                height: 15
            ),
            font: .systemFont(
                ofSize: 9.4,
                weight: index == 0 ? .semibold : .medium
            ),
            color: NSColor.white.withAlphaComponent(0.84)
        )
        drawText(
            item.statusText,
            in: NSRect(
                x: contentX + contentWidth - 66,
                y: y,
                width: 66,
                height: 15
            ),
            font: .systemFont(ofSize: 9.2, weight: .semibold),
            color: color,
            alignment: .right
        )
    }

    private func drawTaskStatusBadge(
        for kind: TaskProgressKind,
        iconRect: NSRect
    ) {
        guard kind != .completed && kind != .failed else { return }

        let badgeRect = NSRect(
            x: iconRect.minX + 10.6,
            y: iconRect.minY + 0.4,
            width: 8.4,
            height: 8.4
        )
        let badge = NSBezierPath(ovalIn: badgeRect)
        switch kind {
        case .running:
            // GIF 子视图只刷新角标；静态帧用于预览和资源加载失败回退。
            NSColor(
                calibratedRed: 0.12,
                green: 0.46,
                blue: 0.96,
                alpha: 1
            ).setFill()
            badge.fill()
            drawStaticRunningArrow(in: badgeRect)
        case .waitingForInput:
            NSColor(
                calibratedRed: 1.0,
                green: 0.76,
                blue: 0.10,
                alpha: 1
            ).setFill()
            badge.fill()
            drawText(
                "?",
                in: badgeRect.offsetBy(dx: 0, dy: -0.4),
                font: .systemFont(ofSize: 7.2, weight: .heavy),
                color: .white,
                alignment: .center
            )
        case .reading, .completed, .failed, .idle:
            break
        }
    }

    private func drawStaticRunningArrow(in badgeRect: NSRect) {
        let center = NSPoint(x: badgeRect.midX, y: badgeRect.midY)
        let radius = badgeRect.width * 0.31
        let rotation: CGFloat = 0
        let start: CGFloat = rotation - .pi * 0.40
        let sweep: CGFloat = .pi * 1.56
        let segments = 18
        let arc = NSBezierPath()
        for index in 0...segments {
            let angle = start + sweep * CGFloat(index) / CGFloat(segments)
            let point = NSPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            if index == 0 {
                arc.move(to: point)
            } else {
                arc.line(to: point)
            }
        }
        NSColor.white.setStroke()
        arc.lineWidth = 1.05
        arc.lineCapStyle = .round
        arc.stroke()

        let end = start + sweep
        let tip = NSPoint(
            x: center.x + cos(end) * radius,
            y: center.y + sin(end) * radius
        )
        let tangent = NSPoint(x: -sin(end), y: cos(end))
        let normal = NSPoint(x: -tangent.y, y: tangent.x)
        let base = NSPoint(
            x: tip.x - tangent.x * 1.6,
            y: tip.y - tangent.y * 1.6
        )
        let head = NSBezierPath()
        head.move(to: tip)
        head.line(to: NSPoint(
            x: base.x + normal.x * 0.72,
            y: base.y + normal.y * 0.72
        ))
        head.line(to: NSPoint(
            x: base.x - normal.x * 0.72,
            y: base.y - normal.y * 0.72
        ))
        head.close()
        NSColor.white.setFill()
        head.fill()
    }

    private func drawMarketPriceRow(
        symbol: String,
        iconText: String,
        iconColor: NSColor,
        price: Double?,
        direction: Int,
        statusText: String,
        y: CGFloat,
        separatorY: CGFloat,
        contentX: CGFloat,
        contentWidth: CGFloat
    ) {
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: contentX, y: separatorY))
        separator.line(to: NSPoint(x: contentX + contentWidth, y: separatorY))
        NSColor.white.withAlphaComponent(0.13).setStroke()
        separator.lineWidth = 0.75
        separator.stroke()

        let iconRect = NSRect(x: contentX, y: y, width: 15, height: 15)
        let icon = NSBezierPath(ovalIn: iconRect)
        iconColor.setFill()
        icon.fill()
        drawText(
            iconText,
            in: NSRect(x: iconRect.minX, y: iconRect.minY + 0.5, width: iconRect.width, height: 14),
            font: .systemFont(ofSize: 10.2, weight: .bold),
            color: .white,
            alignment: .center
        )

        drawText(
            symbol,
            in: NSRect(x: contentX + 20, y: y, width: 62, height: 15),
            font: .systemFont(ofSize: 9.6, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.78)
        )

        if let price {
            let formattedPrice = Self.marketPriceFormatter.string(from: NSNumber(value: price)) ?? "--"
            drawText(
                formattedPrice,
                in: NSRect(x: contentX + 78, y: y - 1.5, width: 76, height: 17),
                font: .monospacedDigitSystemFont(ofSize: 11.4, weight: .bold),
                color: marketPriceColor(direction: direction),
                alignment: .right
            )
        } else {
            drawText(
                "--",
                in: NSRect(x: contentX + 78, y: y - 1.5, width: 76, height: 17),
                font: .monospacedDigitSystemFont(ofSize: 11.4, weight: .bold),
                color: NSColor.white.withAlphaComponent(0.70),
                alignment: .right
            )
        }

        drawText(
            statusText,
            in: NSRect(x: contentX + 158, y: y + 1, width: contentWidth - 158, height: 14),
            font: .systemFont(ofSize: 8.3, weight: .regular),
            color: NSColor.white.withAlphaComponent(0.54),
            alignment: .right
        )
    }

    private func drawStockMarketHeader(
        y: CGFloat,
        separatorY: CGFloat,
        contentX: CGFloat,
        contentWidth: CGFloat
    ) {
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: contentX, y: separatorY))
        separator.line(to: NSPoint(x: contentX + contentWidth, y: separatorY))
        NSColor.white.withAlphaComponent(0.17).setStroke()
        separator.lineWidth = 0.75
        separator.stroke()

        drawText(
            "A股 · 东方财富",
            in: NSRect(x: contentX, y: y + 1, width: 90, height: 14),
            font: .systemFont(ofSize: 8.8, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.70)
        )
        let stateColor = stockMarketStateColor(stockMarketState)
        drawSystemSymbol(
            named: stockMarketState.symbolName,
            in: NSRect(x: contentX + 91, y: y + 1, width: 11, height: 11),
            color: stateColor
        )
        drawText(
            stockMarketState.text,
            in: NSRect(x: contentX + 105, y: y + 1, width: 53, height: 14),
            font: .systemFont(ofSize: 8.2, weight: .medium),
            color: stateColor
        )
        drawText(
            stockUpdatedText,
            in: NSRect(
                x: contentX + 158,
                y: y + 1,
                width: contentWidth - 158,
                height: 14
            ),
            font: .monospacedDigitSystemFont(ofSize: 7.8, weight: .regular),
            color: NSColor.white.withAlphaComponent(0.50),
            alignment: .right
        )
    }

    private func drawStockQuoteRow(
        _ presentation: StockQuotePresentation,
        y: CGFloat,
        separatorY: CGFloat,
        contentX: CGFloat,
        contentWidth: CGFloat
    ) {
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: contentX, y: separatorY))
        separator.line(to: NSPoint(x: contentX + contentWidth, y: separatorY))
        NSColor.white.withAlphaComponent(0.11).setStroke()
        separator.lineWidth = 0.75
        separator.stroke()

        let isDimmed = stockMarketState.dimsQuotes
            || presentation.isCached
            || presentation.isOffline
        let alpha: CGFloat = isDimmed ? 0.68 : 1
        let detailWidth: CGFloat = 43
        let detailX = contentX + contentWidth - detailWidth
        let priceX = contentX + 74
        let priceWidth = max(0, detailX - priceX - 4)
        let iconRect = NSRect(x: contentX, y: y, width: 15, height: 15)
        stockBadgeColor(for: presentation).withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: iconRect).fill()
        drawText(
            presentation.badge,
            in: NSRect(
                x: iconRect.minX,
                y: iconRect.minY + 0.7,
                width: iconRect.width,
                height: 13
            ),
            font: .systemFont(
                ofSize: presentation.badge.count > 1 ? 7.2 : 9.2,
                weight: .bold
            ),
            color: NSColor.white.withAlphaComponent(alpha),
            alignment: .center
        )
        drawText(
            presentation.displayName,
            in: NSRect(x: contentX + 20, y: y, width: 58, height: 15),
            font: .systemFont(ofSize: 9.2, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.80 * alpha)
        )

        if let quote = presentation.quote {
            let formatted = Self.marketPriceFormatter.string(
                from: NSNumber(value: quote.latest)
            ) ?? "--"
            drawText(
                formatted,
                in: NSRect(x: priceX, y: y - 1.5, width: priceWidth, height: 17),
                font: .monospacedDigitSystemFont(ofSize: 10.6, weight: .bold),
                color: marketPriceColor(direction: presentation.direction)
                    .withAlphaComponent(alpha),
                alignment: .right
            )
            let detail = presentation.isOffline
                ? "离线"
                : String(format: "%+.2f%%", quote.changePercent)
            drawText(
                detail,
                in: NSRect(
                    x: detailX,
                    y: y + 1,
                    width: detailWidth,
                    height: 14
                ),
                font: .monospacedDigitSystemFont(ofSize: 8.4, weight: .semibold),
                color: presentation.isOffline
                    ? NSColor.white.withAlphaComponent(0.48)
                    : marketPriceColor(direction: presentation.direction)
                        .withAlphaComponent(alpha),
                alignment: .right
            )
        } else {
            drawText(
                "--",
                in: NSRect(x: priceX, y: y - 1.5, width: priceWidth, height: 17),
                font: .monospacedDigitSystemFont(ofSize: 10.6, weight: .bold),
                color: NSColor.white.withAlphaComponent(0.62),
                alignment: .right
            )
            drawText(
                presentation.isOffline ? "离线" : "读取中",
                in: NSRect(
                    x: detailX,
                    y: y + 1,
                    width: detailWidth,
                    height: 14
                ),
                font: .systemFont(ofSize: 8.2, weight: .regular),
                color: NSColor.white.withAlphaComponent(0.48),
                alignment: .right
            )
        }
    }

    private func drawSystemSymbol(
        named name: String,
        in rect: NSRect,
        color: NSColor
    ) {
        let base = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        let tinted = base.applying(
            NSImage.SymbolConfiguration(hierarchicalColor: color)
        )
        guard let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: stockMarketState.text
        )?.withSymbolConfiguration(tinted) else { return }
        image.draw(in: rect)
    }

    private func stockBadgeColor(
        for presentation: StockQuotePresentation
    ) -> NSColor {
        if presentation.badge == "创" {
            return NSColor(
                calibratedRed: 0.56,
                green: 0.38,
                blue: 0.88,
                alpha: 1
            )
        }
        if presentation.configuration.secid.hasPrefix("1.") {
            return NSColor(
                calibratedRed: 0.84,
                green: 0.36,
                blue: 0.29,
                alpha: 1
            )
        }
        return NSColor(
            calibratedRed: 0.25,
            green: 0.48,
            blue: 0.84,
            alpha: 1
        )
    }

    private func stockMarketStateColor(
        _ state: StockMarketDisplayState
    ) -> NSColor {
        switch state {
        case .trading:
            return NSColor(calibratedRed: 0.20, green: 0.72, blue: 1, alpha: 1)
        case .stale:
            return NSColor(calibratedRed: 1, green: 0.72, blue: 0.20, alpha: 1)
        case .offline:
            return NSColor(calibratedRed: 1, green: 0.55, blue: 0.33, alpha: 1)
        default:
            return NSColor.white.withAlphaComponent(0.58)
        }
    }

    private func taskProgressColor(for kind: TaskProgressKind) -> NSColor {
        switch kind {
        case .reading, .running:
            return NSColor(
                calibratedRed: 0.10,
                green: 0.78,
                blue: 1.0,
                alpha: 1
            )
        case .waitingForInput:
            return NSColor(
                calibratedRed: 1.0,
                green: 0.79,
                blue: 0.18,
                alpha: 1
            )
        case .completed:
            return NSColor(
                calibratedRed: 0.24,
                green: 0.86,
                blue: 0.58,
                alpha: 1
            )
        case .failed:
            return NSColor(
                calibratedRed: 1.0,
                green: 0.39,
                blue: 0.43,
                alpha: 1
            )
        case .idle:
            return NSColor.white.withAlphaComponent(0.54)
        }
    }

    private func marketPriceColor(direction: Int) -> NSColor {
        switch direction {
        case 1:
            return NSColor(calibratedRed: 1.0, green: 0.39, blue: 0.43, alpha: 1)
        case -1:
            return NSColor(calibratedRed: 0.24, green: 0.86, blue: 0.58, alpha: 1)
        default:
            return NSColor.white.withAlphaComponent(0.94)
        }
    }

    private func progressColor(for remaining: Int) -> NSColor {
        quotaColor(for: quotaDisplayTone(remainingPercent: remaining))
    }

    private func drawText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
                .shadow: Self.textShadow,
            ]
        )
    }

    private static let textShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.72)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: 1)
        return shadow
    }()

    private static let marketPriceFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = true
        return formatter
    }()
}
