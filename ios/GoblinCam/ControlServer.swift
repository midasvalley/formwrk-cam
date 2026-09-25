import Foundation
import Network

/// A line-based control channel, so the Mac can set the shot without anyone
/// walking over to the phone and reframing it in the process.
///
/// Deliberately separate from the video port: that one starts streaming the
/// moment you connect, which leaves no room for a request/response exchange.
///
///     rotate 0|90|180|270   ->  ok <angle>
///     lock                  ->  ok locked      (exposure, white balance, focus)
///     auto                  ->  ok auto
///     set <key> <value> ... ->  ok <key> <value> ...   (one or more pairs, applied as one look)
///     state                 ->  rotation=90 size=2160x3840 ... | device iso=200 1/60 ... queue=ok
final class ControlServer {

    /// Handles one command line and returns the reply. Called off the main queue.
    var onCommand: ((String) -> String)?

    private let queue = DispatchQueue(label: "goblincam.control")
    private var listener: NWListener?
    private var boundPort: UInt16 = 0
    private var stopped = true

    func start(port: UInt16) {
        queue.async {
            self.stopped = false
            self.boundPort = port
            guard self.listener == nil else { return }
            self._start(port: port)
        }
    }

    func stop() {
        queue.async { self.stopped = true; self.listener?.cancel(); self.listener = nil }
    }

    private func _start(port: UInt16) {
        let options = NWProtocolTCP.Options()
        options.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: options)
        parameters.allowLocalEndpointReuse = true

        guard let listener = try? NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!) else {
            rebuild()
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .main)
            self?.receive(connection)
        }
        // Dies the same way the video listener does, on the same interface changes.
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async { if case .failed = state { self.rebuild() } }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func rebuild() {
        listener?.cancel()
        listener = nil
        guard !stopped else { return }
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.stopped, self.listener == nil else { return }
            self._start(port: self.boundPort)
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 512) { [weak self] data, _, done, _ in
            guard let self else { return }
            if let data, !data.isEmpty {
                let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let reply = (self.onCommand?(line) ?? "error no handler") + "\n"
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }
            if done { connection.cancel() } else { self.receive(connection) }
        }
    }
}
