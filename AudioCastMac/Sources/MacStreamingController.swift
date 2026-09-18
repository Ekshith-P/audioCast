import Foundation

@MainActor
final class MacStreamingController: ObservableObject {
    @Published private(set) var isBroadcasting: Bool = false
    @Published var lastError: String?

    let server = StreamServer()
    let capture = AudioCaptureManager()

    init() {
        capture.onAudioChunk = { [weak self] chunk in
            guard let self else { return }
            self.server.updateStreamFormat(
                sampleRate: chunk.sampleRate,
                channelCount: chunk.channelCount,
                isInterleaved: chunk.isInterleaved
            )
            print("Sent audio chunk of size \(chunk.pcmData.count) bytes")
            self.server.broadcastAudioPayload(chunk.pcmData)
        }
    }

    func start() {
        guard !isBroadcasting else { return }
        lastError = nil

        server.start()
        Task {
            await capture.start()
            await MainActor.run {
                self.isBroadcasting = self.server.isRunning && self.capture.isCapturing
                self.lastError = self.capture.lastError ?? self.server.lastError
            }
        }
    }

    func stop() {
        guard isBroadcasting else {
            server.stop()
            return
        }

        Task {
            await capture.stop()
            server.stop()
            await MainActor.run {
                self.isBroadcasting = false
            }
        }
    }
}
