import Darwin
import XCTest
@testable import RoviaEngineAPI
@testable import RoviaXray

/// A loopback bridge: `read` replays queued packets until told to wait, and
/// `write` records. The pump's fd side is a real socket pair, so these tests
/// exercise real syscalls without the engine.
final class XrayTunPumpTests: XCTestCase {
    private final class MockBridge: PacketBridge, @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [[EnginePacket]] = []
        private var recorded: [EnginePacket] = []

        func enqueue(_ packets: [EnginePacket]) {
            lock.withLock { pending.append(packets) }
        }

        func read() async throws -> [EnginePacket] {
            while true {
                try Task.checkCancellation()
                let next = lock.withLock { () -> [EnginePacket]? in
                    pending.isEmpty ? nil : pending.removeFirst()
                }
                if let next { return next }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        func write(_ packets: [EnginePacket]) async throws {
            lock.withLock { recorded.append(contentsOf: packets) }
        }

        func recordedWrites() -> [EnginePacket] {
            lock.withLock { recorded }
        }
    }

    private func makeIPv4Packet(_ byte: UInt8 = 0x45) -> EnginePacket {
        EnginePacket(data: Data([byte, 0x00, 0x00, 0x3c]), protocolNumber: 2)
    }

    private func makeIPv6Packet() -> EnginePacket {
        EnginePacket(data: Data([0x60, 0x00, 0x00, 0x00]), protocolNumber: 30)
    }

    // MARK: Framing

    func testFramingRoundTripsIPv4AndIPv6() {
        for packet in [makeIPv4Packet(), makeIPv6Packet()] {
            let framed = UtunFraming.frame(packet)
            XCTAssertEqual(framed.count, packet.data.count + 4)
            XCTAssertEqual(framed[0], 0)
            XCTAssertEqual(framed[1], 0)
            XCTAssertEqual(framed[2], 0)
            let restored = UtunFraming.unframe(framed)
            XCTAssertEqual(restored, packet)
        }
    }

    func testUnframeDropsSubHeaderDatagrams() {
        XCTAssertNil(UtunFraming.unframe(Data()))
        XCTAssertNil(UtunFraming.unframe(Data([0, 0, 0])))
        XCTAssertNil(UtunFraming.unframe(Data([0, 0, 0, 2])))
    }

    func testUnframeDropsUnknownFamilies() {
        XCTAssertNil(UtunFraming.unframe(Data([0, 0, 0, 7, 0x45])))
    }

    // MARK: Socket pair

    func testSocketPairIsNonBlockingAndLoopback() throws {
        let pair = try XrayTunPump.makeSocketPair()
        defer {
            close(pair.engine)
            close(pair.client)
        }
        // An empty pair answers EAGAIN, never a block.
        var buffer = [UInt8](repeating: 0, count: 128)
        let empty = buffer.withUnsafeMutableBytes { pointer in
            Darwin.read(pair.engine, pointer.baseAddress, 128)
        }
        XCTAssertEqual(empty, -1)
        XCTAssertEqual(errno, EAGAIN)

        let framed = UtunFraming.frame(makeIPv4Packet())
        let written = framed.withUnsafeBytes { pointer in
            Darwin.write(pair.client, pointer.baseAddress, framed.count)
        }
        XCTAssertEqual(written, framed.count)
        let count = buffer.withUnsafeMutableBytes { pointer in
            Darwin.read(pair.engine, pointer.baseAddress, 128)
        }
        XCTAssertEqual(count, framed.count)
        XCTAssertEqual(Data(bytes: buffer, count: count), framed)
    }

    // MARK: Pump movement

    func testPumpMovesBridgePacketsToTheEngineFD() async throws {
        let pair = try XrayTunPump.makeSocketPair()
        defer { close(pair.engine) }
        let bridge = MockBridge()
        let packet = makeIPv4Packet()
        bridge.enqueue([packet])

        let pump = XrayTunPump()
        let task = Task {
            try await pump.run(clientFD: pair.client, bridge: bridge)
        }
        // Read what the pump wrote to the engine's end.
        var buffer = [UInt8](repeating: 0, count: 128)
        var pollFD = pollfd(fd: pair.engine, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&pollFD, 1, 2000), 1)
        let count = buffer.withUnsafeMutableBytes { pointer in
            Darwin.read(pair.engine, pointer.baseAddress, 128)
        }
        pump.stop()
        task.cancel()
        _ = try? await task.value
        close(pair.client)

        XCTAssertGreaterThan(count, 4)
        let received = UtunFraming.unframe(Data(bytes: buffer, count: count))
        XCTAssertEqual(received, packet)
    }

    func testPumpMovesEngineFDPacketsToTheBridge() async throws {
        let pair = try XrayTunPump.makeSocketPair()
        defer { close(pair.engine) }
        let bridge = MockBridge()
        let pump = XrayTunPump()
        let task = Task {
            try await pump.run(clientFD: pair.client, bridge: bridge)
        }
        // Write as the engine would.
        let framed = UtunFraming.frame(makeIPv6Packet())
        let written = framed.withUnsafeBytes { pointer in
            Darwin.write(pair.engine, pointer.baseAddress, framed.count)
        }
        XCTAssertEqual(written, framed.count)

        // Wait for the pump to deliver.
        var delivered: [EnginePacket] = []
        for _ in 0..<100 {
            delivered = bridge.recordedWrites()
            if !delivered.isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        pump.stop()
        task.cancel()
        _ = try? await task.value
        close(pair.client)

        XCTAssertEqual(delivered, [makeIPv6Packet()])
    }

    func testPumpCountsMalformedEngineDatagramsAsInboundDrops() async throws {
        let pair = try XrayTunPump.makeSocketPair()
        defer { close(pair.engine) }
        let bridge = MockBridge()
        let pump = XrayTunPump()
        let task = Task {
            try await pump.run(clientFD: pair.client, bridge: bridge)
        }
        let garbage = Data([0xde, 0xad])
        _ = garbage.withUnsafeBytes { pointer in
            Darwin.write(pair.engine, pointer.baseAddress, garbage.count)
        }
        for _ in 0..<100 {
            if pump.counters().inboundDrops == 1 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        pump.stop()
        task.cancel()
        _ = try? await task.value
        close(pair.client)

        XCTAssertEqual(pump.counters().inboundDrops, 1)
        XCTAssertEqual(bridge.recordedWrites(), [])
    }

    func testStopEndsThePump() async throws {
        let pair = try XrayTunPump.makeSocketPair()
        defer {
            close(pair.engine)
            close(pair.client)
        }
        let bridge = MockBridge()
        let pump = XrayTunPump()
        let task = Task {
            try await pump.run(clientFD: pair.client, bridge: bridge)
        }
        pump.stop()
        task.cancel()
        _ = await task.result // the pump ends with its stopped or cancelled error
    }
}
