import os

/// Launch and loading milestones, visible as Points of Interest in Instruments.
enum Signpost {
    private static let signposter = OSSignposter(subsystem: "app.openplayer.OpenPlayer", category: .pointsOfInterest)

    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }
}
