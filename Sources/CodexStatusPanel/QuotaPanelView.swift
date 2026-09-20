// 面板的 AppKit 自绘视图。
// 数据由 AppDelegate 写入模块内可见属性；属性的 didSet 会触发重绘或同步任务动画层。

import AppKit
import Foundation
import QuartzCore

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

private func taskAttentionColor(for kind: TaskProgressKind) -> NSColor {
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

struct TaskStatusTextEffectProfile: Equatable {
    let ambientScanDuration: CFTimeInterval?
    let ambientActiveFraction: Double
    let entranceScanCount: Float
    let entranceScanDuration: CFTimeInterval
    let usesGlitchEntrance: Bool
    let glowOpacity: Float
}

func taskStatusTextEffectProfile(
    for kind: TaskProgressKind
) -> TaskStatusTextEffectProfile {
    switch kind {
    case .reading:
        return TaskStatusTextEffectProfile(
            ambientScanDuration: nil,
            ambientActiveFraction: 0,
            entranceScanCount: 0,
            entranceScanDuration: 0,
            usesGlitchEntrance: false,
            glowOpacity: 0.18
        )
    case .running:
        return TaskStatusTextEffectProfile(
            ambientScanDuration: 2.4,
            ambientActiveFraction: 0.66,
            entranceScanCount: 0,
            entranceScanDuration: 0,
            usesGlitchEntrance: false,
            glowOpacity: 0.34
        )
    case .waitingForInput:
        return TaskStatusTextEffectProfile(
            ambientScanDuration: 5.6,
            ambientActiveFraction: 0.18,
            entranceScanCount: 3,
            entranceScanDuration: 0.52,
            usesGlitchEntrance: false,
            glowOpacity: 0.62
        )
    case .completed:
        return TaskStatusTextEffectProfile(
            ambientScanDuration: nil,
            ambientActiveFraction: 0,
            entranceScanCount: 1,
            entranceScanDuration: 0.72,
            usesGlitchEntrance: false,
            glowOpacity: 0.42
        )
    case .failed:
        return TaskStatusTextEffectProfile(
            ambientScanDuration: 6.2,
            ambientActiveFraction: 0.16,
            entranceScanCount: 1,
            entranceScanDuration: 0.46,
            usesGlitchEntrance: true,
            glowOpacity: 0.68
        )
    case .idle:
        return TaskStatusTextEffectProfile(
            ambientScanDuration: nil,
            ambientActiveFraction: 0,
            entranceScanCount: 0,
            entranceScanDuration: 0,
            usesGlitchEntrance: false,
            glowOpacity: 0
        )
    }
}

struct TaskCompletionCelebrationProfile: Equatable {
    let ringCount: Int
    let particleCount: Int
    let totalDuration: CFTimeInterval
    let cycleDuration: CFTimeInterval
    let cycleCount: Int
    let waveStagger: CFTimeInterval
    let waveTravelsFromCompletedBall: Bool
    let repeats: Bool
    let clipsToBallBand: Bool
}

let taskCompletionCelebrationProfile = TaskCompletionCelebrationProfile(
    ringCount: 2,
    particleCount: 14,
    totalDuration: 10,
    cycleDuration: 2,
    cycleCount: 5,
    waveStagger: 0.065,
    waveTravelsFromCompletedBall: true,
    repeats: true,
    clipsToBallBand: false
)

let taskCompletionWaveOrder: [TaskProgressKind] = [
    .completed,
    .waitingForInput,
    .reading,
    .running,
    .failed,
]

private final class TaskAttentionRowView: NSView {
    private let statusTextLayer = CATextLayer()
    private let ambientScanLayer = CAGradientLayer()
    private let eventScanLayer = CAGradientLayer()
    private let ambientScanMaskLayer = CATextLayer()
    private let eventScanMaskLayer = CATextLayer()
    private let cyanGlitchLayer = CATextLayer()
    private let magentaGlitchLayer = CATextLayer()
    private var displayedKind: TaskProgressKind?
    private var displayedText: String?
    private var animationsEnabled = false

    private static let statusFont = NSFont.systemFont(ofSize: 9.2, weight: .semibold)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayers()
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        let statusFrame = CGRect(
            x: max(0, bounds.width - 66),
            y: 7,
            width: min(66, bounds.width),
            height: 15
        )
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for textLayer in [
            cyanGlitchLayer,
            magentaGlitchLayer,
            statusTextLayer,
            ambientScanLayer,
            eventScanLayer,
        ] {
            textLayer.frame = statusFrame
            textLayer.contentsScale = scale
        }
        ambientScanMaskLayer.frame = ambientScanLayer.bounds
        eventScanMaskLayer.frame = eventScanLayer.bounds
        ambientScanMaskLayer.contentsScale = scale
        eventScanMaskLayer.contentsScale = scale
        CATransaction.commit()
    }

    func update(
        kind: TaskProgressKind,
        text: String,
        animationsEnabled: Bool
    ) {
        guard displayedKind != kind
                || displayedText != text
                || self.animationsEnabled != animationsEnabled
        else {
            return
        }
        displayedKind = kind
        displayedText = text
        self.animationsEnabled = animationsEnabled

        let color = taskAttentionColor(for: kind)
        let profile = taskStatusTextEffectProfile(for: kind)
        updateText(text, color: color)
        updateScanColors(for: kind, color: color)
        stopAnimations()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        statusTextLayer.shadowColor = color.cgColor
        statusTextLayer.shadowOpacity = profile.glowOpacity
        statusTextLayer.shadowRadius = kind == .waitingForInput || kind == .failed
            ? 3.6 : 2.4
        statusTextLayer.shadowOffset = .zero
        Self.parkScan(ambientScanLayer)
        Self.parkScan(eventScanLayer)
        CATransaction.commit()

        guard animationsEnabled,
              let duration = profile.ambientScanDuration
        else { return }

        ambientScanLayer.add(Self.scanAnimation(
            duration: duration,
            activeFraction: profile.ambientActiveFraction,
            repeatCount: .infinity
        ), forKey: "ambientScan")

        if kind == .waitingForInput || kind == .failed {
            statusTextLayer.add(Self.glowAnimation(
                baseOpacity: profile.glowOpacity,
                duration: duration
            ), forKey: "ambientGlow")
        }
    }

    func playEntrance(for kind: TaskProgressKind) {
        guard animationsEnabled,
              kind == .waitingForInput || kind == .completed || kind == .failed
        else { return }

        let profile = taskStatusTextEffectProfile(for: kind)
        eventScanLayer.add(Self.scanAnimation(
            duration: profile.entranceScanDuration,
            activeFraction: 1,
            repeatCount: profile.entranceScanCount
        ), forKey: "entranceScan")
        statusTextLayer.add(Self.entranceGlowAnimation(
            baseOpacity: profile.glowOpacity,
            duration: profile.entranceScanDuration
                * Double(profile.entranceScanCount)
        ), forKey: "entranceGlow")

        if profile.usesGlitchEntrance {
            playGlitchEntrance()
        }
    }

    func stopAnimations() {
        statusTextLayer.removeAllAnimations()
        ambientScanLayer.removeAllAnimations()
        eventScanLayer.removeAllAnimations()
        cyanGlitchLayer.removeAllAnimations()
        magentaGlitchLayer.removeAllAnimations()
        cyanGlitchLayer.opacity = 0
        magentaGlitchLayer.opacity = 0
    }

    func preparePreviewFrame() {
        guard displayedKind != .idle,
              displayedKind != .reading
        else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        eventScanLayer.startPoint = CGPoint(x: 0.18, y: 0.5)
        eventScanLayer.endPoint = CGPoint(x: 0.72, y: 0.5)
        CATransaction.commit()
    }

    private func configureLayers() {
        wantsLayer = true
        layer?.masksToBounds = false
        configureTextLayer(cyanGlitchLayer)
        configureTextLayer(magentaGlitchLayer)
        configureTextLayer(statusTextLayer)
        configureTextLayer(ambientScanMaskLayer)
        configureTextLayer(eventScanMaskLayer)
        configureScanLayer(ambientScanLayer, mask: ambientScanMaskLayer)
        configureScanLayer(eventScanLayer, mask: eventScanMaskLayer)

        layer?.addSublayer(cyanGlitchLayer)
        layer?.addSublayer(magentaGlitchLayer)
        layer?.addSublayer(statusTextLayer)
        layer?.addSublayer(ambientScanLayer)
        layer?.addSublayer(eventScanLayer)
    }

    private func configureTextLayer(_ textLayer: CATextLayer) {
        textLayer.alignmentMode = .right
        textLayer.truncationMode = .end
        textLayer.isWrapped = false
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        textLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "string": NSNull(),
            "opacity": NSNull(),
        ]
    }

    private func configureScanLayer(
        _ scanLayer: CAGradientLayer,
        mask: CATextLayer
    ) {
        scanLayer.locations = [0, 0.36, 0.5, 0.64, 1]
        scanLayer.mask = mask
        scanLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "startPoint": NSNull(),
            "endPoint": NSNull(),
        ]
        Self.parkScan(scanLayer)
    }

    private func updateText(_ text: String, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.lineBreakMode = .byTruncatingTail
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: Self.statusFont,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        let maskAttributes: [NSAttributedString.Key: Any] = [
            .font: Self.statusFont,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        statusTextLayer.string = NSAttributedString(
            string: text,
            attributes: baseAttributes
        )
        ambientScanMaskLayer.string = NSAttributedString(
            string: text,
            attributes: maskAttributes
        )
        eventScanMaskLayer.string = NSAttributedString(
            string: text,
            attributes: maskAttributes
        )

        var cyanAttributes = baseAttributes
        cyanAttributes[.foregroundColor] = NSColor(
            calibratedRed: 0.1,
            green: 0.9,
            blue: 1,
            alpha: 0.9
        )
        var magentaAttributes = baseAttributes
        magentaAttributes[.foregroundColor] = NSColor(
            calibratedRed: 1,
            green: 0.14,
            blue: 0.72,
            alpha: 0.9
        )
        cyanGlitchLayer.string = NSAttributedString(
            string: text,
            attributes: cyanAttributes
        )
        magentaGlitchLayer.string = NSAttributedString(
            string: text,
            attributes: magentaAttributes
        )
    }

    private func updateScanColors(for kind: TaskProgressKind, color: NSColor) {
        let secondary = kind == .failed
            ? NSColor(calibratedRed: 1, green: 0.14, blue: 0.72, alpha: 1)
            : color
        let colors = [
            color.withAlphaComponent(0).cgColor,
            secondary.withAlphaComponent(0.34).cgColor,
            NSColor.white.withAlphaComponent(0.98).cgColor,
            color.withAlphaComponent(0.58).cgColor,
            color.withAlphaComponent(0).cgColor,
        ]
        ambientScanLayer.colors = colors
        eventScanLayer.colors = colors
    }

    private func playGlitchEntrance() {
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 0.82, 0, 0.58, 0]
        opacity.keyTimes = [0, 0.16, 0.34, 0.54, 1]

        let cyanShift = CAKeyframeAnimation(keyPath: "transform.translation.x")
        cyanShift.values = [0, -1.4, 0.8, -0.5, 0]
        cyanShift.keyTimes = opacity.keyTimes
        let magentaShift = CAKeyframeAnimation(keyPath: "transform.translation.x")
        magentaShift.values = [0, 1.3, -0.9, 0.6, 0]
        magentaShift.keyTimes = opacity.keyTimes

        for (textLayer, shift) in [
            (cyanGlitchLayer, cyanShift),
            (magentaGlitchLayer, magentaShift),
        ] {
            let group = CAAnimationGroup()
            group.animations = [opacity, shift]
            group.duration = 0.42
            group.timingFunction = CAMediaTimingFunction(name: .linear)
            textLayer.add(group, forKey: "glitch")
        }

        let baseShift = CAKeyframeAnimation(keyPath: "transform.translation.x")
        baseShift.values = [0, -0.7, 0.8, 0]
        baseShift.keyTimes = [0, 0.26, 0.58, 1]
        baseShift.duration = 0.36
        baseShift.timingFunction = CAMediaTimingFunction(name: .linear)
        statusTextLayer.add(baseShift, forKey: "glitch")
    }

    private static func parkScan(_ scanLayer: CAGradientLayer) {
        scanLayer.startPoint = CGPoint(x: 1.12, y: 0.5)
        scanLayer.endPoint = CGPoint(x: 1.48, y: 0.5)
    }

    private static func scanAnimation(
        duration: CFTimeInterval,
        activeFraction: Double,
        repeatCount: Float
    ) -> CAAnimationGroup {
        let normalizedActiveFraction = min(1, max(0.01, activeFraction))
        let keyTimes: [NSNumber]
        let startValues: [NSValue]
        let endValues: [NSValue]
        if normalizedActiveFraction == 1 {
            keyTimes = [0, 1]
            startValues = [
                NSValue(point: NSPoint(x: -0.48, y: 0.5)),
                NSValue(point: NSPoint(x: 1.12, y: 0.5)),
            ]
            endValues = [
                NSValue(point: NSPoint(x: -0.12, y: 0.5)),
                NSValue(point: NSPoint(x: 1.48, y: 0.5)),
            ]
        } else {
            keyTimes = [0, NSNumber(value: normalizedActiveFraction), 1]
            startValues = [
                NSValue(point: NSPoint(x: -0.48, y: 0.5)),
                NSValue(point: NSPoint(x: 1.12, y: 0.5)),
                NSValue(point: NSPoint(x: 1.12, y: 0.5)),
            ]
            endValues = [
                NSValue(point: NSPoint(x: -0.12, y: 0.5)),
                NSValue(point: NSPoint(x: 1.48, y: 0.5)),
                NSValue(point: NSPoint(x: 1.48, y: 0.5)),
            ]
        }

        let startPoint = CAKeyframeAnimation(keyPath: "startPoint")
        startPoint.values = startValues
        startPoint.keyTimes = keyTimes

        let endPoint = CAKeyframeAnimation(keyPath: "endPoint")
        endPoint.values = endValues
        endPoint.keyTimes = keyTimes

        let group = CAAnimationGroup()
        group.animations = [startPoint, endPoint]
        group.duration = duration
        group.repeatCount = repeatCount
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return group
    }

    private static func glowAnimation(
        baseOpacity: Float,
        duration: CFTimeInterval
    ) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "shadowOpacity")
        animation.values = [baseOpacity, min(1, baseOpacity + 0.22), baseOpacity, baseOpacity]
        animation.keyTimes = [0, 0.08, 0.18, 1]
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
    }

    private static func entranceGlowAnimation(
        baseOpacity: Float,
        duration: CFTimeInterval
    ) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "shadowOpacity")
        animation.values = [baseOpacity, 1, baseOpacity]
        animation.keyTimes = [0, 0.46, 1]
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
    }
}

private final class CollapsedTaskAttentionView: NSView {
    private var displayedKind: TaskProgressKind?
    private var animationsEnabled = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func update(kind: TaskProgressKind, animationsEnabled: Bool) {
        guard displayedKind != kind || self.animationsEnabled != animationsEnabled else {
            return
        }
        displayedKind = kind
        self.animationsEnabled = animationsEnabled
        layer?.removeAllAnimations()

        guard kind != .idle else {
            isHidden = true
            return
        }
        isHidden = false
        let color = taskAttentionColor(for: kind)
        layer?.borderColor = color.withAlphaComponent(0.82).cgColor
        layer?.borderWidth = kind == .running || kind == .reading ? 0.75 : 1.25
        layer?.cornerRadius = 15
        layer?.opacity = 1

        guard animationsEnabled,
              kind == .waitingForInput || kind == .failed
        else { return }

        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0.42, 1, 0.42, 0.42]
        animation.keyTimes = [0, 0.08, 0.18, 1]
        animation.duration = kind == .failed ? 5 : 8
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(animation, forKey: "ambient")
    }

    func stopAnimations() {
        layer?.removeAllAnimations()
    }
}

private final class TaskBallImageView: NSImageView {
    private let radarSweepLayer = CAGradientLayer()
    private let radarRingMaskLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureRadarLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureRadarLayer()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        let radarFrame = bounds.insetBy(dx: -1.5, dy: -1.5)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        radarSweepLayer.frame = radarFrame
        radarRingMaskLayer.frame = radarSweepLayer.bounds
        radarRingMaskLayer.path = CGPath(
            ellipseIn: radarSweepLayer.bounds.insetBy(dx: 1.5, dy: 1.5),
            transform: nil
        )
        CATransaction.commit()
    }

    func updateRadar(
        color: NSColor,
        visible: Bool,
        animated: Bool
    ) {
        radarSweepLayer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        radarSweepLayer.colors = [
            color.withAlphaComponent(0.04).cgColor,
            color.withAlphaComponent(0.16).cgColor,
            NSColor.white.withAlphaComponent(0.92).cgColor,
            color.withAlphaComponent(0.08).cgColor,
        ]
        radarSweepLayer.locations = [0, 0.54, 0.82, 1]
        radarSweepLayer.opacity = visible ? 0.78 : 0
        CATransaction.commit()

        guard visible, animated else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = Double.pi * 2
        rotation.duration = 3.4
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        radarSweepLayer.add(rotation, forKey: "radarRotation")
    }

    func playRadarPing() {
        let ping = CAKeyframeAnimation(keyPath: "opacity")
        ping.values = [0.34, 1, 0.46, 1, 0.52, 1, 0.78]
        ping.keyTimes = [0, 0.12, 0.25, 0.38, 0.52, 0.68, 1]
        ping.duration = 1.45
        ping.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        radarSweepLayer.add(ping, forKey: "radarPing")
    }

    func stopAnimations() {
        layer?.removeAllAnimations()
        radarSweepLayer.removeAllAnimations()
    }

    private func configureRadarLayer() {
        wantsLayer = true
        layer?.masksToBounds = false
        radarSweepLayer.type = .conic
        radarSweepLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        radarSweepLayer.endPoint = CGPoint(x: 0.5, y: 0)
        radarSweepLayer.opacity = 0
        radarSweepLayer.mask = radarRingMaskLayer
        radarRingMaskLayer.fillColor = NSColor.clear.cgColor
        radarRingMaskLayer.strokeColor = NSColor.white.cgColor
        radarRingMaskLayer.lineWidth = 0.9
        radarRingMaskLayer.lineCap = .round
        radarRingMaskLayer.lineDashPattern = [2.2, 2.8]
        radarSweepLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "opacity": NSNull(),
            "colors": NSNull(),
        ]
        layer?.addSublayer(radarSweepLayer)
    }
}

private final class TaskCompletionCelebrationView: NSView {
    private let innerRingLayer = CAShapeLayer()
    private let outerRingLayer = CAShapeLayer()
    private var particleLayers: [CALayer] = []
    private var celebrationCenter = CGPoint.zero
    private var reducedMotionHaloVisible = false

    private static let particleVectors: [CGPoint] = [
        CGPoint(x: -38, y: -3),
        CGPoint(x: -33, y: -16),
        CGPoint(x: -25, y: -25),
        CGPoint(x: -14, y: -21),
        CGPoint(x: -5, y: -26),
        CGPoint(x: 3, y: -15),
        CGPoint(x: 11, y: -10),
        CGPoint(x: 15, y: -5),
        CGPoint(x: 18, y: 1),
        CGPoint(x: 16, y: 7),
        CGPoint(x: 12, y: 12),
        CGPoint(x: 1, y: 15),
        CGPoint(x: -14, y: 13),
        CGPoint(x: -30, y: 9),
    ]

    private static let particleColors: [NSColor] = [
        NSColor(calibratedRed: 0.22, green: 1, blue: 0.70, alpha: 1),
        NSColor(calibratedRed: 0.13, green: 0.86, blue: 1, alpha: 1),
        NSColor(calibratedRed: 1, green: 0.76, blue: 0.16, alpha: 1),
        NSColor(calibratedRed: 1, green: 0.25, blue: 0.68, alpha: 1),
        NSColor.white,
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayers()
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func updateCenter(_ center: CGPoint) {
        celebrationCenter = center
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        configureRingGeometry(
            innerRingLayer,
            size: CGSize(width: 42, height: 24)
        )
        configureRingGeometry(
            outerRingLayer,
            size: CGSize(width: 50, height: 26)
        )
        for (index, particleLayer) in particleLayers.enumerated() {
            let vector = Self.particleVectors[index]
            particleLayer.position = CGPoint(
                x: center.x + vector.x,
                y: center.y + vector.y
            )
        }
        CATransaction.commit()
    }

    func play(startTime: CFTimeInterval) {
        guard celebrationCenter != .zero else { return }
        stopAnimations()

        animateRing(
            innerRingLayer,
            delay: 0.06,
            activeDuration: 0.74,
            startScale: 0.62,
            endScale: 1.52,
            peakOpacity: 0.92,
            startTime: startTime
        )
        animateRing(
            outerRingLayer,
            delay: 0.14,
            activeDuration: 0.86,
            startScale: 0.66,
            endScale: 1.42,
            peakOpacity: 0.56,
            startTime: startTime
        )

        for (index, particleLayer) in particleLayers.enumerated() {
            animateParticle(
                particleLayer,
                vector: Self.particleVectors[index],
                index: index,
                startTime: startTime
            )
        }
    }

    func setReducedMotionHaloVisible(_ visible: Bool) {
        guard reducedMotionHaloVisible != visible else { return }
        stopAnimations()
        reducedMotionHaloVisible = visible
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        innerRingLayer.opacity = visible ? 0.44 : 0
        innerRingLayer.transform = CATransform3DMakeScale(1.08, 1.08, 1)
        outerRingLayer.opacity = visible ? 0.22 : 0
        outerRingLayer.transform = CATransform3DMakeScale(1.22, 1.22, 1)
        CATransaction.commit()
    }

    func preparePreviewFrame(visible: Bool) {
        stopAnimations()
        guard visible else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        innerRingLayer.opacity = 0.76
        innerRingLayer.transform = CATransform3DMakeScale(1.28, 1.28, 1)
        outerRingLayer.opacity = 0.42
        outerRingLayer.transform = CATransform3DMakeScale(1.48, 1.48, 1)
        for (index, particleLayer) in particleLayers.enumerated() {
            let vector = Self.particleVectors[index]
            particleLayer.position = CGPoint(
                x: celebrationCenter.x + vector.x * 0.68,
                y: celebrationCenter.y + vector.y * 0.68
            )
            particleLayer.opacity = index.isMultiple(of: 4) ? 0.58 : 0.92
            particleLayer.transform = CATransform3DMakeRotation(
                CGFloat(index) * 0.48,
                0,
                0,
                1
            )
        }
        CATransaction.commit()
    }

    func stopAnimations() {
        reducedMotionHaloVisible = false
        innerRingLayer.removeAllAnimations()
        outerRingLayer.removeAllAnimations()
        particleLayers.forEach { $0.removeAllAnimations() }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        innerRingLayer.opacity = 0
        outerRingLayer.opacity = 0
        innerRingLayer.transform = CATransform3DIdentity
        outerRingLayer.transform = CATransform3DIdentity
        for (index, particleLayer) in particleLayers.enumerated() {
            let vector = Self.particleVectors[index]
            particleLayer.opacity = 0
            particleLayer.position = CGPoint(
                x: celebrationCenter.x + vector.x,
                y: celebrationCenter.y + vector.y
            )
            particleLayer.transform = CATransform3DIdentity
        }
        CATransaction.commit()
    }

    private func configureLayers() {
        wantsLayer = true
        layer?.masksToBounds = taskCompletionCelebrationProfile.clipsToBallBand
        configureRingLayer(
            innerRingLayer,
            color: NSColor(
                calibratedRed: 0.26,
                green: 1,
                blue: 0.72,
                alpha: 1
            ),
            lineWidth: 1.35
        )
        configureRingLayer(
            outerRingLayer,
            color: NSColor(
                calibratedRed: 0.18,
                green: 0.82,
                blue: 1,
                alpha: 1
            ),
            lineWidth: 0.9
        )
        layer?.addSublayer(outerRingLayer)
        layer?.addSublayer(innerRingLayer)

        for index in 0..<taskCompletionCelebrationProfile.particleCount {
            let particleLayer = CALayer()
            let isDot = index.isMultiple(of: 4)
            let size = isDot
                ? CGSize(width: 3.2, height: 3.2)
                : CGSize(width: 1.8, height: index.isMultiple(of: 3) ? 6 : 4.6)
            particleLayer.bounds = CGRect(origin: .zero, size: size)
            particleLayer.cornerRadius = isDot ? size.width / 2 : 0.9
            particleLayer.backgroundColor = Self.particleColors[
                index % Self.particleColors.count
            ].cgColor
            particleLayer.shadowColor = particleLayer.backgroundColor
            particleLayer.shadowOpacity = 0.72
            particleLayer.shadowRadius = 2.2
            particleLayer.shadowOffset = .zero
            particleLayer.opacity = 0
            particleLayer.actions = [
                "opacity": NSNull(),
                "position": NSNull(),
                "transform": NSNull(),
            ]
            layer?.addSublayer(particleLayer)
            particleLayers.append(particleLayer)
        }
    }

    private func configureRingLayer(
        _ ringLayer: CAShapeLayer,
        color: NSColor,
        lineWidth: CGFloat
    ) {
        ringLayer.fillColor = NSColor.clear.cgColor
        ringLayer.strokeColor = color.cgColor
        ringLayer.lineWidth = lineWidth
        ringLayer.shadowColor = color.cgColor
        ringLayer.shadowOpacity = 0.68
        ringLayer.shadowRadius = 3
        ringLayer.shadowOffset = .zero
        ringLayer.opacity = 0
        ringLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "opacity": NSNull(),
            "path": NSNull(),
            "transform": NSNull(),
        ]
    }

    private func configureRingGeometry(
        _ ringLayer: CAShapeLayer,
        size: CGSize
    ) {
        ringLayer.bounds = CGRect(origin: .zero, size: size)
        ringLayer.position = CGPoint(
            x: celebrationCenter.x - 18,
            y: celebrationCenter.y
        )
        ringLayer.path = CGPath(
            ellipseIn: ringLayer.bounds.insetBy(dx: 1.5, dy: 1.5),
            transform: nil
        )
    }

    private func animateRing(
        _ ringLayer: CAShapeLayer,
        delay: CFTimeInterval,
        activeDuration: CFTimeInterval,
        startScale: CGFloat,
        endScale: CGFloat,
        peakOpacity: Float,
        startTime: CFTimeInterval
    ) {
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [startScale, 1.08, endScale]
        scale.keyTimes = [0, 0.38, 1]
        scale.beginTime = delay
        scale.duration = activeDuration
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, peakOpacity, peakOpacity * 0.56, 0]
        opacity.keyTimes = [0, 0.16, 0.58, 1]
        opacity.beginTime = delay
        opacity.duration = activeDuration
        opacity.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.beginTime = startTime
        group.duration = taskCompletionCelebrationProfile.cycleDuration
        group.repeatCount = Float(taskCompletionCelebrationProfile.cycleCount)
        ringLayer.add(group, forKey: "celebration")
    }

    private func animateParticle(
        _ particleLayer: CALayer,
        vector: CGPoint,
        index: Int,
        startTime: CFTimeInterval
    ) {
        let duration = 0.70 + Double(index % 3) * 0.06
        let delay = 0.12 + Double(index) * 0.006
        let middle = CGPoint(
            x: celebrationCenter.x + vector.x * 0.48,
            y: celebrationCenter.y + vector.y * 0.42 - 2.5
        )
        let end = CGPoint(
            x: celebrationCenter.x + vector.x,
            y: celebrationCenter.y + vector.y + 2
        )

        let position = CAKeyframeAnimation(keyPath: "position")
        position.values = [
            NSValue(point: celebrationCenter),
            NSValue(point: middle),
            NSValue(point: end),
        ]
        position.keyTimes = [0, 0.48, 1]
        position.beginTime = delay
        position.duration = duration
        position.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 1, 0.92, 0]
        opacity.keyTimes = [0, 0.14, 0.68, 1]
        opacity.beginTime = delay
        opacity.duration = duration
        opacity.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.3, 1.12, 0.72]
        scale.keyTimes = [0, 0.34, 1]
        scale.beginTime = delay
        scale.duration = duration
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = (index.isMultiple(of: 2) ? 1.0 : -1.0)
            * Double.pi * 1.25
        rotation.beginTime = delay
        rotation.duration = duration
        rotation.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let group = CAAnimationGroup()
        group.animations = [position, opacity, scale, rotation]
        group.beginTime = startTime
        group.duration = taskCompletionCelebrationProfile.cycleDuration
        group.repeatCount = Float(taskCompletionCelebrationProfile.cycleCount)
        particleLayer.add(group, forKey: "celebration")
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
        // 动效使用独立图层，避免每一帧向上触发整个面板重绘。
        wantsLayer = true
        canDrawSubviewsIntoLayer = false
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        configureTaskAttentionViews()
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
    private(set) var taskProgress = TaskProgressSnapshot.reading {
        didSet {
            if taskProgress != oldValue {
                needsDisplay = true
                needsLayout = true
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
            needsLayout = true
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
            needsLayout = true
            updateTaskAnimationState()
            window?.invalidateCursorRects(for: self)
            window?.invalidateShadow()
        }
    }
    var allowsWindowDragging = false {
        didSet {
            guard allowsWindowDragging != oldValue else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            window?.invalidateShadow()
        }
    }
    var onToggleCollapsed: (() -> Void)?
    var onCycleRateLimit: (() -> Void)?
    var onOpenTask: ((TaskProgressItem) -> Void)?
    var onWindowDragCompleted: (() -> Void)?
    private var hideButtonTrackingArea: NSTrackingArea?
    private var isHideButtonHovered = false
    private var taskBallViews: [TaskProgressKind: TaskBallImageView] = [:]
    private let taskCompletionCelebrationView = TaskCompletionCelebrationView(
        frame: .zero
    )
    private var taskRowAttentionViews: [String: TaskAttentionRowView] = [:]
    private let collapsedTaskAttentionView = CollapsedTaskAttentionView(frame: .zero)
    private var attentionItems = TaskProgressSnapshot.reading.items
    private var pendingAttentionEvents: [TaskAttentionEvent] = []
    private var taskAnimationsEnabled = false
    private var lastBallAnimationKind: TaskProgressKind?
    private var lastBallAnimationsEnabled = false
    private var windowVisibilityObservers: [NSObjectProtocol] = []

    private static let taskBallSpecifications: [(
        kind: TaskProgressKind,
        assetName: String,
        horizontalFraction: CGFloat
    )] = [
        (.failed, "01-red.png", 0.15),
        (.running, "02-blue.png", 0.33),
        (.reading, "03-pink.png", 0.51),
        (.waitingForInput, "04-orange.png", 0.69),
        (.completed, "05-green.png", 0.86),
    ]

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
        needsLayout = true
        updateTaskAnimationState()
        window?.invalidateCursorRects(for: self)
    }

    private lazy var completedTaskIcon: NSImage? = taskIcon(
        named: "task-completed-icon.png"
    )
    private lazy var runningTaskIcon: NSImage? = taskIcon(
        named: "task-running-icon.png"
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
        stopAllTaskAnimations()
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
                self?.updateTaskAnimationState()
            })
        }
        needsLayout = true
        syncTaskAttentionRowViews()
        updateTaskAnimationState()
    }

    func setTaskAnimationsEnabled(_ enabled: Bool) {
        guard taskAnimationsEnabled != enabled else { return }
        taskAnimationsEnabled = enabled
        updateTaskAnimationState()
    }

    func applyTaskProgress(
        _ result: TaskProgressReadResult,
        events: [TaskAttentionEvent] = []
    ) {
        attentionItems = result.allItems
        taskProgress = result.snapshot
        enqueueAttentionEvents(events)
        updateTaskAnimationState()
    }

    func prepareTaskEffectPreviewFrame() {
        taskRowAttentionViews.values.forEach { $0.preparePreviewFrame() }
        let showsCompletionCelebration = dominantTaskProgressKind(
            in: attentionItems
        ) == .completed && usesLayeredTaskBalls && !isCollapsed
        taskCompletionCelebrationView.preparePreviewFrame(
            visible: showsCompletionCelebration
        )
        guard showsCompletionCelebration else { return }

        let waveOffsets: [TaskProgressKind: CGFloat] = [
            .completed: -3.8,
            .waitingForInput: -2.5,
            .reading: -1.2,
            .running: -0.4,
            .failed: 0,
        ]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (kind, offset) in waveOffsets {
            taskBallViews[kind]?.layer?.setAffineTransform(
                CGAffineTransform(translationX: 0, y: offset)
            )
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        layoutTaskAttentionViews()
    }

    private var usesLayeredTaskBalls: Bool {
        panelConfig.theme.backgroundImage == "quota-panel-background.png"
            && taskBallViews.count == Self.taskBallSpecifications.count
    }

    private var canAnimateTaskEffects: Bool {
        let isVisible = taskAnimationsEnabled && window?.isVisible == true
        let isOccluded = window.map {
            !$0.occlusionState.contains(.visible)
        } ?? true
        return shouldAnimateTaskEffects(
            isWindowVisible: isVisible,
            isWindowOccluded: isOccluded,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    private func configureTaskAttentionViews() {
        addSubview(taskCompletionCelebrationView)
        for specification in Self.taskBallSpecifications {
            guard let image = taskIcon(named: specification.assetName) else { continue }
            let imageView = TaskBallImageView(frame: .zero)
            imageView.image = image
            imageView.imageAlignment = .alignCenter
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.imageFrameStyle = .none
            imageView.isEditable = false
            imageView.wantsLayer = true
            imageView.canDrawSubviewsIntoLayer = false
            imageView.layerContentsRedrawPolicy = .onSetNeedsDisplay
            imageView.layer?.masksToBounds = false
            imageView.isHidden = true
            addSubview(imageView)
            taskBallViews[specification.kind] = imageView
        }
        collapsedTaskAttentionView.isHidden = true
        addSubview(collapsedTaskAttentionView)
    }

    private func layoutTaskAttentionViews() {
        let bodyRect = panelBodyRect()
        let showsBalls = usesLayeredTaskBalls && !isCollapsed
        let ballSize: CGFloat = 36
        let ballY = bodyRect.minY + 28
        taskCompletionCelebrationView.frame = bounds
        taskCompletionCelebrationView.alphaValue = showsBalls ? 1 : 0
        for specification in Self.taskBallSpecifications {
            guard let imageView = taskBallViews[specification.kind] else { continue }
            let centerX = bodyRect.minX
                + bodyRect.width * specification.horizontalFraction
            imageView.frame = NSRect(
                x: floor(centerX - ballSize / 2),
                y: ballY,
                width: ballSize,
                height: ballSize
            )
            imageView.isHidden = !showsBalls
        }
        if let completedBall = taskBallViews[.completed] {
            taskCompletionCelebrationView.updateCenter(CGPoint(
                x: completedBall.frame.midX
                    - taskCompletionCelebrationView.frame.minX,
                y: completedBall.frame.midY
                    - taskCompletionCelebrationView.frame.minY
            ))
        }

        for (index, item) in taskProgress.items.enumerated() {
            guard let taskID = rowAttentionIdentifier(for: item, index: index),
                  let rowView = taskRowAttentionViews[taskID]
            else { continue }
            rowView.frame = taskProgressRowRect(index: index, in: bodyRect)
            rowView.alphaValue = isCollapsed ? 0 : 1
        }

        collapsedTaskAttentionView.frame = bodyRect.insetBy(dx: 1, dy: 1)
    }

    private func syncTaskAttentionRowViews() {
        let animationsEnabled = canAnimateTaskEffects && !isCollapsed
        var activeIDs = Set<String>()
        for (index, item) in taskProgress.items.enumerated() {
            guard let taskID = rowAttentionIdentifier(for: item, index: index) else {
                continue
            }
            activeIDs.insert(taskID)
            let rowView: TaskAttentionRowView
            if let existing = taskRowAttentionViews[taskID] {
                rowView = existing
            } else {
                rowView = TaskAttentionRowView(frame: .zero)
                taskRowAttentionViews[taskID] = rowView
                addSubview(rowView)
            }
            rowView.update(
                kind: item.kind,
                text: item.statusText,
                animationsEnabled: animationsEnabled
            )
        }

        let removedIDs = taskRowAttentionViews.keys.filter {
            !activeIDs.contains($0)
        }
        for taskID in removedIDs {
            guard let rowView = taskRowAttentionViews.removeValue(forKey: taskID) else {
                continue
            }
            rowView.stopAnimations()
            rowView.removeFromSuperview()
        }
    }

    private func rowAttentionIdentifier(
        for item: TaskProgressItem,
        index: Int
    ) -> String? {
        taskAttentionIdentifier(for: item)
            ?? "display:\(index):\(item.title):\(item.startedAt.timeIntervalSinceReferenceDate.bitPattern)"
    }

    private func enqueueAttentionEvents(_ events: [TaskAttentionEvent]) {
        for event in events {
            pendingAttentionEvents.removeAll { $0.taskID == event.taskID }
            switch event.kind {
            case .waitingForInput, .completed, .failed:
                pendingAttentionEvents.append(event)
            case .reading, .running, .idle:
                break
            }
        }
    }

    private func updateTaskAnimationState() {
        let animationsEnabled = canAnimateTaskEffects
        let dominantKind = dominantTaskProgressKind(in: attentionItems)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let showsReducedMotionCompletionHalo = !animationsEnabled
            && !isCollapsed
            && usesLayeredTaskBalls
            && dominantKind == .completed
            && reduceMotion
        let retainsAnimatedCompletionCelebration = animationsEnabled
            && !isCollapsed
            && usesLayeredTaskBalls
            && dominantKind == .completed

        syncTaskAttentionRowViews()
        collapsedTaskAttentionView.update(
            kind: dominantKind,
            animationsEnabled: animationsEnabled && isCollapsed
        )
        collapsedTaskAttentionView.isHidden = !isCollapsed || dominantKind == .idle
        updateTaskBallPresentation(
            dominantKind: dominantKind,
            animationsEnabled: animationsEnabled && !isCollapsed
        )

        taskCompletionCelebrationView.setReducedMotionHaloVisible(
            showsReducedMotionCompletionHalo
        )

        if !retainsAnimatedCompletionCelebration
            && !showsReducedMotionCompletionHalo
        {
            taskCompletionCelebrationView.stopAnimations()
        }

        guard animationsEnabled else {
            for imageView in taskBallViews.values {
                imageView.stopAnimations()
            }
            for rowView in taskRowAttentionViews.values {
                rowView.stopAnimations()
            }
            collapsedTaskAttentionView.stopAnimations()
            if reduceMotion {
                pendingAttentionEvents.removeAll(keepingCapacity: true)
            }
            return
        }
        playPendingAttentionEvents(dominantKind: dominantKind)
    }

    private func updateTaskBallPresentation(
        dominantKind: TaskProgressKind,
        animationsEnabled: Bool
    ) {
        let shouldAnimate = animationsEnabled && usesLayeredTaskBalls
        guard lastBallAnimationKind != dominantKind
                || lastBallAnimationsEnabled != shouldAnimate
        else { return }

        lastBallAnimationKind = dominantKind
        lastBallAnimationsEnabled = shouldAnimate
        let emphasizesUrgency = dominantKind == .waitingForInput
            || dominantKind == .failed

        for specification in Self.taskBallSpecifications {
            guard let imageView = taskBallViews[specification.kind],
                  let imageLayer = imageView.layer
            else { continue }
            if shouldAnimate {
                imageLayer.removeAnimation(forKey: "ambient")
            } else {
                imageView.stopAnimations()
            }
            imageLayer.shadowColor = taskAttentionColor(for: dominantKind).cgColor
            imageLayer.shadowOffset = .zero
            imageLayer.shadowRadius = specification.kind == dominantKind ? 5 : 0
            imageLayer.shadowOpacity = specification.kind == dominantKind
                && dominantKind != .idle ? 0.38 : 0
            imageView.alphaValue = emphasizesUrgency
                && specification.kind != dominantKind ? 0.66 : 1
            imageView.updateRadar(
                color: taskAttentionColor(for: .waitingForInput),
                visible: specification.kind == .waitingForInput
                    && dominantKind == .waitingForInput,
                animated: shouldAnimate
            )
        }

        guard shouldAnimate,
              let activeLayer = taskBallViews[dominantKind]?.layer
        else { return }

        let animation: CAKeyframeAnimation
        switch dominantKind {
        case .reading:
            animation = Self.repeatingAnimation(
                keyPath: "opacity",
                values: [0.72, 1, 0.72],
                keyTimes: [0, 0.5, 1],
                duration: 2.4
            )
        case .running:
            animation = Self.repeatingAnimation(
                keyPath: "transform.translation.y",
                values: [0, -1.6, 0],
                keyTimes: [0, 0.5, 1],
                duration: 2.2
            )
        case .waitingForInput:
            return
        case .failed:
            animation = Self.repeatingAnimation(
                keyPath: "transform.translation.x",
                values: [0, -0.8, 0.8, 0, 0],
                keyTimes: [0, 0.04, 0.08, 0.14, 1],
                duration: 6.2
            )
        case .completed, .idle:
            return
        }
        activeLayer.add(animation, forKey: "ambient")
    }

    private func playPendingAttentionEvents(dominantKind: TaskProgressKind) {
        guard !pendingAttentionEvents.isEmpty else { return }
        let events = pendingAttentionEvents
        pendingAttentionEvents.removeAll(keepingCapacity: true)

        for event in events {
            taskRowAttentionViews[event.taskID]?.playEntrance(for: event.kind)
        }

        guard !isCollapsed,
              let dominantEvent = events.max(by: {
                  taskAttentionPriority($0.kind) < taskAttentionPriority($1.kind)
              })
        else { return }

        if (dominantKind == .failed || dominantKind == .waitingForInput),
           taskAttentionPriority(dominantKind)
            > taskAttentionPriority(dominantEvent.kind)
        {
            return
        }
        playTaskBallEntrance(for: dominantEvent.kind)
    }

    private func playTaskBallEntrance(for kind: TaskProgressKind) {
        guard usesLayeredTaskBalls,
              let activeView = taskBallViews[kind],
              let activeLayer = activeView.layer
        else { return }

        switch kind {
        case .waitingForInput:
            activeView.playRadarPing()
        case .completed:
            let startTime = CACurrentMediaTime()
            let entrance = Self.completionCycleAnimation(
                keyPath: "transform.scale",
                values: [0.88, 1.22, 0.94, 1.07, 1],
                keyTimes: [0, 0.28, 0.50, 0.72, 1],
                activeDuration: 0.82
            )
            entrance.beginTime = startTime
            activeLayer.add(entrance, forKey: "entrance")
            taskCompletionCelebrationView.play(startTime: startTime)
            for (index, kind) in taskCompletionWaveOrder.enumerated() {
                guard let imageLayer = taskBallViews[kind]?.layer else {
                    continue
                }
                let wave = Self.completionCycleAnimation(
                    keyPath: "transform.translation.y",
                    values: [0, -4.2, 0.8, 0],
                    keyTimes: [0, 0.42, 0.68, 1],
                    activeDuration: 0.58,
                    delay: Double(index)
                        * taskCompletionCelebrationProfile.waveStagger
                )
                wave.beginTime = startTime
                imageLayer.add(wave, forKey: "completionWave")
            }
        case .failed:
            activeLayer.add(Self.oneShotAnimation(
                keyPath: "transform.translation.x",
                values: [0, -1.6, 1.5, -0.8, 0.7, 0],
                keyTimes: [0, 0.16, 0.34, 0.52, 0.7, 1],
                duration: 0.42
            ), forKey: "entrance")
        case .reading, .running, .idle:
            break
        }
    }

    private func stopAllTaskAnimations() {
        for imageView in taskBallViews.values {
            imageView.stopAnimations()
        }
        for rowView in taskRowAttentionViews.values {
            rowView.stopAnimations()
        }
        taskCompletionCelebrationView.stopAnimations()
        collapsedTaskAttentionView.stopAnimations()
        lastBallAnimationKind = nil
        lastBallAnimationsEnabled = false
    }

    private static func repeatingAnimation(
        keyPath: String,
        values: [CGFloat],
        keyTimes: [NSNumber],
        duration: CFTimeInterval
    ) -> CAKeyframeAnimation {
        let animation = oneShotAnimation(
            keyPath: keyPath,
            values: values,
            keyTimes: keyTimes,
            duration: duration
        )
        animation.repeatCount = .infinity
        return animation
    }

    private static func completionCycleAnimation(
        keyPath: String,
        values: [CGFloat],
        keyTimes: [NSNumber],
        activeDuration: CFTimeInterval,
        delay: CFTimeInterval = 0
    ) -> CAKeyframeAnimation {
        let cycleDuration = taskCompletionCelebrationProfile.cycleDuration
        var cycleValues = values
        var cycleKeyTimes = keyTimes.map {
            NSNumber(value: (delay + $0.doubleValue * activeDuration)
                / cycleDuration)
        }

        if delay > 0, let firstValue = values.first {
            cycleValues.insert(firstValue, at: 0)
            cycleKeyTimes.insert(0, at: 0)
        }
        if let lastValue = values.last,
           (cycleKeyTimes.last?.doubleValue ?? 0) < 1
        {
            cycleValues.append(lastValue)
            cycleKeyTimes.append(1)
        }

        let animation = oneShotAnimation(
            keyPath: keyPath,
            values: cycleValues,
            keyTimes: cycleKeyTimes,
            duration: cycleDuration
        )
        animation.repeatCount = Float(taskCompletionCelebrationProfile.cycleCount)
        return animation
    }

    private static func oneShotAnimation(
        keyPath: String,
        values: [CGFloat],
        keyTimes: [NSNumber],
        duration: CFTimeInterval
    ) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values.map { NSNumber(value: Double($0)) }
        animation.keyTimes = keyTimes
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
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

        if !isCollapsed, usesLayeredTaskBalls || backgroundImage != nil {
            NSGraphicsContext.saveGraphicsState()
            bodyPath.addClip()
            if usesLayeredTaskBalls {
                NSColor.black.setFill()
                NSBezierPath(rect: NSRect(
                    x: bodyRect.minX,
                    y: bodyRect.minY,
                    width: bodyRect.width,
                    height: min(93, bodyRect.height)
                )).fill()
            } else if let backgroundImage {
                drawFiveBallBand(backgroundImage, in: bodyRect)
            }
            NSColor.black.withAlphaComponent(0.08).setFill()
            bodyPath.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        border.setStroke()
        bodyPath.lineWidth = 1
        bodyPath.stroke()

        if !allowsWindowDragging {
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
        }

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
            drawCollapsedTaskIndicator(
                kind: dominantTaskProgressKind(in: attentionItems),
                in: bodyRect
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

    private func drawCollapsedTaskIndicator(
        kind: TaskProgressKind,
        in bodyRect: NSRect
    ) {
        guard kind != .idle else { return }
        let color = taskAttentionColor(for: kind)
        let dotRect = NSRect(
            x: bodyRect.maxX - 13,
            y: bodyRect.minY + 8,
            width: 6,
            height: 6
        )
        color.withAlphaComponent(0.24).setFill()
        NSBezierPath(ovalIn: dotRect.insetBy(dx: -2, dy: -2)).fill()
        color.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
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
        taskAttentionColor(for: kind)
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
