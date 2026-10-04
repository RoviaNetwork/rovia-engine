import Foundation
import XCTest
@testable import RoviaConfig
@testable import RoviaEngineAPI
@testable import RoviaXray

/// The live adapter, over a scripted bridge. These tests pin the wiring, not
/// the engine: the artifact's own proof is the pinned build plus the
/// packet-flow spike on hardware.
final class XrayLiveAdapterTests: XCTestCase {
    private final class ScriptingBridge: LibXrayBridge, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var methods: [String] = []
        private(set) var lastRunPayload: String = ""
        var engineRunning = false

        func invoke(_ requestJSON: String) throws -> String {
            guard let data = requestJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let envelope = object as? [String: Any],
                  let method = envelope["method"] as? String
            else {
                return #"{"success":false,"data":null,"error":"bad request"}"#
            }
            lock.lock()
            methods.append(method)
            lock.unlock()
            switch method {
            case "xrayVersion":
                return #"{"success":true,"data":{"version":"Xray 26.9.9"},"error":""}"#
            case "testXray":
                return #"{"success":true,"data":{},"error":""}"#
            case "runXray":
                lock.lock()
                engineRunning = true
                if let payload = envelope["payload"] as? [String: Any],
                   let json = payload["xrayJson"] as? String {
                    lastRunPayload = json
                }
                lock.unlock()
                return #"{"success":true,"data":{},"error":""}"#
            case "stopXray":
                lock.lock()
                engineRunning = false
                lock.unlock()
                return #"{"success":true,"data":{},"error":""}"#
            default:
                return #"{"success":false,"data":null,"error":"unknown method"}"#
            }
        }

        func free(_ response: String) {}
    }

    private final class NullPacketBridge: PacketBridge, @unchecked Sendable {
        func read() async throws -> [EnginePacket] {
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
            return []
        }

        func write(_ packets: [EnginePacket]) async throws {}
    }

    private func configuration() -> CanonicalTunnelConfiguration {
        CanonicalTunnelConfiguration(
            schemaVersion: 1,
            appConfig: AppConfig(
                schemaVersion: 1,
                subscriptions: [],
                groups: [],
                routing: RouteSet(rules: [], defaultAction: .group(UUID())),
                dns: DNSPolicy(mode: .system),
                privacy: PrivacyPolicy(),
                servers: [
                    Server(
                        id: UUID(),
                        name: "VLESS server",
                        protocolKind: .vless,
                        endpoint: Endpoint(host: "synthetic.example", port: 443),
                        credential: SecretReference(key: "subscription/test/vless"),
                        transport: TransportOptions(kind: "tcp"),
                        tls: TLSOptions(serverName: "synthetic.example"),
                        tags: []
                    )
                ]
            )
        )
    }

    func testLiveAdapterReportsTheEnginesVersion() async {
        let adapter = XrayAdapter(bridge: ScriptingBridge(), secretReader: { _ in nil })
        XCTAssertEqual(adapter.descriptor.version, "Xray 26.9.9")
        let capabilities = await adapter.capabilities()
        XCTAssertTrue(capabilities.supportsTunnel)
        XCTAssertEqual(capabilities.supportedProtocols, [.vless, .trojan, .shadowsocks])
    }

    func testUnavailableAdapterRefusesPrepareAndStart() async {
        let adapter = XrayAdapter()
        do {
            _ = try await adapter.prepare(configuration())
            XCTFail("the foundation adapter must refuse prepare")
        } catch let error as EngineError {
            XCTAssertEqual(error, .notIncludedInBuild("xray"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        await adapter.stop()
        let status = await adapter.status()
        XCTAssertEqual(status, .unavailable)
    }

    func testLiveAdapterPrepareCompilesAndStartRunsTheRuntime() async throws {
        let bridge = ScriptingBridge()
        let adapter = XrayAdapter(
            bridge: bridge,
            secretReader: { key in
                key == "subscription/test/vless"
                    ? Data("11111111-1111-4111-8111-111111111111".utf8)
                    : nil
            }
        )
        let prepared = try await adapter.prepare(configuration())
        XCTAssertEqual(prepared.engineID, "xray")
        // Secrets are placeholders in the compiled payload, never credentials.
        XCTAssertFalse(prepared.opaquePayload.isEmpty)
        XCTAssertNil(
            String(data: prepared.opaquePayload, encoding: .utf8)?
                .range(of: "11111111-1111-4111-8111-111111111111")
        )

        let context = TunnelRuntimeContext(
            sessionID: UUID(),
            platform: "ios",
            preparedConfiguration: prepared,
            packetBridge: NullPacketBridge()
        )
        try await adapter.start(context)
        var status = await adapter.status()
        XCTAssertEqual(status, .running)
        // The tun fd is injected into the engine's environment, and the
        // placeholder was resolved through the secret reader.
        XCTAssertTrue(bridge.lastRunPayload.contains("xray.tun.fd"))
        XCTAssertTrue(bridge.lastRunPayload.contains("11111111-1111-4111-8111-111111111111"))

        await adapter.stop()
        status = await adapter.status()
        XCTAssertEqual(status, .idle)
        XCTAssertFalse(bridge.engineRunning)
    }
}
