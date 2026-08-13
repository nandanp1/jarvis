import AppKit
import QuartzCore

final class AmbientOrbView: NSView {
    private let outerLayer = CAShapeLayer()
    private let innerLayer = CAShapeLayer()
    private let glowLayer = CAShapeLayer()
    private var assistantState: AssistantState = .idle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(glowLayer)
        layer?.addSublayer(outerLayer)
        layer?.addSublayer(innerLayer)
        configureLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.addSublayer(glowLayer)
        layer?.addSublayer(outerLayer)
        layer?.addSublayer(innerLayer)
        configureLayers()
    }

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        let outerRect = NSRect(x: (bounds.width - side) / 2 + 8, y: (bounds.height - side) / 2 + 8, width: side - 16, height: side - 16)
        let innerRect = outerRect.insetBy(dx: side * 0.24, dy: side * 0.24)
        let glowRect = outerRect.insetBy(dx: -7, dy: -7)
        outerLayer.path = CGPath(ellipseIn: outerRect, transform: nil)
        innerLayer.path = CGPath(ellipseIn: innerRect, transform: nil)
        glowLayer.path = CGPath(ellipseIn: glowRect, transform: nil)
    }

    func update(state: AssistantState) {
        assistantState = state
        let color: NSColor
        switch state {
        case .error: color = JarvisTheme.danger
        case .executing: color = JarvisTheme.success
        default: color = JarvisTheme.accent
        }
        outerLayer.strokeColor = color.cgColor
        innerLayer.fillColor = color.cgColor
        glowLayer.strokeColor = color.withAlphaComponent(0.22).cgColor
        updateAnimation(for: state)
    }

    private func configureLayers() {
        outerLayer.fillColor = NSColor.clear.cgColor
        outerLayer.strokeColor = JarvisTheme.accent.cgColor
        outerLayer.lineWidth = 2
        innerLayer.fillColor = JarvisTheme.accent.cgColor
        glowLayer.fillColor = NSColor.clear.cgColor
        glowLayer.strokeColor = JarvisTheme.accentSoft.cgColor
        glowLayer.lineWidth = 10
        updateAnimation(for: .idle)
    }

    private func updateAnimation(for state: AssistantState) {
        [outerLayer, innerLayer, glowLayer].forEach { $0.removeAllAnimations() }
        guard state != .error else { return }

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = state == .idle ? 0.45 : 0.35
        pulse.toValue = 1.0
        pulse.duration = state == .processing ? 0.7 : 1.55
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        glowLayer.add(pulse, forKey: "jarvisPulse")

        if state == .listening || state == .wakeDetected {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.92
            scale.toValue = 1.08
            scale.duration = 0.55
            scale.autoreverses = true
            scale.repeatCount = .infinity
            innerLayer.add(scale, forKey: "listeningScale")
        }

        if state == .processing {
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = 0
            rotation.toValue = Double.pi * 2
            rotation.duration = 1.4
            rotation.repeatCount = .infinity
            outerLayer.lineDashPattern = [4, 8]
            outerLayer.add(rotation, forKey: "thinkingRotation")
        } else {
            outerLayer.lineDashPattern = nil
        }
    }
}

