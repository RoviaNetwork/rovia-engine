import Foundation
import RoviaConfig
import RoviaEngineAPI

/// Compiles a canonical configuration into an Xray JSON config.
///
/// Secrets never enter the output: every credential becomes a
/// `__ROVIA_SECRET::<key>__` placeholder, where `<key>` is the
/// `SecretReference` key. The tunnel extension substitutes the real bytes
/// from the Keychain at start time (one Go runtime per process, so the
/// substitution lives in the extension, next to `runXray`).
///
/// Ordering contract: the default route targets the FIRST server's outbound.
/// The adapter orders the selected server first in `prepare`, so compiling
/// without reordering routes to whatever the configuration lists first.
///
/// v1 limits, stated plainly: per-rule routing (`RouteSet` matchers) is not
/// mapped yet — only the default route plus the DNS rule are emitted — and
/// `vmess` servers are refused. Both are `invalidConfiguration`, never
/// silent drops, except `vmess` which is refused loudly too.
public struct XrayConfigCompiler: EngineConfigCompiler {
    public typealias Output = Data

    /// The placeholder around a secret-reference key. Bracketed so a real
    /// credential can never collide with it, and greppable so the extension
    /// can collect the key list with one pass.
    public static func placeholder(forKey key: String) -> String {
        "__ROVIA_SECRET::\(key)__"
    }

    public init() {}

    public func compile(_ configuration: CanonicalTunnelConfiguration) throws -> Data {
        guard configuration.schemaVersion == 1 else {
            throw EngineError.invalidConfiguration("unsupported schemaVersion \(configuration.schemaVersion)")
        }
        let servers = configuration.appConfig.servers
        guard !servers.isEmpty else {
            throw EngineError.invalidConfiguration("no servers to compile")
        }
        var outbounds: [[String: Any]] = []
        var tags: [String] = []
        for (index, server) in servers.enumerated() {
            let tag = "proxy-\(index)"
            tags.append(tag)
            outbounds.append(try serverOutbound(server, tag: tag))
        }
        outbounds.append(["protocol": "direct", "tag": "direct"])
        outbounds.append(["protocol": "blackhole", "tag": "block"])
        outbounds.append(["protocol": "dns", "tag": "dns"])
        let config: [String: Any] = [
            "inbounds": [
                ["protocol": "tun", "tag": "tun", "settings": [:] as [String: Any]],
                [
                    "protocol": "socks",
                    "tag": "socks-in",
                    "settings": ["auth": "noauth", "udp": true, "ip": "127.0.0.1", "port": 10808] as [String: Any],
                ],
            ],
            "outbounds": outbounds,
            "routing": [
                "domainStrategy": "AsIs",
                "rules": [
                    ["type": "field", "port": "53", "outboundTag": "dns"],
                    ["type": "field", "inboundTag": ["tun"], "outboundTag": tags[0]],
                ],
            ] as [String: Any],
            "dns": dnsSection(policy: configuration.appConfig.dns),
        ]
        return try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
    }

    // MARK: - Servers

    private func serverOutbound(_ server: Server, tag: String) throws -> [String: Any] {
        guard let reference = server.credential else {
            throw EngineError.invalidConfiguration("server \(server.id) has no credential reference")
        }
        let secret = Self.placeholder(forKey: reference.key)
        switch server.protocolKind {
        case .vless:
            return [
                "protocol": "vless",
                "tag": tag,
                "settings": [
                    "vnext": [
                        [
                            "address": server.endpoint.host,
                            "port": server.endpoint.port,
                            "users": [
                                [
                                    "id": secret,
                                    "encryption": "none",
                                    "flow": server.transport.options["flow"] ?? "",
                                    "level": 0,
                                ],
                            ],
                        ],
                    ],
                ] as [String: Any],
                "streamSettings": try streamSettings(server),
            ]
        case .trojan:
            return [
                "protocol": "trojan",
                "tag": tag,
                "settings": [
                    "servers": [
                        [
                            "address": server.endpoint.host,
                            "port": server.endpoint.port,
                            "password": secret,
                            "level": 0,
                        ],
                    ],
                ] as [String: Any],
                "streamSettings": try streamSettings(server),
            ]
        case .shadowsocks:
            guard let method = server.transport.options["method"] else {
                throw EngineError.invalidConfiguration("shadowsocks server \(server.id) has no method")
            }
            return [
                "protocol": "shadowsocks",
                "tag": tag,
                "settings": [
                    "servers": [
                        [
                            "address": server.endpoint.host,
                            "port": server.endpoint.port,
                            "method": method,
                            "password": secret,
                            "level": 0,
                        ],
                    ],
                ] as [String: Any],
            ]
        case .vmess:
            throw EngineError.invalidConfiguration("vmess is not supported by this compiler")
        }
    }

    private func streamSettings(_ server: Server) throws -> [String: Any] {
        let transport = server.transport
        let options = transport.options
        let isReality = options["realityPublicKey"] != nil
        let security: String
        if server.tls == nil {
            security = "none"
        } else if isReality {
            security = "reality"
        } else {
            security = "tls"
        }
        var settings: [String: Any] = ["network": transport.kind, "security": security]
        switch transport.kind {
        case "ws":
            var ws: [String: Any] = ["path": options["path"] ?? "/"]
            if let host = options["host"] {
                ws["headers"] = ["Host": host]
            }
            settings["wsSettings"] = ws
        case "grpc":
            settings["grpcSettings"] = ["serviceName": options["serviceName"] ?? ""]
        case "http", "httpupgrade":
            var http: [String: Any] = ["path": options["path"] ?? "/"]
            if let host = options["host"] {
                http["host"] = [host]
            }
            settings["httpSettings"] = http
        case "tcp":
            if options["headerType"] == "http" {
                var request: [String: Any] = ["path": ["/"], "headers": [:] as [String: Any]]
                if let host = options["host"] {
                    request["headers"] = ["Host": [host]]
                }
                settings["tcpSettings"] = ["header": ["type": "http", "request": request]]
            }
        default:
            throw EngineError.invalidConfiguration("unsupported transport \(transport.kind)")
        }
        if let tls = server.tls {
            var tlsSettings: [String: Any] = ["allowInsecure": tls.allowInsecure]
            if let name = tls.serverName {
                tlsSettings["serverName"] = name
            }
            if !tls.alpn.isEmpty {
                tlsSettings["alpn"] = tls.alpn
            }
            if let fingerprint = options["fingerprint"] {
                tlsSettings["fingerprint"] = fingerprint
            }
            if isReality {
                guard let publicKey = options["realityPublicKey"] else {
                    throw EngineError.invalidConfiguration("reality without a public key")
                }
                var reality = tlsSettings
                reality["publicKey"] = publicKey
                if let shortID = options["realityShortID"], !shortID.isEmpty {
                    reality["shortId"] = shortID
                }
                settings["realitySettings"] = reality
            } else {
                settings["tlsSettings"] = tlsSettings
            }
        }
        return settings
    }

    private func dnsSection(policy: DNSPolicy) -> [String: Any] {
        let servers: [String]
        switch policy.mode {
        case .custom where !policy.servers.isEmpty:
            servers = policy.servers
        default:
            servers = ["1.1.1.1", "8.8.8.8"]
        }
        return ["servers": servers, "queryStrategy": "UseIPv4"]
    }
}
