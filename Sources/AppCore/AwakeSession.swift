import Foundation

public enum AwakeRequestKind { case system, display }

/// The app supplies IOKit; the core owns request lifetime and partial-failure cleanup.
public protocol AwakePowerRequests: AnyObject {
    func acquire(_ kind: AwakeRequestKind, timeout: TimeInterval) throws -> UInt32
    func release(_ id: UInt32)
}

public final class AwakeSession {
    private let power: AwakePowerRequests
    private var requests: [UInt32] = []
    public private(set) var deadline: TimeInterval?
    public private(set) var keepsDisplayOn = false
    public var isActive: Bool { deadline != nil }

    public init(power: AwakePowerRequests) { self.power = power }
    deinit { requests.forEach { power.release($0) } }

    /// `now` uses a monotonic clock that includes sleep, never wall-clock time.
    /// Replacing a session ends the old one first. Failure leaves the tool idle and retryable.
    public func start(duration: TimeInterval, keepDisplayOn: Bool, now: TimeInterval) throws {
        cancel()
        guard duration.isFinite, duration > 0, now.isFinite else { throw SessionError.invalidDuration }
        do {
            requests.append(try power.acquire(.system, timeout: duration))
            if keepDisplayOn { requests.append(try power.acquire(.display, timeout: duration)) }
            deadline = now + duration
            keepsDisplayOn = keepDisplayOn
        } catch {
            cancel()
            throw error
        }
    }

    /// Changing the display option preserves the deadline, including after a delayed timer.
    public func setDisplayOn(_ enabled: Bool, now: TimeInterval) throws {
        expire(now: now)
        guard let deadline, enabled != keepsDisplayOn else { return }
        try start(duration: deadline - now, keepDisplayOn: enabled, now: now)
    }

    public func remaining(now: TimeInterval) -> TimeInterval {
        guard let deadline else { return 0 }
        return max(0, deadline - now)
    }

    public func expire(now: TimeInterval) {
        if let deadline, now >= deadline { cancel() }
    }

    /// Manual stop, disable, shutdown, and explicit system sleep share the same cleanup.
    public func cancel() {
        requests.forEach { power.release($0) }
        requests.removeAll()
        deadline = nil
        keepsDisplayOn = false
    }

    private enum SessionError: Error { case invalidDuration }
}
