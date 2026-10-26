import Foundation

/// When Hushhh looks for the caret again after switching an app's accessibility tree on.
/// Electron apps take about 2 s to build it; Chromium browsers usually less.
enum RefineSchedule {
    /// Seconds after the tree was switched on.
    static let delays: [TimeInterval] = [0.8, 1.6, 2.5, 3.5]

    /// The looks still ahead for a session that starts `elapsed` seconds after the tree was
    /// switched on, each with how long to wait from now.
    static func pending(after elapsed: TimeInterval, delays: [TimeInterval] = delays)
        -> [(delay: TimeInterval, wait: TimeInterval)] {
        delays.filter { $0 > elapsed }.map { (delay: $0, wait: $0 - elapsed) }
    }
}
