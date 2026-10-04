import Foundation
import RoviaEngineAPI

/// The Xray engine boundary.
///
/// Two shapes, one type:
///
/// - `XrayAdapter()` — the foundation adapter. No artifact is linked, so
///   `prepare` and `start` refuse with `notIncludedInBuild`, `status` reports
///   `unavailable`, and the descriptor version is `not-enabled`. This shape is
///   what the app links when it is built without the engine binary.
/// - `XrayAdapter(bridge:secretReader:)` — the live adapter, constructed by
///   `RoviaXrayLive` with the gomobile bridge. `prepare` compiles the
///   canonical configuration into engine JSON with secret placeholders,
///   `start` resolves the placeholders through the Keychain reader, builds the
///   tun socket pair, hands the engine fd to the config, starts the runtime,
///   and runs the packet pump against the tunnel's bridge.
public struct XrayAdapter: TunnelEngine {
    public let descriptor: EngineDescriptor

    private let controller: XrayEngineController?

    public init() {
        descriptor = EngineDescriptor(id: "xray", name: "Xray", version: "not-enabled")
        controller = nil
    }

    /// The live adapter. `secretReader` resolves a `SecretReference` key to the
    /// credential bytes — in the extension that is a Keychain read; the adapter
    /// never sees the app process's copy.
    public init(
        bridge: any LibXrayBridge,
        secretReader: @escaping @Sendable (String) throws -> Data?
    ) {
        let version: String
        if let reported = try? Self.probeVersion(bridge: bridge) {
            version = reported
        } else {
            version = "unknown"
        }
        descriptor = EngineDescriptor(id: "xray", name: "Xray", version: version)
        controller = XrayEngineController(
            runtime: XrayRuntime(bridge: bridge, secretReader: secretReader)
        )
    }

    /// Reads the engine's version through the bridge. Called once at
    /// construction: the descriptor is a value type, so the version has to be
    /// known before the adapter exists.
    private static func probeVersion(bridge: any LibXrayBridge) throws -> String {
        let request = try LibXrayRequest(method: .xrayVersion).encoded()
        let raw = try bridge.invoke(request)
        defer { bridge.free(raw) }
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let envelope = object as? [String: Any],
              let payload = envelope["data"] as? [String: Any],
              let version = payload["version"] as? String
        else {
            throw XrayRuntimeError.malformedResponse
        }
        return version
    }

    public func capabilities() async -> EngineCapabilities {
        if controller == nil {
            return EngineCapabilities(
                supportsTunnel: false,
                supportsHealthProbe: false,
                supportsRouting: false,
                supportedProtocols: []
            )
        }
        return EngineCapabilities(
            supportsTunnel: true,
            supportsHealthProbe: false,
            supportsRouting: true,
            supportedProtocols: [.vless, .trojan, .shadowsocks]
        )
    }

    public func validate(_ configuration: CanonicalTunnelConfiguration) async throws -> ValidationReport {
        do {
            _ = try XrayConfigCompiler().compile(configuration)
            return ValidationReport(valid: true, warnings: [])
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.invalidConfiguration("uncompilable configuration")
        }
    }

    public func prepare(_ configuration: CanonicalTunnelConfiguration) async throws -> PreparedEngineConfiguration {
        guard controller != nil else {
            throw EngineError.notIncludedInBuild("xray")
        }
        let compiled = try XrayConfigCompiler().compile(configuration)
        return PreparedEngineConfiguration(engineID: descriptor.id, opaquePayload: compiled)
    }

    public func start(_ context: TunnelRuntimeContext) async throws {
        guard let controller else {
            throw EngineError.notIncludedInBuild("xray")
        }
        try await controller.start(context)
    }

    public func stop() async {
        await controller?.stop()
    }

    public func status() async -> EngineStatus {
        guard let controller else {
            return .unavailable
        }
        return await controller.status()
    }

    public func probe(_ request: HealthProbeRequest) async throws -> HealthProbeResult {
        throw EngineError.unsupportedCapability("health probe is not wired yet")
    }
}
