import Foundation
import AVFoundation

@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var isConfigured: Bool = false
    @Published private(set) var isPlaying: Bool = false
    @Published var lastError: String?

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    private var streamFormat: AVAudioFormat?
    private let scheduleQueue = DispatchQueue(label: "AudioPlayer.scheduleQueue")

    init() {
        engine.attach(playerNode)
    }

    func configure(sampleRate: Double, channelCount: Int, isInterleaved: Bool) {
        let channelLayout: AVAudioChannelLayout
        if channelCount == 1 {
            channelLayout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Mono)!
        } else {
            channelLayout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Stereo)!
        }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            interleaved: isInterleaved,
            channelLayout: channelLayout
        )

        do {
            engine.disconnectNodeOutput(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
            engine.prepare()
            try engine.start()

            streamFormat = format
            isConfigured = true
            lastError = nil

            if !playerNode.isPlaying {
                playerNode.play()
            }
            isPlaying = true
        } catch {
            lastError = "Audio engine start failed: \(error.localizedDescription)"
            isConfigured = false
            isPlaying = false
        }
    }

    func stop() {
        scheduleQueue.async { [weak self] in
            self?.playerNode.stop()
            self?.engine.stop()
        }
        isPlaying = false
        isConfigured = false
        streamFormat = nil
    }

    func play(pcmData: Data) {
        guard let format = streamFormat else { return }

        let bytesPerSample = MemoryLayout<Float>.size
        let channels = Int(format.channelCount)
        guard channels > 0 else { return }

        let bytesPerFrame = channels * bytesPerSample
        guard pcmData.count >= bytesPerFrame else { return }

        let frameCount = pcmData.count / bytesPerFrame
        guard frameCount > 0 else { return }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)

        if format.isInterleaved {
            let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            guard let mData = abl.first?.mData else { return }
            pcmData.withUnsafeBytes { raw in
                guard let src = raw.baseAddress else { return }
                memcpy(mData, src, frameCount * bytesPerFrame)
            }
        } else {
            // Planar: one buffer per channel.
            let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let bytesPerChannel = frameCount * bytesPerSample
            for i in 0..<channels {
                guard let mData = abl[i].mData else { continue }
                let offset = i * bytesPerChannel
                pcmData.withUnsafeBytes { raw in
                    guard let src = raw.baseAddress else { return }
                    memcpy(mData, src.advanced(by: offset), bytesPerChannel)
                }
            }
        }

        scheduleQueue.async { [weak self] in
            self?.playerNode.scheduleBuffer(buffer, completionHandler: nil)
        }
    }
}
