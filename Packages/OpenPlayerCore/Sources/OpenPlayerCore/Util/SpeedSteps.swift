import Foundation

/// Playback speed arithmetic for the speed keys and the clickable speed label.
public enum SpeedSteps {
    public static let minimum = 0.1
    public static let maximum = 4.0
    /// The label click cycles 1.0 → 1.25 → … → 2.0 → 1.0.
    public static let cycleStep = 0.25
    public static let cycleMaximum = 2.0

    /// Next value on the `step` grid above `speed` (1.75 with step 0.1 → 1.8).
    public static func up(from speed: Double, step: Double) -> Double {
        guard step > 0 else { return speed }
        return clamp(((speed / step + 1e-6).rounded(.down) + 1) * step)
    }

    /// Previous value on the `step` grid below `speed` (1.75 with step 0.1 → 1.7).
    public static func down(from speed: Double, step: Double) -> Double {
        guard step > 0 else { return speed }
        return clamp(((speed / step - 1e-6).rounded(.up) - 1) * step)
    }

    /// The label click: next 0.25 step, or back to 1.0 once 2.0 is reached.
    public static func cycle(from speed: Double) -> Double {
        let next = up(from: speed, step: cycleStep)
        return next > cycleMaximum + 1e-6 ? 1.0 : next
    }

    /// "1.0×", "1.25×", "1.1×", "2.0×".
    public static func label(_ speed: Double) -> String {
        var text = String(format: "%.2f", speed)
        if text.hasSuffix("0") { text.removeLast() }
        return text + "×"
    }

    private static func clamp(_ value: Double) -> Double {
        // Rounded to hundredths so repeated steps don't drift (0.1 × 3 = 0.30000000000000004).
        (min(maximum, max(minimum, value)) * 100).rounded() / 100
    }
}
