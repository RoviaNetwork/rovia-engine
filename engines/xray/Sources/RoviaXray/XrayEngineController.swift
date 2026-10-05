import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

import RoviaEngineAPI

/// Owns the pieces of a running engine: the runtime state machine, the
/// socket pair the engine's tun inbound talks over, and the pump task moving
/// packets between that pair and the tunnel's packet bridge.
///
/// Lifecycle order is the contract: the engine is stopped before the pump is
/// cancelled, and the pump returns before either fd is closed, so no syscall
/// ever touches a closed descriptor.
final class XrayEngineController: @unchecked Sendable {
    private let runtime: XrayRuntime
    private var pumpTask: Task<Void, Error>?
    private var pump: XrayTunPump?
    private var engineFD: Int32 = -1
    private var clientFD: Int32 = -1

    init(runtime: XrayRuntime) {
        self.runtime = runtime
    }

    func start(_ context: TunnelRuntimeContext) async throws {
        let pair = try XrayTunPump.makeSocketPair()
        engineFD = pair.engine
        clientFD = pair.client
        do {
            try await runtime.start(
                configJSON: context.preparedConfiguration.opaquePayload,
                tunFD: pair.engine
            )
        } catch {
            closeDescriptors()
            throw error
        }
        let pump = XrayTunPump()
        self.pump = pump
        pumpTask = Task {
            try await pump.run(clientFD: pair.client, bridge: context.packetBridge)
        }
    }

    func stop() async {
        try? await runtime.stop()
        pump?.stop()
        if let task = pumpTask {
            task.cancel()
            _ = try? await task.value
        }
        pumpTask = nil
        pump = nil
        closeDescriptors()
    }

    func status() async -> EngineStatus {
        switch await runtime.state {
        case .idle:
            return .idle
        case .starting:
            return .preparing
        case .running:
            return .running
        case .stopping:
            return .stopping
        case let .failed(message):
            return .failed(message)
        }
    }

    /// The engine's own answer to "are you still running".
    func isEngineAlive() async -> Bool {
        await runtime.isEngineAlive()
    }

    /// Counters for the diagnostic surface. Payloads never appear here — only
    /// how many datagrams the backpressure policy dropped in each direction.
    func droppedCounts() async -> (outboundDrops: UInt64, inboundDrops: UInt64) {
        guard let pump else { return (0, 0) }
        let counters = pump.counters()
        return counters
    }

    private func closeDescriptors() {
        if engineFD >= 0 {
            close(engineFD)
            engineFD = -1
        }
        if clientFD >= 0 {
            close(clientFD)
            clientFD = -1
        }
    }
}
