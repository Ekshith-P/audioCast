import Foundation
import Network

final class StreamReceiver: ObservableObject {
    enum Status: Equatable {
        case idle
        case browsing
        case connecting(String)
        case connected(String)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published var lastError: String?

    private let queue = DispatchQueue(label: "StreamReceiver.queue")

    private var browser: NWBrowser?
    private var connection: NWConnection?

    // AudioPlayer is @MainActor; we create it on the main thread and only
    // ever touch it inside Task { @MainActor in }.
    nonisolated(unsafe) private var audioPlayer: AudioPlayer

    init() {
        audioPlayer = MainActor.assumeIsolated { AudioPlayer() }
    }

    private var buffer = Data()
    private var bufferReadIndex: Int = 0

    private var hasParsedHeader = false
    private var expectedPayloadLength: Int?

    func start() {
        DispatchQueue.main.async { [weak self] in
            self?.status = .browsing
            self?.lastError = nil
        }

        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }

        Task { @MainActor [weak self] in
            self?.audioPlayer.stop()
            self?.status = .idle
        }
    }

    func player() -> AudioPlayer { audioPlayer }

    // MARK: - Private

    private func startOnQueue() {
        guard browser == nil else { return }

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let newBrowser = NWBrowser(for: .bonjour(type: AudioCastProtocol.serviceType, domain: nil), using: parameters)

        newBrowser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed(let error) = state {
                self.publish {
                    self.status = .failed("Browse failed: \(error.localizedDescription)")
                    self.lastError = "Browse failed: \(error.localizedDescription)"
                }
                self.stopOnQueue()
            }
        }

        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            guard let first = results.first else { return }
            self.connectOnQueue(to: first.endpoint)
        }

        browser = newBrowser
        newBrowser.start(queue: queue)
    }

    private func stopOnQueue() {
        browser?.cancel()
        browser = nil

        connection?.cancel()
        connection = nil

        buffer.removeAll(keepingCapacity: false)
        bufferReadIndex = 0
        hasParsedHeader = false
        expectedPayloadLength = nil
    }

    private func connectOnQueue(to endpoint: NWEndpoint) {
        guard connection == nil else { return }

        let displayName: String
        if case let .service(name: name, type: _, domain: _, interface: _) = endpoint {
            displayName = name
        } else {
            displayName = "Server"
        }

        publish {
            self.status = .connecting(displayName)
        }

        let parameters = NWParameters.tcp
        let conn = NWConnection(to: endpoint, using: parameters)

        conn.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state, displayName: displayName)
        }

        connection = conn
        conn.start(queue: queue)
    }

    private func handleConnectionState(_ state: NWConnection.State, displayName: String) {
        switch state {
        case .ready:
            publish {
                self.status = .connected(displayName)
                self.lastError = nil
            }
            receiveNext()

        case .failed(let error):
            publish {
                self.status = .failed("Connection failed: \(error.localizedDescription)")
                self.lastError = "Connection failed: \(error.localizedDescription)"
            }
            stopOnQueue()
            Task { @MainActor [weak self] in self?.audioPlayer.stop() }

        case .cancelled:
            publish { self.status = .idle }

        default:
            break
        }
    }

    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.processBuffer()
            }

            if let error {
                self.publish {
                    self.status = .failed("Receive failed: \(error.localizedDescription)")
                    self.lastError = "Receive failed: \(error.localizedDescription)"
                }
                self.stopOnQueue()
                Task { @MainActor [weak self] in self?.audioPlayer.stop() }
                return
            }

            if isComplete {
                self.publish { self.status = .idle }
                self.stopOnQueue()
                Task { @MainActor [weak self] in self?.audioPlayer.stop() }
                return
            }

            self.receiveNext()
        }
    }

    private func processBuffer() {
        while true {
            if !hasParsedHeader {
                guard availableBytes() >= AudioCastProtocol.headerLength else { return }
                let headerData = consumeBytes(AudioCastProtocol.headerLength)

                guard let header = AudioCastProtocol.decodeHeader(headerData) else {
                    publish {
                        self.status = .failed("Invalid stream header")
                        self.lastError = "Invalid stream header"
                    }
                    stopOnQueue()
                    Task { @MainActor [weak self] in self?.audioPlayer.stop() }
                    return
                }

                Task { @MainActor [weak self] in
                    self?.audioPlayer.configure(
                        sampleRate: header.sampleRate,
                        channelCount: header.channelCount,
                        isInterleaved: header.isInterleaved
                    )
                }

                hasParsedHeader = true
                expectedPayloadLength = nil
                continue
            }

            if expectedPayloadLength == nil {
                guard availableBytes() >= 4 else { return }
                let lenData = consumeBytes(4)
                let len = Int(AudioCastProtocol.readUInt32BE(lenData, offset: 0))

                if len <= 0 || len > (8 * 1024 * 1024) {
                    publish {
                        self.status = .failed("Invalid packet length")
                        self.lastError = "Invalid packet length"
                    }
                    stopOnQueue()
                    Task { @MainActor [weak self] in self?.audioPlayer.stop() }
                    return
                }

                expectedPayloadLength = len
            }

            guard let len = expectedPayloadLength else { return }
            guard availableBytes() >= len else { return }

            let payload = consumeBytes(len)
            expectedPayloadLength = nil

            Task { @MainActor [weak self] in
                self?.audioPlayer.play(pcmData: payload)
            }
        }
    }

    private func availableBytes() -> Int {
        buffer.count - bufferReadIndex
    }

    private func consumeBytes(_ count: Int) -> Data {
        let start = bufferReadIndex
        let end = start + count
        let sub = buffer.subdata(in: start..<end)
        bufferReadIndex = end

        // Periodically trim to keep memory stable.
        if bufferReadIndex > 512 * 1024 {
            buffer.removeSubrange(0..<bufferReadIndex)
            bufferReadIndex = 0
        }

        return sub
    }

    private func publish(_ block: @escaping @MainActor () -> Void) {
        Task { @MainActor in block() }
    }
}
