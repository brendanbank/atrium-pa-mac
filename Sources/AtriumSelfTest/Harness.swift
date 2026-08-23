import Foundation

/// A test harness in eighty lines, because this machine has no test
/// framework.
///
/// The Command Line Tools ship neither XCTest nor swift-testing — both
/// come with Xcode — so `swift test` cannot run here at all. Rather than
/// make a 10 GB IDE install a prerequisite for checking that the upload
/// lane works, the tests are an ordinary executable: `make test`.
///
/// The trade is real and worth stating. There is no test discovery, no
/// parallelism, no XCTest reporting, and no CI integration beyond an
/// exit code. What there is: the tests run, they run everywhere, and the
/// live ones can be pointed at a real Atrium PA deployment from a shell.
final class Harness {

    struct Failure: Error, CustomStringConvertible {
        let message: String
        let file: String
        let line: Int
        var description: String {
            "\(message)  (\((file as NSString).lastPathComponent):\(line))"
        }
    }

    private var passed = 0
    private var failed = 0
    private var skipped = 0
    private var currentGroup = ""

    func group(_ name: String) {
        currentGroup = name
        print("\n\u{001B}[1m\(name)\u{001B}[0m")
    }

    func test(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            passed += 1
            print("  \u{001B}[32m✓\u{001B}[0m \(name)")
        } catch let failure as Failure {
            failed += 1
            print("  \u{001B}[31m✗\u{001B}[0m \(name)")
            print("      \(failure.description)")
        } catch {
            failed += 1
            print("  \u{001B}[31m✗\u{001B}[0m \(name)")
            print("      threw: \(error)")
        }
    }

    func asyncTest(_ name: String, _ body: @escaping () async throws -> Void) {
        let semaphore = DispatchSemaphore(value: 0)
        var thrown: Error?
        Task {
            do { try await body() } catch { thrown = error }
            semaphore.signal()
        }
        semaphore.wait()
        if let thrown {
            failed += 1
            print("  \u{001B}[31m✗\u{001B}[0m \(name)")
            print("      \(thrown)")
        } else {
            passed += 1
            print("  \u{001B}[32m✓\u{001B}[0m \(name)")
        }
    }

    func skip(_ name: String, why: String) {
        skipped += 1
        print("  \u{001B}[33m-\u{001B}[0m \(name) — \(why)")
    }

    func note(_ message: String) {
        print("      \u{001B}[2m\(message)\u{001B}[0m")
    }

    /// Print the tally and return the process exit code.
    func summarise() -> Int32 {
        print("")
        let verdict = failed == 0 ? "\u{001B}[32mPASS\u{001B}[0m" : "\u{001B}[31mFAIL\u{001B}[0m"
        print(
            "\(verdict)  \(passed) passed, \(failed) failed"
                + (skipped > 0 ? ", \(skipped) skipped" : ""))
        return failed == 0 ? 0 : 1
    }
}

// MARK: - Assertions

func expect(
    _ condition: Bool, _ message: @autoclosure () -> String,
    file: String = #file, line: Int = #line
) throws {
    guard condition else {
        throw Harness.Failure(message: message(), file: file, line: line)
    }
}

func expectEqual<T: Equatable>(
    _ actual: T, _ wanted: T, _ label: String = "",
    file: String = #file, line: Int = #line
) throws {
    guard actual == wanted else {
        let prefix = label.isEmpty ? "" : "\(label): "
        throw Harness.Failure(
            message: "\(prefix)got \(actual), wanted \(wanted)", file: file, line: line)
    }
}

func expectNear(
    _ actual: Double, _ wanted: Double, tolerance: Double, _ label: String = "",
    file: String = #file, line: Int = #line
) throws {
    guard abs(actual - wanted) <= tolerance else {
        let prefix = label.isEmpty ? "" : "\(label): "
        throw Harness.Failure(
            message: "\(prefix)got \(actual), wanted \(wanted) ± \(tolerance)",
            file: file, line: line)
    }
}

/// Wait for a condition that another thread will make true. The session
/// controller is queue-based and calls back asynchronously, so almost
/// every assertion about it needs this.
func waitUntil(
    _ timeout: TimeInterval = 5, _ condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}
