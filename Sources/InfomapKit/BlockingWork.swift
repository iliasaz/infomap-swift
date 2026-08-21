import Foundation

/// The engine's blocking-work executor: one long-lived dedicated thread
/// running C++ calls in FIFO order, keeping them off the Swift cooperative
/// pool.
///
/// One thread, deliberately:
/// - The vendored core routes logging through mutable statics (`utils/Log`),
///   so C++ runs must serialize process-wide anyway; a thread per call would
///   buy nothing but a convoy of blocked threads (16 MiB stack each) parked
///   on a gate.
/// - Foundation's `Thread.start()` discards `pthread_create` failures on
///   Linux — a failed spawn would leave the awaiting continuation suspended
///   forever. A single worker created at first use keeps thread creation off
///   every request path instead of gambling on it per call under load.
///
/// Work is non-cancellable once enqueued: the core offers no cancellation
/// hook, so a job runs to completion even if the awaiting task is cancelled.
/// Callers check cancellation before enqueueing.
final class BlockingWorker: @unchecked Sendable {
    /// `@unchecked Sendable` invariant: `jobs` and `started` are only
    /// accessed while `condition` is held; jobs execute exclusively on the
    /// single worker thread.
    static let shared = BlockingWorker()

    private let condition = NSCondition()
    private var jobs: [() -> Void] = []
    private var started = false

    /// Runs `body` on the worker thread and resumes when it finishes.
    func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            enqueue { continuation.resume(returning: body()) }
        }
    }

    private func enqueue(_ job: @escaping () -> Void) {
        condition.lock()
        if !started {
            started = true
            // Retains self — intended: the singleton and its worker live for
            // the process.
            let thread = Thread { self.workLoop() }
            thread.name = "InfomapKit.engine"
            // The generous stack matters: secondary threads default to
            // 512 KiB on macOS, and the core's tree aggregation recurses
            // per hierarchy level.
            thread.stackSize = 16 << 20
            thread.start()
        }
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }

    private func workLoop() {
        while true {
            condition.lock()
            while jobs.isEmpty { condition.wait() }
            let job = jobs.removeFirst()
            condition.unlock()
            job()
        }
    }
}
