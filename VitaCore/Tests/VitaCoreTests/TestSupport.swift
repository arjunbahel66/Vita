import Foundation

/// Floating-point comparison helper.
///
/// Swift Testing has no `accuracy:` parameter the way XCTest did, and these are
/// averages and ratios where exact equality is the wrong assertion.
func isClose(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.0001) -> Bool {
    abs(lhs - rhs) < tolerance
}
