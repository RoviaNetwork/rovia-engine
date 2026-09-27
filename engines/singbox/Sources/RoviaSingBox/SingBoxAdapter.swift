import Foundation
import RoviaEngineAPI

public struct SingBoxAdapter: TunnelEngine {
    public let descriptor = EngineDescriptor(id: "sing-box", name: "sing-box", version: "not-enabled")

    public init() {}

    public func capabilities() async -> EngineCapabilities {
        EngineCapabilities(
            supportsTunnel: false,
            supportsHealthProbe: false,
            supportsRouting: false,
            supportedProtocols: []
        )
    }

    public func validate(_ configuration: CanonicalTunnelConfiguration) async throws -> ValidationReport {
        throw EngineError.notIncludedInBuild("sing-box")
    }

    public func prepare(_ configuration: CanonicalTunnelConfiguration) async throws -> PreparedEngineConfiguration {
        throw EngineError.notIncludedInBuild("sing-box")
    }

    public func start(_ context: TunnelRuntimeContext) async throws {
        throw EngineError.notIncludedInBuild("sing-box")
    }

    public func stop() async {}

    public func status() async -> EngineStatus {
        .unavailable
    }

    public func probe(_ request: HealthProbeRequest) async throws -> HealthProbeResult {
        throw EngineError.notIncludedInBuild("sing-box")
    }
}

public struct SingBoxConfigCompiler: EngineConfigCompiler {
    public typealias Output = Data

    public init() {}

    public func compile(_ configuration: CanonicalTunnelConfiguration) throws -> Data {
        throw EngineError.notIncludedInBuild("sing-box")
    }
}
