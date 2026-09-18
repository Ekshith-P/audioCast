import Foundation
import ScreenCaptureKit
import CoreMedia
import AudioToolbox

struct CapturedAudioChunk {
    let pcmData: Data
    let sampleRate: Double
    let channelCount: Int
    let isInterleaved: Bool
}

final class AudioCaptureManager: NSObject, ObservableObject {
    @Published private(set) var isCapturing: Bool = false
    @Published var lastError: String?

    var onAudioChunk: ((CapturedAudioChunk) -> Void)?

    private let sampleQueue = DispatchQueue(label: "AudioCaptureManager.sampleQueue")
    private var stream: SCStream?

    func start() async {
        guard !isCapturing else { return }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                await MainActor.run {
                    self.lastError = "No display found for capture."
                }
                return
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])

            let config = SCStreamConfiguration()
            config.capturesAudio = true
            
            // ScreenCaptureKit on macOS 13/14 requires a valid .screen output if we are capturing
            // to prevent CMSampleBuffer audio stalls (the err=-12737).
            // We keep native resolution but drop to 1 frame per second to save CPU bandwidth.
            config.showsCursor = false
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let newStream = SCStream(filter: filter, configuration: config, delegate: self)
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)

            try await newStream.startCapture()

            await MainActor.run {
                self.stream = newStream
                self.isCapturing = true
                self.lastError = nil
            }
        } catch {
            await MainActor.run {
                self.lastError = "Failed to start capture: \(error.localizedDescription)"
                self.isCapturing = false
                self.stream = nil
            }
        }
    }

    func stop() async {
        guard isCapturing else { return }
        do {
            try await stream?.stopCapture()
        } catch {
            // best-effort
        }
        await MainActor.run {
            self.stream = nil
            self.isCapturing = false
        }
    }
}

// MARK: - SCStreamOutput

extension AudioCaptureManager: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        guard let chunk = Self.convertToFloat32PlanarStereo(sampleBuffer: sampleBuffer) else { return }
        onAudioChunk?(chunk)
    }

    private static func convertToFloat32PlanarStereo(sampleBuffer: CMSampleBuffer) -> CapturedAudioChunk? {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        guard let formatDesc = sampleBuffer.formatDescription,
              let asbdPtr = formatDesc.audioStreamBasicDescription else {
            return nil
        }

        let asbd = asbdPtr
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        guard isFloat, asbd.mBitsPerChannel == 32 else { return nil }

        let inputChannels = max(1, Int(asbd.mChannelsPerFrame))
        let sampleRate = asbd.mSampleRate
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        var payload: Data?

        try? sampleBuffer.withAudioBufferList { abl, blockBuffer -> Void in
            let bytesPerSample = MemoryLayout<Float>.size
            let frames = frameCount

            if isNonInterleaved {
                guard abl.count >= 1 else { return }

                // Channel 0
                let ch0 = abl[0]
                guard let ch0Ptr = ch0.mData else { return }
                let ch0Bytes = Int(ch0.mDataByteSize)
                let left = Data(bytes: ch0Ptr, count: ch0Bytes)

                // Channel 1 (optional)
                let ch1Bytes: Data
                if abl.count >= 2, let ch1Ptr = abl[1].mData {
                    ch1Bytes = Data(bytes: ch1Ptr, count: Int(abl[1].mDataByteSize))
                } else {
                    ch1Bytes = left
                }

                var combined = Data(capacity: left.count + ch1Bytes.count)
                combined.append(left)
                combined.append(ch1Bytes)
                payload = combined

            } else {
                guard let buffer0 = abl.first, let basePtr = buffer0.mData else { return }

                let interleavedFloatPtr = basePtr.assumingMemoryBound(to: Float.self)

                var leftData = Data(count: frames * bytesPerSample)
                var rightData = Data(count: frames * bytesPerSample)

                leftData.withUnsafeMutableBytes { leftBytes in
                    rightData.withUnsafeMutableBytes { rightBytes in
                        guard let leftPtr = leftBytes.bindMemory(to: Float.self).baseAddress,
                              let rightPtr = rightBytes.bindMemory(to: Float.self).baseAddress else {
                            return
                        }

                        for i in 0..<frames {
                            let base = i * inputChannels
                            let l = interleavedFloatPtr[base]
                            let r = inputChannels > 1 ? interleavedFloatPtr[base + 1] : l
                            leftPtr[i] = l
                            rightPtr[i] = r
                        }
                    }
                }

                var combined = Data(capacity: leftData.count + rightData.count)
                combined.append(leftData)
                combined.append(rightData)
                payload = combined
            }
        }

        guard let finalPayload = payload else { return nil }

        return CapturedAudioChunk(
            pcmData: finalPayload,
            sampleRate: sampleRate,
            channelCount: 2,
            isInterleaved: false
        )
    }
}

// MARK: - SCStreamDelegate

extension AudioCaptureManager: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.lastError = "Capture stopped: \(error.localizedDescription)"
            self.isCapturing = false
            self.stream = nil
        }
    }
}
