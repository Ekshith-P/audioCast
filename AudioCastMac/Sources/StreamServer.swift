import Foundation
import Network

final class StreamServer: ObservableObject {
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var port: UInt16?
    @Published private(set) var connectedClientCount: Int = 0
    @Published var lastError: String?

    private let queue = DispatchQueue(label: "StreamServer.queue")
    private var listener: NWListener?

    private struct Client {
        var connection: NWConnection
        var isReady: Bool
        var hasSentHeader: Bool
    }

    private var clients: [ObjectIdentifier: Client] = [:]
    private var headerData: Data?

    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    /// Sets/updates the stream header; newly-ready clients will receive it.
    func updateStreamFormat(sampleRate: Double, channelCount: Int, isInterleaved: Bool) {
        let newHeader = AudioCastProtocol.makeHeader(
            sampleRate: sampleRate,
            channelCount: channelCount,
            isInterleaved: isInterleaved
        )

        queue.async { [weak self] in
            guard let self else { return }
            self.headerData = newHeader
            self.flushHeadersIfNeeded()
        }
    }

    /// Broadcasts a single audio payload to all ready clients.
    func broadcastAudioPayload(_ payload: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            let packet = AudioCastProtocol.packetize(payload)

            for (id, client) in self.clients {
                guard client.isReady, client.hasSentHeader else { continue }
                client.connection.send(content: packet, completion: .contentProcessed({ [weak self] error in
                    if let error {
                        self?.publish { self?.lastError = "Send failed: \(error.localizedDescription)" }
                        self?.queue.async { [weak self] in
                            self?.removeClient(id)
                        }
                    }
                }))
            }
        }
    }

    // MARK: - Private

    private func startOnQueue() {
        guard listener == nil else { return }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            let newListener = try NWListener(using: parameters)
            newListener.service = NWListener.Service(
                name: Host.current().localizedName ?? "AudioCast",
                type: AudioCastProtocol.serviceType,
                domain: nil,
                txtRecord: nil
            )

            newListener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state, listener: newListener)
            }

            newListener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }

            listener = newListener
            newListener.start(queue: queue)
        } catch {
            publish { [weak self] in
                self?.lastError = "Failed to start server: \(error.localizedDescription)"
            }
        }
    }

    private func stopOnQueue() {
        listener?.cancel()
        listener = nil

        for (_, client) in clients {
            client.connection.cancel()
        }
        clients.removeAll()
        headerData = nil

        publish { [weak self] in
            self?.isRunning = false
            self?.port = nil
            self?.connectedClientCount = 0
        }
    }

    private func handleListenerState(_ state: NWListener.State, listener: NWListener) {
        switch state {
        case .ready:
            let newPort = listener.port.map { UInt16($0.rawValue) }
            publish { [weak self] in
                self?.isRunning = true
                self?.port = newPort
                self?.lastError = nil
            }
        case .failed(let error):
            publish { [weak self] in
                self?.lastError = "Server failed: \(error.localizedDescription)"
            }
            stopOnQueue()
        case .cancelled:
            publish { [weak self] in
                self?.isRunning = false
                self?.port = nil
            }
        default:
            break
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        clients[id] = Client(connection: connection, isReady: false, hasSentHeader: false)
        let count = clients.count
        publish { [weak self] in
            self?.connectedClientCount = count
        }

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self else { return }
                self.handleConnectionState(state, id: id)
            }
        }

        connection.start(queue: queue)
    }

    private func handleConnectionState(_ state: NWConnection.State, id: ObjectIdentifier) {
        switch state {
        case .ready:
            if var client = clients[id] {
                client.isReady = true
                clients[id] = client
            }
            flushHeadersIfNeeded()

        case .failed, .cancelled:
            removeClient(id)

        default:
            break
        }
    }

    private func flushHeadersIfNeeded() {
        guard let headerData else { return }

        for (id, client) in clients {
            guard client.isReady, !client.hasSentHeader else { continue }

            client.connection.send(content: headerData, completion: .contentProcessed({ [weak self] error in
                guard let self else { return }
                if let error {
                    self.publish { [weak self] in
                        self?.lastError = "Header send failed: \(error.localizedDescription)"
                    }
                    self.removeClient(id)
                    return
                }

                self.queue.async { [weak self] in
                    guard let self else { return }
                    if var updated = self.clients[id] {
                        updated.hasSentHeader = true
                        self.clients[id] = updated
                    }
                }
            }))
        }
    }

    private func removeClient(_ id: ObjectIdentifier) {
        if let client = clients.removeValue(forKey: id) {
            client.connection.cancel()
        }

        let count = clients.count
        publish { [weak self] in
            self?.connectedClientCount = count
        }
    }

    private func publish(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}
