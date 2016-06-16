import Foundation

#if _runtime(_ObjC)
import Dispatch

private let timeoutLeeway = DispatchTimeInterval.nanoseconds(Int(NSEC_PER_MSEC))
private let pollLeeway = DispatchTimeInterval.nanoseconds(Int(NSEC_PER_MSEC))

/// Stores debugging information about callers
internal struct WaitingInfo: CustomStringConvertible {
    let name: String
    let file: FileString
    let lineNumber: UInt

    var description: String {
        return "\(name) at \(file):\(lineNumber)"
    }
}

internal protocol WaitLock {
    func acquireWaitingLock(_ fnName: String, file: FileString, line: UInt)
    func releaseWaitingLock()
    func isWaitingLocked() -> Bool
}

internal class AssertionWaitLock: WaitLock {
    private var currentWaiter: WaitingInfo? = nil
    init() { }

    func acquireWaitingLock(_ fnName: String, file: FileString, line: UInt) {
        let info = WaitingInfo(name: fnName, file: file, lineNumber: line)
        nimblePrecondition(
            Thread.isMainThread(),
            "InvalidNimbleAPIUsage",
            "\(fnName) can only run on the main thread."
        )
        nimblePrecondition(
            currentWaiter == nil,
            "InvalidNimbleAPIUsage",
            "Nested async expectations are not allowed to avoid creating flaky tests.\n\n" +
            "The call to\n\t\(info)\n" +
            "triggered this exception because\n\t\(currentWaiter!)\n" +
            "is currently managing the main run loop."
        )
        currentWaiter = info
    }

    func isWaitingLocked() -> Bool {
        return currentWaiter != nil
    }

    func releaseWaitingLock() {
        currentWaiter = nil
    }
}

internal enum AwaitResult<T> {
    /// Incomplete indicates None (aka - this value hasn't been fulfilled yet)
    case Incomplete
    /// TimedOut indicates the result reached its defined timeout limit before returning
    case TimedOut
    /// BlockedRunLoop indicates the main runloop is too busy processing other blocks to trigger
    /// the timeout code.
    ///
    /// This may also mean the async code waiting upon may have never actually ran within the
    /// required time because other timers & sources are running on the main run loop.
    case BlockedRunLoop
    /// The async block successfully executed and returned a given result
    case Completed(T)
    /// When a Swift Error is thrown
    case ErrorThrown(ErrorProtocol)
    /// When an Objective-C Exception is raised
    case RaisedException(NSException)

    func isIncomplete() -> Bool {
        switch self {
        case .Incomplete: return true
        default: return false
        }
    }

    func isCompleted() -> Bool {
        switch self {
        case .Completed(_): return true
        default: return false
        }
    }
}

/// Holds the resulting value from an asynchronous expectation.
/// This class is thread-safe at receiving an "response" to this promise.
internal class AwaitPromise<T> {
    private(set) internal var asyncResult: AwaitResult<T> = .Incomplete
    private var signal: DispatchSemaphore

    init() {
        signal = DispatchSemaphore(value: 1)
    }

    /// Resolves the promise with the given result if it has not been resolved. Repeated calls to
    /// this method will resolve in a no-op.
    ///
    /// @returns a Bool that indicates if the async result was accepted or rejected because another
    ///          value was recieved first.
    func resolveResult(_ result: AwaitResult<T>) -> Bool {
        if signal.wait(timeout: .now()) == .Success {
            self.asyncResult = result
            return true
        } else {
            return false
        }
    }
}

internal struct AwaitTrigger {
    let timeoutSource: DispatchSourceTimer
    let actionSource: DispatchSourceTimer?
    let start: () throws -> Void
}

/// Factory for building fully configured AwaitPromises and waiting for their results.
///
/// This factory stores all the state for an async expectation so that Await doesn't
/// doesn't have to manage it.
internal class AwaitPromiseBuilder<T> {
    let awaiter: Awaiter
    let waitLock: WaitLock
    let trigger: AwaitTrigger
    let promise: AwaitPromise<T>

    internal init(
        awaiter: Awaiter,
        waitLock: WaitLock,
        promise: AwaitPromise<T>,
        trigger: AwaitTrigger) {
            self.awaiter = awaiter
            self.waitLock = waitLock
            self.promise = promise
            self.trigger = trigger
    }

    func timeout(_ timeoutInterval: TimeInterval, forcefullyAbortTimeout: TimeInterval) -> Self {
        // = Discussion =
        //
        // There's a lot of technical decisions here that is useful to elaborate on. This is
        // definitely more lower-level than the previous NSRunLoop based implementation.
        //
        //
        // Why Dispatch Source?
        //
        //
        // We're using a dispatch source to have better control of the run loop behavior.
        // A timer source gives us deferred-timing control without having to rely as much on
        // a run loop's traditional dispatching machinery (eg - NSTimers, DefaultRunLoopMode, etc.)
        // which is ripe for getting corrupted by application code.
        //
        // And unlike dispatch_async(), we can control how likely our code gets prioritized to
        // executed (see leeway parameter) + DISPATCH_TIMER_STRICT.
        //
        // This timer is assumed to run on the HIGH priority queue to ensure it maintains the
        // highest priority over normal application / test code when possible.
        //
        //
        // Run Loop Management
        //
        // In order to properly interrupt the waiting behavior performed by this factory class,
        // this timer stops the main run loop to tell the waiter code that the result should be
        // checked.
        //
        // In addition, stopping the run loop is used to halt code executed on the main run loop.
        trigger.timeoutSource.scheduleOneshot(
            deadline: DispatchTime.now() + timeoutInterval,
            leeway: timeoutLeeway)
        trigger.timeoutSource.setEventHandler() {
            guard self.promise.asyncResult.isIncomplete() else { return }
            let timedOutSem = DispatchSemaphore(value: 0)
            let semTimedOutOrBlocked = DispatchSemaphore(value: 0)
            semTimedOutOrBlocked.signal()
            let runLoop = CFRunLoopGetMain()
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
                if semTimedOutOrBlocked.wait(timeout: .now()) == .Success {
                    timedOutSem.signal()
                    semTimedOutOrBlocked.signal()
                    if self.promise.resolveResult(.TimedOut) {
                        CFRunLoopStop(CFRunLoopGetMain())
                    }
                }
            }
            // potentially interrupt blocking code on run loop to let timeout code run
            CFRunLoopStop(runLoop)
            let now = DispatchTime.now() + forcefullyAbortTimeout
            let didNotTimeOut = timedOutSem.wait(timeout: now) != .Success
            let timeoutWasNotTriggered = semTimedOutOrBlocked.wait(timeout: .now()) == .Success
            if didNotTimeOut && timeoutWasNotTriggered {
                if self.promise.resolveResult(.BlockedRunLoop) {
                    CFRunLoopStop(CFRunLoopGetMain())
                }
            }
        }
        return self
    }

    /// Blocks for an asynchronous result.
    ///
    /// @discussion
    /// This function must be executed on the main thread and cannot be nested. This is because
    /// this function (and it's related methods) coordinate through the main run loop. Tampering
    /// with the run loop can cause undesireable behavior.
    ///
    /// This method will return an AwaitResult in the following cases:
    ///
    /// - The main run loop is blocked by other operations and the async expectation cannot be
    ///   be stopped.
    /// - The async expectation timed out
    /// - The async expectation succeeded
    /// - The async expectation raised an unexpected exception (objc)
    /// - The async expectation raised an unexpected error (swift)
    ///
    /// The returned AwaitResult will NEVER be .Incomplete.
    func wait(_ fnName: String = #function, file: FileString = #file, line: UInt = #line) -> AwaitResult<T> {
        waitLock.acquireWaitingLock(
            fnName,
            file: file,
            line: line)

        let capture = NMBExceptionCapture(handler: ({ exception in
            self.promise.resolveResult(.RaisedException(exception))
        }), finally: ({
            self.waitLock.releaseWaitingLock()
        }))
        capture.tryBlock {
            do {
                try self.trigger.start()
            } catch let error {
                self.promise.resolveResult(.ErrorThrown(error))
            }
            self.trigger.timeoutSource.resume()
            while self.promise.asyncResult.isIncomplete() {
                // Stopping the run loop does not work unless we run only 1 mode
                RunLoop.current().run(mode: .defaultRunLoopMode, before: .distantFuture)
            }
            self.trigger.timeoutSource.suspend()
            self.trigger.timeoutSource.cancel()
            if let asyncSource = self.trigger.actionSource {
                asyncSource.cancel()
            }
        }

        return promise.asyncResult
    }
}

internal class Awaiter {
    let waitLock: WaitLock
    let timeoutQueue: DispatchQueue
    let asyncQueue: DispatchQueue

    internal init(
        waitLock: WaitLock,
        asyncQueue: DispatchQueue,
        timeoutQueue: DispatchQueue) {
            self.waitLock = waitLock
            self.asyncQueue = asyncQueue
            self.timeoutQueue = timeoutQueue
    }

    private func createTimerSource(_ queue: DispatchQueue) -> DispatchSourceTimer {
        return DispatchSource.timer(flags: .strict, queue: queue)
    }

    func performBlock<T>(
        _ closure: ((T) -> Void) throws -> Void) -> AwaitPromiseBuilder<T> {
            let promise = AwaitPromise<T>()
            let timeoutSource = createTimerSource(timeoutQueue)
            var completionCount = 0
            let trigger = AwaitTrigger(timeoutSource: timeoutSource, actionSource: nil) {
                try closure() {
                    completionCount += 1
                    nimblePrecondition(
                        completionCount < 2,
                        "InvalidNimbleAPIUsage",
                        "Done closure's was called multiple times. waitUntil(..) expects its " +
                        "completion closure to only be called once.")
                    if promise.resolveResult(.Completed($0)) {
                        CFRunLoopStop(CFRunLoopGetMain())
                    }
                }
            }

            return AwaitPromiseBuilder(
                awaiter: self,
                waitLock: waitLock,
                promise: promise,
                trigger: trigger)
    }

    func poll<T>(_ pollInterval: TimeInterval, closure: () throws -> T?) -> AwaitPromiseBuilder<T> {
        let promise = AwaitPromise<T>()
        let timeoutSource = createTimerSource(timeoutQueue)
        let asyncSource = createTimerSource(asyncQueue)
        let trigger = AwaitTrigger(timeoutSource: timeoutSource, actionSource: asyncSource) {
            let interval = DispatchTimeInterval.nanoseconds(Int(pollInterval * TimeInterval(NSEC_PER_SEC)))
            asyncSource.scheduleRepeating(deadline: .now(), interval: interval, leeway: pollLeeway)
            asyncSource.setEventHandler() {
                do {
                    if let result = try closure() {
                        if promise.resolveResult(.Completed(result)) {
                            CFRunLoopStop(CFRunLoopGetCurrent())
                        }
                    }
                } catch let error {
                    if promise.resolveResult(.ErrorThrown(error)) {
                        CFRunLoopStop(CFRunLoopGetCurrent())
                    }
                }
            }
            asyncSource.resume()
        }

        return AwaitPromiseBuilder(
            awaiter: self,
            waitLock: waitLock,
            promise: promise,
            trigger: trigger)
    }
}

internal func pollBlock(
    pollInterval: TimeInterval,
    timeoutInterval: TimeInterval,
    file: FileString,
    line: UInt,
    fnName: String = #function,
    expression: () throws -> Bool) -> AwaitResult<Bool> {
        let awaiter = NimbleEnvironment.activeInstance.awaiter
        let result = awaiter.poll(pollInterval) { () throws -> Bool? in
            do {
                if try expression() {
                    return true
                }
                return nil
            } catch let error {
                throw error
            }
        }.timeout(timeoutInterval, forcefullyAbortTimeout: timeoutInterval / 2.0).wait(fnName, file: file, line: line)

        return result
}

#endif
