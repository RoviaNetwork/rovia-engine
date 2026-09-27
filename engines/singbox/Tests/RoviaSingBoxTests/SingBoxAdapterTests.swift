import XCTest
@testable import RoviaConfig
@testable import RoviaEngineAPI
@testable import RoviaSingBox

final class SingBoxAdapterTests: XCTestCase {
    func testFoundationAdapterIsExplicitlyUnavailable() async {
        let adapter = SingBoxAdapter()

        let status = await adapter.status()
        XCTAssertEqual(status, .unavailable)
        do {
            _ = try await adapter.prepare(CanonicalTunnelConfiguration.fixture)
            XCTFail("Expected the unavailable adapter to reject preparation")
        } catch let error as EngineError {
            XCTAssertEqual(error, .notIncludedInBuild("sing-box"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private extension CanonicalTunnelConfiguration {
    static var fixture: CanonicalTunnelConfiguration {
        CanonicalTunnelConfiguration(
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
    }
}
