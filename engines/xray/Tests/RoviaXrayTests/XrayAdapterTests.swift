import XCTest
@testable import RoviaConfig
@testable import RoviaEngineAPI
@testable import RoviaXray

final class XrayAdapterTests: XCTestCase {
    func testFoundationAdapterValidatesCompilableConfigurations() async throws {
        let adapter = XrayAdapter()
        let valid = CanonicalTunnelConfiguration(
            schemaVersion: 1,
            appConfig: AppConfig(
                schemaVersion: 1,
                subscriptions: [],
                groups: [],
                routing: RouteSet(rules: [], defaultAction: .direct),
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
        let report = try await adapter.validate(valid)
        XCTAssertTrue(report.valid)

        let empty = CanonicalTunnelConfiguration(
            schemaVersion: 1,
            appConfig: AppConfig(
                schemaVersion: 1,
                subscriptions: [],
                groups: [],
                routing: RouteSet(rules: [], defaultAction: .direct),
                dns: DNSPolicy(mode: .system),
                privacy: PrivacyPolicy()
            )
        )
        do {
            _ = try await adapter.validate(empty)
            XCTFail("Expected validation to reject a server-less configuration")
        } catch let error as EngineError {
            XCTAssertEqual(error, .invalidConfiguration("no servers to compile"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAdapterStatusIsUnavailable() async {
        let status = await XrayAdapter().status()

        XCTAssertEqual(status, .unavailable)
    }
}
