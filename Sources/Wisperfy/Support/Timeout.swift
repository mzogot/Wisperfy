import Foundation
import Synchronization

/// Waits for `operation` but gives up after `seconds`.
///
/// If the operation ignores cancellation it keeps running in the background; the caller
/// simply stops waiting. Used around speech-engine calls that have been observed to
/// never return when fed almost no audio.
///
/// - Returns: true if the operation completed in time, false on timeout.
@discardableResult
func awaitWithTimeout(
    _ seconds: Double,
    _ operation: @escaping @Sendable () async -> Void
) async -> Bool {
    await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        let once = Once(continuation)
        Task {
            await operation()
            once.resume(true)
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            once.resume(false)
        }
    }
}

/// Like `awaitWithTimeout` but returns the operation's value, or nil on timeout.
func valueWithTimeout<T: Sendable>(
    _ seconds: Double,
    _ operation: @escaping @Sendable () async -> T
) async -> T? {
    let box = Mutex<T?>(nil)
    let finished = await awaitWithTimeout(seconds) {
        let value = await operation()
        box.withLock { $0 = value }
    }
    return finished ? box.withLock { $0 } : nil
}

/// Resumes a continuation at most once, whichever racer arrives first.
private final class Once: Sendable {
    private let slot: Mutex<CheckedContinuation<Bool, Never>?>

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        slot = Mutex(continuation)
    }

    func resume(_ value: Bool) {
        let taken = slot.withLock { stored -> CheckedContinuation<Bool, Never>? in
            defer { stored = nil }
            return stored
        }
        taken?.resume(returning: value)
    }
}

extension Duration {
    /// Whole seconds plus the fractional part, for logging and history.
    var inSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
