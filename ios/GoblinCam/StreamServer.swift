import Foundation
import Network

/// Serves the MPEG-TS stream over TCP.
///
/// The phone listens and the Mac connects, which is what lets one code path cover
/// both transports: over USB `iproxy` forwards a Mac port to this one through
/// usbmuxd, and over Wi-Fi the Mac dials the phone directly (Bonjour advertises it).
final class StreamServer {

    struct Stats {
        var listening = false
        var clients = 0
        var bytesSent = 0
        var droppedFrames = 0
        var port: UInt16 = 0
    }

    /// Raised when a client connects and needs a key frame before it can decode.
    var onNeedsKeyframe: (() -> Void)?
    /// Raised whenever the client count changes, so capture can idle with nobody watching.
    var onClientCountChanged: ((Int) -> Void)?

    private final class Client {
        let connection: NWConnection
        var primed = false   // has been handed a key frame
        var pending = 0      // bytes handed to the socket but not yet flushed
        init(_ connection: NWConnection) { self.connection = connection }
    }

    /// Roughly a second of headroom at 40 Mbps. Past this we drop rather than
    /// queue, because queueing on a live feed just turns into latency.
    private let maxPendingBytes = 4 * 1024 * 1024

    private let queue = DispatchQueue(label: "goblincam.server")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var stats = Stats()
    private var boundPort: UInt16 = 0
    /// Set only by `stop()`, so a listener that dies on its own comes back but one
    /// we deliberately took down stays down.
    private var stopped = true

    // MARK: - Lifecycle

    func start(port: UInt16) {
        queue.async {
            self.stopped = false
            self.boundPort = port
            guard self.listener == nil else { return }
            self._start(port: port)
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.clients.values.forEach { $0.connection.cancel() }
            self.clients.removeAll()
            self.listener?.cancel()
            self.listener = nil
            self.stats.listening = false
            self.stats.clients = 0
        }
    }

    func snapshot() -> Stats {
        queue.sync { stats }
    }

    private func _start(port: UInt16) {
        let options = NWProtocolTCP.Options()
        options.noDelay = true                 // never sit on a partial frame
        options.enableKeepalive = true
        options.keepaliveIdle = 5

        let parameters = NWParameters(tls: nil, tcp: options)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false

        guard let listener = try? NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!) else {
            stats.listening = false
            return
        }
        listener.service = NWListener.Service(name: "GoblinCam", type: "_goblincam._tcp")
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                if case .ready = state { self.stats.listening = true; self.stats.port = port }
                // A failed listener never recovers on its own, and plugging the phone
                // in or unplugging it is exactly the kind of interface change that
                // kills one. Build a fresh one rather than making anyone relaunch.
                if case .failed = state { self.rebuild() }
                if case .cancelled = state { self.stats.listening = false }
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// Tear down a dead listener and stand a new one up in its place.
    private func rebuild() {
        stats.listening = false
        listener?.cancel()
        listener = nil
        guard !stopped else { return }
        // A second is long enough for the interface change that killed it to settle.
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.stopped, self.listener == nil else { return }
            self._start(port: self.boundPort)
        }
    }

    // MARK: - Clients

    private func accept(_ connection: NWConnection) {
        let client = Client(connection)
        clients[ObjectIdentifier(connection)] = client
        stats.clients = clients.count

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onNeedsKeyframe?()
                self.onClientCountChanged?(self.clients.count)
            case .failed, .cancelled:
                self.drop(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func drop(_ connection: NWConnection) {
        guard clients.removeValue(forKey: ObjectIdentifier(connection)) != nil else { return }
        connection.cancel()
        stats.clients = clients.count
        onClientCountChanged?(clients.count)
    }

    // MARK: - Sending

    /// Drop every client so they reconnect and probe again.
    ///
    /// Needed whenever the encoder restarts: the stream's resolution, codec and
    /// timeline all change at once, and a reader part-way through the old stream
    /// has no way to renegotiate. Cutting them makes OBS redial within a second
    /// and pick up the new format cleanly.
    func resetClients() {
        queue.async {
            self.clients.values.forEach { $0.connection.cancel() }
            self.clients.removeAll()
            self.stats.clients = 0
        }
    }

    /// Hand one access unit's worth of transport packets to every client.
    /// A client that has not yet seen a key frame is skipped until one arrives.
    func broadcast(_ data: Data, keyframe: Bool) {
        queue.async {
            guard !self.clients.isEmpty else { return }
            for client in self.clients.values {
                if !client.primed {
                    guard keyframe else { continue }
                    client.primed = true
                }
                if client.pending > self.maxPendingBytes {
                    // Backed up. Wait for the next key frame to resynchronise.
                    if !keyframe { self.stats.droppedFrames += 1; continue }
                    client.pending = 0
                }
                client.pending += data.count
                self.stats.bytesSent += data.count
                client.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    self?.queue.async {
                        client.pending = max(0, client.pending - data.count)
                        if error != nil { self?.drop(client.connection) }
                    }
                })
            }
        }
    }
}
