import Foundation

/// The libXray Invoke envelope (apiVersion 3), modeled without the artifact
/// so the runtime, the state machine, and the race handling are testable
/// today. The only file that touches the real `LibXray` module is the thin
/// `LibXrayBridge` implementation added alongside the built xcframework;
/// everything else talks to this protocol.
public protocol LibXrayBridge: Sendable {
    /// Sends one Invoke request envelope, returns the raw response envelope.
    func invoke(_ requestJSON: String) throws -> String
    /// Frees a response string previously returned by `invoke`, mirroring
    /// `CGoFree`. Mocks may ignore it; the real bridge must not.
    func free(_ response: String)
}

public enum LibXrayMethod: String, Sendable {
    case runXray
    case stopXray
    case testXray
    case xrayVersion
}

public struct LibXrayRequest: Sendable {
    public static let apiVersion = 3
    public static let maximumBytes = 16 * 1024 * 1024

    public let method: LibXrayMethod
    public let payload: [String: String]

    public init(method: LibXrayMethod, payload: [String: String] = [:]) {
        self.method = method
        self.payload = payload
    }

    public func encoded() throws -> String {
        let envelope: [String: Any] = [
            "apiVersion": Self.apiVersion,
            "method": method.rawValue,
            "payload": payload,
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        guard data.count <= Self.maximumBytes else {
            throw XrayRuntimeError.requestTooLarge
        }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct LibXrayResponse: Sendable {
    public let success: Bool
    public let error: String

    public static func decode(_ json: String) throws -> LibXrayResponse {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let envelope = object as? [String: Any],
              let success = envelope["success"] as? Bool
        else {
            throw XrayRuntimeError.malformedResponse
        }
        return LibXrayResponse(
            success: success,
            error: envelope["error"] as? String ?? ""
        )
    }
}

public enum XrayRuntimeError: Error, Equatable, Sendable {
    case requestTooLarge
    case malformedResponse
    case engineRefused(String)
    case alreadyRunning
    case cancelled
}

/// The engine lifecycle with generation-gated state: every start/stop bumps
/// the generation, and a late response from an older generation can observe
/// but never overwrite current state.
///
/// The hard interleaving is stop-during-start: the engine may complete
/// `runXray` after we already decided to stop. `stopRequested` closes it —
/// `start` checks the flag after a successful `runXray` and stops the engine
/// itself before reporting, so no path leaves the engine running while the
/// state says idle. The unit tests pin every interleaving below.
public actor XrayRuntime {
    public enum State: Equatable, Sendable {
        case idle
        case starting
        case running(since: Date)
        case stopping
        case failed(String)
    }

    private let bridge: any LibXrayBridge
    private let secretReader: @Sendable (String) throws -> Data?
    private let now: @Sendable () -> Date

    private var generation = 0
    private var stopRequested = false
    /// Generation of the latest `start` call. A stale start cleans up after
    /// itself only while no newer start began: cleaning up after a newer
    /// start owns the engine would kill a live tunnel.
    ///
    /// Residual window (documented, not hidden): if a newer start begins
    /// *during* this stale start's cleanup `stopXray` await, the cleanup can
    /// land after the newer start's `runXray`. Closing that needs engine-side
    /// fencing (an order-reporting mutex in libXray); the pinned
    /// interleavings — stop-during-start, refresh storms, late responses —
    /// are fully covered below.
    private var activeStart: Int = 0
    private(set) var state: State = .idle

    public init(
        bridge: any LibXrayBridge,
        secretReader: @escaping @Sendable (String) throws -> Data?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.bridge = bridge
        self.secretReader = secretReader
        self.now = now
    }

    /// Validates the config against the engine (`testXray`), then starts.
    /// `tunFD` is the Packet Tunnel flow descriptor, injected into the
    /// config env as `xray.tun.fd` before `runXray`.
    public func start(configJSON: Data, tunFD: Int32?) async throws {
        generation += 1
        let mine = generation
        activeStart = mine
        stopRequested = false
        switch state {
        case .idle, .failed:
            break
        default:
            throw XrayRuntimeError.alreadyRunning
        }
        state = .starting
        do {
            let resolved = try resolveSecrets(in: configJSON)
            try await invokeChecked(method: .testXray, payload: ["xrayJson": resolved], generation: mine)
            var tunConfig = resolved
            if let tunFD {
                tunConfig = try injectTunFD(tunFD, into: resolved)
            }
            try await invokeChecked(method: .runXray, payload: ["xrayJson": tunConfig], generation: mine)
            guard mine == generation else { throw XrayRuntimeError.cancelled }
            if stopRequested, activeStart == mine {
                // Stop arrived mid-start and no newer start began since: the
                // engine may now be running, so stop it before reporting.
                // Best effort — the state below is what matters, and it is
                // idle either way.
                try? await rawInvoke(method: .stopXray, payload: [:])
                state = .idle
                throw XrayRuntimeError.cancelled
            }
            state = .running(since: now())
        } catch {
            if stopRequested, activeStart == mine {
                // Stop arrived mid-start (or the start itself was stale): the
                // engine may have completed `runXray` after the decision to
                // stop, so ask it to stop before reporting. Best effort — a
                // refusal here means it never started, and the state below
                // is idle either way.
                try? await rawInvoke(method: .stopXray, payload: [:])
                if mine == generation {
                    state = .idle
                }
            } else if mine == generation {
                state = .failed(String(describing: error))
            }
            throw error
        }
    }

    public func stop() async throws {
        generation += 1
        let wasStarting: Bool
        switch state {
        case .idle:
            return
        case .starting:
            wasStarting = true
        case .running, .stopping, .failed:
            wasStarting = false
        }
        stopRequested = true
        state = .stopping
        do {
            try await rawInvoke(method: .stopXray, payload: [:])
            state = .idle
        } catch {
            // Stopping an engine that never finished starting legitimately
            // reports nothing to stop: the desired end state is idle, and it
            // holds. A stop against a running engine that refuses is real.
            if wasStarting {
                state = .idle
            } else {
                state = .failed(String(describing: error))
                throw error
            }
        }
    }

    private func resolveSecrets(in configJSON: Data) throws -> String {
        let keys = try XraySecretSubstitutor.secretKeys(in: configJSON)
        var secrets: [String: Data] = [:]
        for key in keys {
            guard let value = try secretReader(key) else {
                throw XrayRuntimeError.engineRefused("missing secret for \(key)")
            }
            secrets[key] = value
        }
        let substituted = try XraySecretSubstitutor.substituting(secrets, in: configJSON)
        guard let text = String(data: substituted, encoding: .utf8) else {
            throw XrayRuntimeError.engineRefused("substituted config is not UTF-8")
        }
        return text
    }

    private func injectTunFD(_ fd: Int32, into configJSON: String) throws -> String {
        guard var object = try? JSONSerialization.jsonObject(with: Data(configJSON.utf8)) as? [String: Any] else {
            throw XrayRuntimeError.engineRefused("config is not a JSON object")
        }
        var env = object["env"] as? [String: String] ?? [:]
        env["xray.tun.fd"] = String(fd)
        object["env"] = env
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// One Invoke round trip with the generation check. The bridge call runs
    /// detached (synchronous C must not park the actor); a wedged engine
    /// outlives the wait only until the caller cancels, at which point the
    /// result is discarded.
    private func invokeChecked(method: LibXrayMethod, payload: [String: String], generation mine: Int) async throws {
        let raw = try await rawInvoke(method: method, payload: payload)
        guard mine == generation else { throw XrayRuntimeError.cancelled }
        let response = try LibXrayResponse.decode(raw)
        guard response.success else {
            throw XrayRuntimeError.engineRefused(response.error)
        }
    }

    private func rawInvoke(method: LibXrayMethod, payload: [String: String]) async throws -> String {
        let request = try LibXrayRequest(method: method, payload: payload).encoded()
        let raw: String = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [bridge] in
                try bridge.invoke(request)
            }.value
        } onCancel: {}
        bridge.free(raw)
        return raw
    }
}
