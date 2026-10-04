import Foundation
import RoviaEngineAPI
import RoviaXray

extension XrayAdapter {
    /// The adapter wired to the bundled libXray artifact.
    ///
    /// `secretReader` resolves a `SecretReference` key to credential bytes. In
    /// the Packet Tunnel extension that is a Keychain read; the engine process
    /// never sees the app process's copy of anything.
    public static func live(
        secretReader: @escaping @Sendable (String) throws -> Data?
    ) -> XrayAdapter {
        XrayAdapter(bridge: GomobileLibXrayBridge(), secretReader: secretReader)
    }
}
