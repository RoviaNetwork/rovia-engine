import XCTest
@testable import RoviaConfig
@testable import RoviaEngineAPI
@testable import RoviaXray

final class XrayAdapterTests: XCTestCase {
    func testFoundationAdapterReportsThatEngineIsNotIncluded() async {
        let adapter = XrayAdapter()
        let configuration = CanonicalTunnelConfiguration(
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
            _ = try await adapter.validate(configuration)
            XCTFail("Expected the unavailable adapter to reject validation")
        } catch let error as EngineError {
            XCTAssertEqual(error, .notIncludedInBuild("xray"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAdapterStatusIsUnavailable() async {
        let status = await XrayAdapter().status()

        XCTAssertEqual(status, .unavailable)
    }
}
