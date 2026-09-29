import Foundation
import XCTest
@testable import RoviaConfig
@testable import RoviaEngineAPI
@testable import RoviaXray

final class XrayConfigCompilerTests: XCTestCase {
    private func configuration(servers: [Server]) -> CanonicalTunnelConfiguration {
        CanonicalTunnelConfiguration(
            schemaVersion: 1,
            appConfig: AppConfig(
                schemaVersion: 1,
                subscriptions: [],
                groups: [],
                routing: RouteSet(rules: [], defaultAction: .direct),
                dns: DNSPolicy(mode: .system),
                privacy: PrivacyPolicy(),
                servers: servers
            )
        )
    }

    private func vlessServer() -> Server {
        Server(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
            name: "VLESS server",
            protocolKind: .vless,
            endpoint: Endpoint(host: "synthetic.example", port: 443),
            credential: SecretReference(key: "subscription/test/vless"),
            transport: TransportOptions(kind: "ws", options: ["host": "synthetic.example", "path": "/ws"]),
            tls: TLSOptions(serverName: "synthetic.example"),
            tags: ["share-link", "vless"]
        )
    }

    private func compiled(_ servers: [Server]) throws -> [String: Any] {
        let data = try XrayConfigCompiler().compile(configuration(servers: servers))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testCompilesVLESSWithStreamSettings() throws {
        let json = try compiled([vlessServer()])
        let outbounds = try XCTUnwrap(json["outbounds"] as? [[String: Any]])
        XCTAssertEqual(outbounds[0]["protocol"] as? String, "vless")
        XCTAssertEqual(outbounds[0]["tag"] as? String, "proxy-0")
        let stream = try XCTUnwrap(outbounds[0]["streamSettings"] as? [String: Any])
        XCTAssertEqual(stream["network"] as? String, "ws")
        XCTAssertEqual(stream["security"] as? String, "tls")
        let ws = try XCTUnwrap(stream["wsSettings"] as? [String: Any])
        XCTAssertEqual(ws["path"] as? String, "/ws")
        let rules = try XCTUnwrap((json["routing"] as? [String: Any])?["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.last?["outboundTag"] as? String, "direct")
    }

    func testSecretsBecomePlaceholdersNeverMaterial() throws {
        let trojan = Server(
            id: UUID(),
            name: "Trojan server",
            protocolKind: .trojan,
            endpoint: Endpoint(host: "synthetic.example", port: 443),
            credential: SecretReference(key: "subscription/test/trojan"),
            transport: TransportOptions(kind: "tcp"),
            tls: TLSOptions(serverName: "synthetic.example"),
            tags: []
        )
        let data = try XrayConfigCompiler().compile(configuration(servers: [trojan]))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("Trojan-Password"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let outbounds = try XCTUnwrap(json["outbounds"] as? [[String: Any]])
        let servers = try XCTUnwrap((outbounds[0]["settings"] as? [String: Any])?["servers"] as? [[String: Any]])
        XCTAssertEqual(
            servers[0]["password"] as? String,
            XrayConfigCompiler.placeholder(forKey: "subscription/test/trojan")
        )
    }

    func testCompilesRealitySettings() throws {
        let server = Server(
            id: UUID(),
            name: "VLESS server",
            protocolKind: .vless,
            endpoint: Endpoint(host: "synthetic.example", port: 443),
            credential: SecretReference(key: "subscription/test/reality"),
            transport: TransportOptions(kind: "tcp", options: [
                "realityPublicKey": String(repeating: "A", count: 43),
                "fingerprint": "chrome",
                "flow": "xtls-rprx-vision",
            ]),
            tls: TLSOptions(serverName: "synthetic.example"),
            tags: []
        )
        let json = try compiled([server])
        let outbounds = try XCTUnwrap(json["outbounds"] as? [[String: Any]])
        let stream = try XCTUnwrap(outbounds[0]["streamSettings"] as? [String: Any])
        XCTAssertEqual(stream["security"] as? String, "reality")
        let reality = try XCTUnwrap(stream["realitySettings"] as? [String: Any])
        XCTAssertEqual((reality["publicKey"] as? String)?.count, 43)
        XCTAssertEqual(reality["fingerprint"] as? String, "chrome")
    }

    func testCompilesShadowsocksWithMethod() throws {
        let server = Server(
            id: UUID(),
            name: "Shadowsocks server",
            protocolKind: .shadowsocks,
            endpoint: Endpoint(host: "synthetic.example", port: 8388),
            credential: SecretReference(key: "subscription/test/ss"),
            transport: TransportOptions(kind: "tcp", options: ["method": "aes-256-gcm"]),
            tls: nil,
            tags: []
        )
        let json = try compiled([server])
        let outbounds = try XCTUnwrap(json["outbounds"] as? [[String: Any]])
        XCTAssertEqual(outbounds[0]["protocol"] as? String, "shadowsocks")
        let servers = try XCTUnwrap((outbounds[0]["settings"] as? [String: Any])?["servers"] as? [[String: Any]])
        XCTAssertEqual(servers[0]["method"] as? String, "aes-256-gcm")
    }

    func testRefusesVMessEmptyServersAndMissingCredentials() {
        let vmess = Server(
            id: UUID(),
            name: "VMess server",
            protocolKind: .vmess,
            endpoint: Endpoint(host: "synthetic.example", port: 443),
            credential: SecretReference(key: "subscription/test/vmess"),
            transport: TransportOptions(kind: "tcp"),
            tls: nil,
            tags: []
        )
        XCTAssertThrowsError(try XrayConfigCompiler().compile(configuration(servers: [vmess])))
        XCTAssertThrowsError(try XrayConfigCompiler().compile(configuration(servers: [])))
        let noCredential = Server(
            id: UUID(),
            name: "VLESS server",
            protocolKind: .vless,
            endpoint: Endpoint(host: "synthetic.example", port: 443),
            credential: nil,
            transport: TransportOptions(kind: "tcp"),
            tls: TLSOptions(serverName: "synthetic.example"),
            tags: []
        )
        XCTAssertThrowsError(try XrayConfigCompiler().compile(configuration(servers: [noCredential])))
    }

    func testCompilationIsDeterministic() throws {
        let first = try XrayConfigCompiler().compile(configuration(servers: [vlessServer()]))
        let second = try XrayConfigCompiler().compile(configuration(servers: [vlessServer()]))
        XCTAssertEqual(first, second)
    }
}

final class XraySecretSubstitutorTests: XCTestCase {
    private func trojanConfig() throws -> Data {
        let trojan = Server(
            id: UUID(),
            name: "Trojan server",
            protocolKind: .trojan,
            endpoint: Endpoint(host: "synthetic.example", port: 443),
            credential: SecretReference(key: "subscription/test/trojan"),
            transport: TransportOptions(kind: "tcp"),
            tls: TLSOptions(serverName: "synthetic.example"),
            tags: []
        )
        let config = CanonicalTunnelConfiguration(
            schemaVersion: 1,
            appConfig: AppConfig(
                schemaVersion: 1,
                subscriptions: [],
                groups: [],
                routing: RouteSet(rules: [], defaultAction: .direct),
                dns: DNSPolicy(mode: .system),
                privacy: PrivacyPolicy(),
                servers: [trojan]
            )
        )
        return try XrayConfigCompiler().compile(config)
    }

    func testCollectsKeysAndSubstitutes() throws {
        let compiled = try trojanConfig()
        XCTAssertEqual(try XraySecretSubstitutor.secretKeys(in: compiled), ["subscription/test/trojan"])
        let substituted = try XraySecretSubstitutor.substituting(
            ["subscription/test/trojan": Data("real-password".utf8)],
            in: compiled
        )
        XCTAssertTrue(try XraySecretSubstitutor.secretKeys(in: substituted).isEmpty)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: substituted) as? [String: Any])
        let outbounds = try XCTUnwrap(json["outbounds"] as? [[String: Any]])
        let servers = try XCTUnwrap((outbounds[0]["settings"] as? [String: Any])?["servers"] as? [[String: Any]])
        XCTAssertEqual(servers[0]["password"] as? String, "real-password")
    }

    func testUnknownKeyAndNonUTF8SecretThrow() throws {
        let compiled = try trojanConfig()
        XCTAssertThrowsError(
            try XraySecretSubstitutor.substituting([:], in: compiled)
        ) { error in
            XCTAssertEqual(error as? XraySecretSubstitutionError, .unknownKey("subscription/test/trojan"))
        }
        XCTAssertThrowsError(
            try XraySecretSubstitutor.substituting(
                ["subscription/test/trojan": Data([0xC3, 0x28])],
                in: compiled
            )
        ) { error in
            XCTAssertEqual(error as? XraySecretSubstitutionError, .secretNotUTF8("subscription/test/trojan"))
        }
        XCTAssertThrowsError(try XraySecretSubstitutor.secretKeys(in: Data("not json".utf8))) { error in
            XCTAssertEqual(error as? XraySecretSubstitutionError, .invalidJSON)
        }
    }

    func testSubstitutionIsDeterministic() throws {
        let compiled = try trojanConfig()
        let secrets = ["subscription/test/trojan": Data("real-password".utf8)]
        XCTAssertEqual(
            try XraySecretSubstitutor.substituting(secrets, in: compiled),
            try XraySecretSubstitutor.substituting(secrets, in: compiled)
        )
    }
}

final class XrayRealShapeTests: XCTestCase {
    private func vlessTCP() -> Server {
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
    }

    private func config(_ servers: [Server]) -> CanonicalTunnelConfiguration {
        CanonicalTunnelConfiguration(
            schemaVersion: 1,
            appConfig: AppConfig(
                schemaVersion: 1, subscriptions: [], groups: [],
                routing: RouteSet(rules: [], defaultAction: .direct),
                dns: DNSPolicy(mode: .system), privacy: PrivacyPolicy(), servers: servers
            )
        )
    }

    private func compiledJSON(_ servers: [Server]) throws -> [String: Any] {
        let data = try XrayConfigCompiler().compile(config(servers))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testDirectOutboundUsesFreedom() throws {
        let json = try compiledJSON([vlessTCP()])
        let outbounds = try XCTUnwrap(json["outbounds"] as? [[String: Any]])
        let direct = try XCTUnwrap(outbounds.first { $0["tag"] as? String == "direct" })
        XCTAssertEqual(direct["protocol"] as? String, "freedom")
    }

    func testBlockOutboundHasResponseType() throws {
        let json = try compiledJSON([vlessTCP()])
        let outbounds = try XCTUnwrap(json["outbounds"] as? [[String: Any]])
        let block = try XCTUnwrap(outbounds.first { $0["tag"] as? String == "block" })
        XCTAssertEqual(block["protocol"] as? String, "blackhole")
        let settings = try XCTUnwrap(block["settings"] as? [String: Any])
        XCTAssertEqual((settings["response"] as? [String: Any])?["type"] as? String, "none")
    }

    func testSocksInboundListenAndPortAreTopLevel() throws {
        let json = try compiledJSON([vlessTCP()])
        let inbounds = try XCTUnwrap(json["inbounds"] as? [[String: Any]])
        let socks = try XCTUnwrap(inbounds.first { $0["tag"] as? String == "socks-in" })
        XCTAssertEqual(socks["listen"] as? String, "127.0.0.1")
        XCTAssertEqual(socks["port"] as? Int, 10808)
        let settings = try XCTUnwrap(socks["settings"] as? [String: Any])
        XCTAssertNil(settings["port"])
        XCTAssertNil(settings["listen"])
    }

    func testHTTPUpgradeUsesItsOwnSettingsBlock() throws {
        let server = Server(
            id: UUID(), name: "VLESS server", protocolKind: .vless,
            endpoint: Endpoint(host: "synthetic.example", port: 443),
            credential: SecretReference(key: "test/hu"),
            transport: TransportOptions(kind: "httpupgrade", options: ["host": "synthetic.example", "path": "/up"]),
            tls: TLSOptions(serverName: "synthetic.example"), tags: []
        )
        let json = try compiledJSON([server])
        let outbounds = try XCTUnwrap(json["outbounds"] as? [[String: Any]])
        let stream = try XCTUnwrap(outbounds[0]["streamSettings"] as? [String: Any])
        XCTAssertEqual(stream["network"] as? String, "httpupgrade")
        XCTAssertNotNil(stream["httpupgradeSettings"])
        XCTAssertNil(stream["httpSettings"])
    }

    func testGRPCModeMapsToMultiMode() throws {
        let server = Server(
            id: UUID(), name: "VLESS server", protocolKind: .vless,
            endpoint: Endpoint(host: "synthetic.example", port: 443),
            credential: SecretReference(key: "test/grpc"),
            transport: TransportOptions(kind: "grpc", options: ["serviceName": "svc", "mode": "multi"]),
            tls: TLSOptions(serverName: "synthetic.example"), tags: []
        )
        let json = try compiledJSON([server])
        let outbounds = try XCTUnwrap(json["outbounds"] as? [[String: Any]])
        let stream = try XCTUnwrap(outbounds[0]["streamSettings"] as? [String: Any])
        let grpc = try XCTUnwrap(stream["grpcSettings"] as? [String: Any])
        XCTAssertEqual(grpc["multiMode"] as? Bool, true)
        XCTAssertNil(grpc["mode"])
    }

    func testEmptyFlowIsOmitted() throws {
        let json = try compiledJSON([vlessTCP()])
        let outbounds = try XCTUnwrap(json["outbounds"] as? [[String: Any]])
        let users = try XCTUnwrap(((outbounds[0]["settings"] as? [String: Any])?["vnext"] as? [[String: Any]])?.first?["users"] as? [[String: Any]])
        XCTAssertNil(users[0]["flow"])
    }
}

final class XrayRoutingMappingTests: XCTestCase {
    private func config(rules: [RouteRule], defaultAction: RouteAction) -> CanonicalTunnelConfiguration {
        let server = Server(
            id: UUID(), name: "VLESS server", protocolKind: .vless,
            endpoint: Endpoint(host: "203.0.113.7", port: 443),
            credential: SecretReference(key: "test/vless"),
            transport: TransportOptions(kind: "tcp"),
            tls: TLSOptions(serverName: "example.com"), tags: []
        )
        return CanonicalTunnelConfiguration(
            schemaVersion: 1,
            appConfig: AppConfig(
                schemaVersion: 1, subscriptions: [], groups: [],
                routing: RouteSet(rules: rules, defaultAction: defaultAction),
                dns: DNSPolicy(mode: .system), privacy: PrivacyPolicy(), servers: [server]
            )
        )
    }

    private func rules(of data: Data) throws -> [[String: Any]] {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap((json["routing"] as? [String: Any])?["rules"] as? [[String: Any]])
    }

    func testBlockRuleWithMatchersMaps() throws {
        let rule = RouteRule(
            id: UUID(), enabled: true,
            matchers: [.domainSuffix("media.example"), .ipCIDR("192.168.0.0/16"), .portRange(lower: 22, upper: 23)],
            action: .block, note: nil
        )
        let rules = try rules(of: XrayConfigCompiler().compile(config(rules: [rule], defaultAction: .direct)))
        XCTAssertEqual(rules.count, 3)
        XCTAssertEqual(rules[1]["outboundTag"] as? String, "block")
        XCTAssertEqual(rules[1]["domain"] as? [String], ["domain:media.example"])
        XCTAssertEqual(rules[1]["ip"] as? [String], ["192.168.0.0/16"])
        XCTAssertEqual(rules[1]["port"] as? String, "22-23")
        XCTAssertEqual(rules[2]["outboundTag"] as? String, "direct")
    }

    func testDisabledRulesAreOmittedAndGroupActionsRefused() throws {
        let disabled = RouteRule(
            id: UUID(), enabled: false,
            matchers: [.domain("x.example")], action: .block, note: nil
        )
        let rules = try rules(of: XrayConfigCompiler().compile(config(rules: [disabled], defaultAction: .direct)))
        XCTAssertEqual(rules.count, 2)

        let grouped = RouteRule(
            id: UUID(), enabled: true,
            matchers: [.domain("x.example")], action: .group(UUID()), note: nil
        )
        XCTAssertThrowsError(try XrayConfigCompiler().compile(config(rules: [grouped], defaultAction: .direct)))
    }
}
