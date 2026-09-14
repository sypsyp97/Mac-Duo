import Foundation

/// Turns the lid sensor's sparse readings into a value that changes smoothly
/// at the display's refresh rate.
///
/// Measured on an M5 Pro: polling the sensor at 270 Hz yields a new value only
/// **8.2 times a second**, with gaps of 103 ms at the median, 205 ms at the
/// 90th percentile and 312 ms at worst, each moving about 0.02 degrees. The
/// display draws at 120 Hz, so fourteen frames in fifteen have nothing new,
/// and the feel of the effect is decided by what is drawn in between.
///
/// 🚫 Do not replace this with velocity extrapolation. An alpha-beta filter
/// was written, tuned against a simulation of exactly the sensor behaviour
/// above, and unit tested: on paper it cut the lag of a steady close from
/// several degrees to 0.75. On a real lid it was clearly worse. A hand-pushed
/// lid is not the smooth ramp the simulation assumed — it carries tremor and
/// hinge stiction, and extrapolating a velocity from that amplifies both.
/// Reversing near the start angle was the worst of it: the estimator coasts
/// through the gap on a speed that no longer applies and then gets hauled
/// back. A critically damped spring cannot overshoot whatever the input does,
/// and that stability is worth more here than the latency it costs.
///
/// Semi-implicit Euler stays stable while `frequency * dt` is below 2. The
/// caller clamps `dt`.
public struct CriticallyDampedSpring {
    public var value: Double
    public var velocity: Double = 0

    /// Radians per second. Higher follows the target faster and smooths less.
    public var frequency: Double = 16

    public init(value: Double = 0) {
        self.value = value
    }

    public mutating func advance(to target: Double, dt: Double) {
        let acceleration = frequency * frequency * (target - value) - 2 * frequency * velocity
        velocity += acceleration * dt
        value += velocity * dt
    }

    public mutating func reset(to newValue: Double) {
        value = newValue
        velocity = 0
    }
}
