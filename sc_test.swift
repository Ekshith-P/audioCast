import Foundation
import ScreenCaptureKit
import CoreMedia

class AudioHandler: NSObject, SCStreamOutput, SCStreamDelegate {
    var stream: SCStream?
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            print("Received audio buffer with \(CMSampleBufferGetNumSamples(sampleBuffer)) samples")
            var blockBuffer: CMBlockBuffer?
            var audioBufferList = AudioBufferList()
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: &audioBufferList,
                bufferListSize: MemoryLayout<AudioBufferList>.size,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            print("Status: \(status)")
            exit(0)
        } else {
            print("Received video frame")
        }
    }
    
    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { return }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.width = 16
        config.height = 16
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        let q = DispatchQueue(label: "q")
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: q)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
        try await s.startCapture()
        self.stream = s
    }
}

let handler = AudioHandler()
Task {
    do {
        try await handler.start()
        print("Started")
    } catch {
        print("Error: \(error)")
    }
}
RunLoop.main.run(until: Date().addingTimeInterval(5))
