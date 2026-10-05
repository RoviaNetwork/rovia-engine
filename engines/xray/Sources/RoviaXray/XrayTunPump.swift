import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

import RoviaEngineAPI

/// The Darwin utun framing the Xray tun inbound expects on its file
/// descriptor: four bytes, the address family in the last one. NetworkExtension
/// hands `NEPacketTunnelFlow` raw IP packets with a separate protocol number,
/// so the pump's whole job on the framing level is adding and removing these
/// four bytes — payloads are never inspected, per `PRIVACY.md`.
public enum UtunFraming {
    public static let headerSize = 4
    public static let afInet: Int32 = 2
    public static let afInet6: Int32 = 30

    public static func frame(_ packet: EnginePacket) -> Data {
        var framed = Data(capacity: packet.data.count + headerSize)
        framed.append(contentsOf: [0, 0, 0, UInt8(truncatingIfNeeded: packet.protocolNumber)])
        framed.append(packet.data)
        return framed
    }

    /// One datagram from the engine's fd, or nil when the datagram is not a
    /// framed IPv4/IPv6 packet — a sub-header datagram or an unknown family is
    /// dropped rather than forwarded, because packetFlow refuses both.
    public static func unframe(_ datagram: Data) -> EnginePacket? {
        guard datagram.count > headerSize else { return nil }
        let family = Int32(datagram[datagram.index(datagram.startIndex, offsetBy: 3)])
        guard family == afInet || family == afInet6 else { return nil }
        return EnginePacket(
            data: datagram.subdata(in: datagram.index(datagram.startIndex, offsetBy: headerSize)..<datagram.endIndex),
            protocolNumber: family
        )
    }
}

public enum XrayTunPumpError: Error, Equatable, Sendable {
    case socketPairFailed(Int32)
    case closed
    case fdNotReady
    case readFailed(Int32)
    case writeFailed(Int32)
}

/// Moves packets between the engine's utun fd and the tunnel's packet bridge.
///
/// Backpressure policy, stated plainly because the spike's acceptance criteria
/// name it: nothing here grows a queue. A datagram that does not fit the
/// socket buffer within the bounded wait is dropped and counted, never
/// buffered — TCP retransmits recover the loss, and an unbounded queue is a
/// memory fault in a long-lived extension process.
///
/// Fd ownership: the pump owns `clientFD` for its lifetime, and `close()` is
/// the only place it is closed. Every syscall against the fd runs under the
/// pump's lock, and `close()` takes the same lock, so a close can never race a
/// read or write — a closed-then-reused fd number is not a hazard the pump
/// exposes to a later tunnel.
public final class XrayTunPump: @unchecked Sendable {
    public enum Counters {
        public typealias Snapshot = (outboundDrops: UInt64, inboundDrops: UInt64)
    }

    private let lock = NSLock()
    private var closed = false
    private var outboundDrops: UInt64 = 0
    private var inboundDrops: UInt64 = 0

    /// How long one datagram may wait for a writable fd before it is dropped.
    private static let writeWaitNanoseconds: UInt64 = 5_000_000_000
    private static let pollSliceMilliseconds: Int32 = 100
    /// Larger than any framed datagram the engine can emit: the biggest IP
    /// packet plus the four-byte utun header. A smaller buffer would truncate
    /// a maximal packet silently — a corrupted packet is worse than a dropped
    /// one, and `read` has no MSG_TRUNC to warn us.
    private static let bufferSize = 65_535 + 4

    public init() {}

    /// Creates the socket pair the tunnel is built on. `engine` is the fd the
    /// engine reads and writes (its number is injected into the config as
    /// `xray.tun.fd`); `client` is the pump's end. Both are datagram sockets,
    /// so one read is exactly one framed packet, and both are non-blocking.
    public static func makeSocketPair() throws -> (engine: Int32, client: Int32) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            throw XrayTunPumpError.socketPairFailed(errno)
        }
        var bufferSize: UInt32 = 4 * 1024 * 1024
        for fd in fds {
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufferSize, UInt32(MemoryLayout<UInt32>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufferSize, UInt32(MemoryLayout<UInt32>.size))
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        return (engine: fds[0], client: fds[1])
    }

    /// The pump's counters — drops in each direction, never payloads.
    public func counters() -> Counters.Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return (outboundDrops, inboundDrops)
    }

    /// Idempotent. After stop, both legs exit with `XrayTunPumpError.closed`,
    /// which the caller treats as a stopped tunnel, not a failure.
    public func stop() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    /// Runs both directions until closed, cancelled, or an fd failure. The
    /// first leg to finish ends the pump: a half-open tunnel is not a tunnel.
    public func run(clientFD: Int32, bridge: any PacketBridge) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.pumpOutbound(clientFD: clientFD, bridge: bridge) }
            group.addTask { try await self.pumpInbound(clientFD: clientFD, bridge: bridge) }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// Packets from the OS (via the bridge) into the engine's fd.
    private func pumpOutbound(clientFD: Int32, bridge: any PacketBridge) async throws {
        while true {
            try Task.checkCancellation()
            let packets = try await bridge.read()
            for packet in packets {
                try Task.checkCancellation()
                try await writeDatagram(UtunFraming.frame(packet), to: clientFD)
            }
        }
    }

    /// Packets from the engine's fd out to the OS (via the bridge).
    private func pumpInbound(clientFD: Int32, bridge: any PacketBridge) async throws {
        var buffer = [UInt8](repeating: 0, count: Self.bufferSize)
        while true {
            try Task.checkCancellation()
            try throwIfStopped()
            // The poll runs outside the lock: the fd stays valid for the
            // pump's whole lifetime (the owner closes it only after the pump
            // task has returned), and holding the lock across a 100 ms wait
            // would stall every outbound datagram behind it.
            var pollFD = pollfd(fd: clientFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollFD, 1, Self.pollSliceMilliseconds)
            if ready == 0 {
                continue  // a timeout is how cancellation stays responsive
            }
            guard ready > 0 else {
                throw XrayTunPumpError.readFailed(errno)
            }
            if pollFD.revents & Int16(POLLIN) == 0 {
                // POLLERR/POLLHUP/POLLNVAL: the engine's end is gone.
                throw XrayTunPumpError.fdNotReady
            }
            let count = try withFD(clientFD) { fd in
                buffer.withUnsafeMutableBytes { pointer in
                    read(fd, pointer.baseAddress, Self.bufferSize)
                }
            }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw XrayTunPumpError.readFailed(errno)
            }
            if count == 0 { continue }
            let datagram = Data(bytes: buffer, count: count)
            guard let packet = UtunFraming.unframe(datagram) else {
                noteInboundDrop()
                continue
            }
            try await bridge.write([packet])
        }
    }

    private func writeDatagram(_ datagram: Data, to fd: Int32) async throws {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(Self.writeWaitNanoseconds))
        while true {
            try Task.checkCancellation()
            let written = try withFD(fd) { descriptor in
                datagram.withUnsafeBytes { pointer in
                    write(descriptor, pointer.baseAddress, datagram.count)
                }
            }
            // A datagram socket writes the whole datagram or fails; a short
            // write would duplicate the tail on retry, so it is a drop.
            if written == datagram.count { return }
            if written >= 0 {
                noteOutboundDrop()
                return
            }
            if errno != EAGAIN && errno != EINTR {
                throw XrayTunPumpError.writeFailed(errno)
            }
            if ContinuousClock.now >= deadline {
                noteOutboundDrop()
                return
            }
            try throwIfStopped()
            var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            poll(&pollFD, 1, Self.pollSliceMilliseconds)
        }
    }

    private func throwIfStopped() throws {
        lock.lock()
        let stopped = closed
        lock.unlock()
        if stopped { throw XrayTunPumpError.closed }
    }

    /// Every fd syscall goes through here: the lock serialises syscalls with
    /// `close()`, and the closed flag is checked under the same lock, so a
    /// syscall never runs against a descriptor the owner has already closed.
    private func withFD<T>(_ fd: Int32, _ body: (Int32) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw XrayTunPumpError.closed }
        return try body(fd)
    }

    private func noteOutboundDrop() {
        lock.lock()
        outboundDrops += 1
        lock.unlock()
    }

    private func noteInboundDrop() {
        lock.lock()
        inboundDrops += 1
        lock.unlock()
    }
}
