import Foundation
import os

/// Intervals appear in Instruments without changing application UI.
public enum TilePerformance {
    private static let signposter = OSSignposter(subsystem: "app.euclid", category: "TilePipeline")

    public struct Interval: @unchecked Sendable {
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState
    }
    public static func begin(_ name: StaticString) -> Interval {
        Interval(name: name, state: signposter.beginInterval(name, id: signposter.makeSignpostID()))
    }
    public static func end(_ interval: Interval) { signposter.endInterval(interval.name, interval.state) }

    public static func measure<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let interval = begin(name)
        defer { end(interval) }
        return try work()
    }
}
