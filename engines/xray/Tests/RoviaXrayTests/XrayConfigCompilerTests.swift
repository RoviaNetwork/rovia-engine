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
        XCTAssertEqual(rules.last?["outboundTag"] as? String, "proxy-0")
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
