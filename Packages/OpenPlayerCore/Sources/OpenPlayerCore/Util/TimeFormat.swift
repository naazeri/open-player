import Foundation

public enum TimeFormat {
    /// "01:02:03" — always with hours, the way PotPlayer lists bookmarks.
    public static func long(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// "3:20" or "1:02:03" for the control bar; hours appear when `reference` (usually the duration) needs them.
    public static func short(_ seconds: Double, reference: Double? = nil) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        let needsHours = total >= 3600 || (reference ?? 0) >= 3600
        if needsHours {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// "5 Sec.", "1 Min.", "1 Min. 30 Sec." for seek step labels.
    public static func stepLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) Sec." }
        let minutes = total / 60, rest = total % 60
        return rest == 0 ? "\(minutes) Min." : "\(minutes) Min. \(rest) Sec."
    }

    /// Parses "hh:mm:ss(.ms)", "mm:ss" or plain seconds.
    public static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 3 else { return nil }
        var result = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            result = result * 60 + value
        }
        return result
    }
}
