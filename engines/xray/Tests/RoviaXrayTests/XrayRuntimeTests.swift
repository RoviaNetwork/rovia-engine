import Foundation
import XCTest
@testable import RoviaXray

private func okEnvelope() -> String {
    #"{"success":true,"data":{},"error":""}"#
}

private func failEnvelope(_ message: String) -> String {
    #"{"success":false,"data":null,"error":"\#(message)"}"#
}

private final class MockBridge: LibXrayBridge, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var methods: [String] = []
    private(set) var engineRunning = false
    var runXrayDelayNanoseconds: UInt64 = 0
    var refuseTest = false

    func invoke(_ requestJSON: String) throws -> String {
        guard let data = requestJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let envelope = object as? [String: Any],
              let method = envelope["method"] as? String
        else {
            return failEnvelope("bad request")
        }
        lock.lock()
        methods.append(method)
        lock.unlock()
        switch method {
        case "testXray":
            return refuseTest ? failEnvelope("bad config") : okEnvelope()
        case "runXray":
            if runXrayDelayNanoseconds > 0 {
                Thread.sleep(forTimeInterval: Double(runXrayDelayNanoseconds) / 1_000_000_000)
            }
            lock.lock()
            engineRunning = true
            lock.unlock()
            return okEnvelope()
        case "stopXray":
            lock.lock()
            engineRunning = false
            lock.unlock()
            return okEnvelope()
        default:
            return failEnvelope("unknown method")
        }
    }

    func free(_ response: String) {}

    func saw(_ method: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return methods.contains(method)
    }
}

final class XrayRuntimeTests: XCTestCase {
    private let configJSON = Data(#"{"outbounds":[{"password":"__ROVIA_SECRET::sub/cred__"}]}"#.utf8)

    private func runtime(_ bridge: MockBridge) -> XrayRuntime {
        XrayRuntime(
            bridge: bridge,
            secretReader: { key in
                key == "sub/cred" ? Data("11111111-1111-4111-8111-111111111111".utf8) : nil
            },
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        )
    }

    func testEnvelopeCarriesAPIVersion3() throws {
        let encoded = try LibXrayRequest(method: .runXray, payload: ["xrayJson": "{}"]).encoded()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        XCTAssertEqual(object["apiVersion"] as? Int, 3)
        XCTAssertEqual(object["method"] as? String, "runXray")
        let huge = String(repeating: "x", count: LibXrayRequest.maximumBytes)
        XCTAssertThrowsError(try LibXrayRequest(method: .runXray, payload: ["xrayJson": huge]).encoded()) { error in
            XCTAssertEqual(error as? XrayRuntimeError, .requestTooLarge)
        }
        XCTAssertThrowsError(try LibXrayResponse.decode("not json")) { error in
            XCTAssertEqual(error as? XrayRuntimeError, .malformedResponse)
        }
    }

    func testStartResolvesSecretsAndRuns() async throws {
        let bridge = MockBridge()
        let runtime = runtime(bridge)
        try await runtime.start(configJSON: configJSON, tunFD: nil)
        let state = await runtime.state
        XCTAssertEqual(state, .running(since: Date(timeIntervalSince1970: 1_750_000_000)))
        XCTAssertTrue(bridge.saw("testXray"))
        XCTAssertTrue(bridge.saw("runXray"))
    }

    func testMissingSecretFailsWithoutStarting() async {
        let bridge = MockBridge()
        let runtime = XrayRuntime(bridge: bridge, secretReader: { _ in nil })
        do {
            try await runtime.start(configJSON: configJSON, tunFD: nil)
            XCTFail("expected engineRefused")
        } catch let error as XrayRuntimeError {
            XCTAssertEqual(error, .engineRefused("missing secret for sub/cred"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertFalse(bridge.saw("runXray"))
        if case .failed = await runtime.state {} else {
            XCTFail("expected failed state, got \(await runtime.state)")
        }
    }

    func testInvalidConfigNeverReachesRun() async {
        let bridge = MockBridge()
        bridge.refuseTest = true
        let runtime = runtime(bridge)
        do {
            try await runtime.start(configJSON: configJSON, tunFD: nil)
            XCTFail("expected engineRefused")
        } catch let error as XrayRuntimeError {
            XCTAssertEqual(error, .engineRefused("bad config"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertFalse(bridge.saw("runXray"))
    }

    func testDoubleStartIsRejected() async throws {
        let bridge = MockBridge()
        let runtime = runtime(bridge)
        try await runtime.start(configJSON: configJSON, tunFD: nil)
        do {
            try await runtime.start(configJSON: configJSON, tunFD: nil)
            XCTFail("expected alreadyRunning")
        } catch let error as XrayRuntimeError {
            XCTAssertEqual(error, .alreadyRunning)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testStopWhenIdleIsNoop() async throws {
        let bridge = MockBridge()
        let runtime = runtime(bridge)
        try await runtime.stop()
        let idleState = await runtime.state
        XCTAssertEqual(idleState, .idle)
        XCTAssertFalse(bridge.saw("stopXray"))
    }

    func testStopDuringStartLeavesEngineStopped() async throws {
        let bridge = MockBridge()
        bridge.runXrayDelayNanoseconds = 500_000_000
        let runtime = runtime(bridge)
        let starterConfig = configJSON
        let starter = Task { [runtime, starterConfig] in try await runtime.start(configJSON: starterConfig, tunFD: 99) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        try await runtime.stop()
        do {
            try await starter.value
            XCTFail("expected the superseded start to throw")
        } catch let error as XrayRuntimeError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let finalState = await runtime.state
        XCTAssertEqual(finalState, .idle)
        XCTAssertFalse(bridge.engineRunning)
    }
}
