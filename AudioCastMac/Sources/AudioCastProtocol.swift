import Foundation

enum AudioCastProtocol {
    static let serviceType = "_audiocast._tcp"

    // 16-byte fixed header:
    // 0..3  : "ACST" magic
    // 4     : version
    // 5     : sample format (1 = Float32)
    // 6     : channel count
    // 7     : flags (bit0 = interleaved)
    // 8..11 : sample rate (UInt32, big-endian)
    // 12..15: reserved
    static let headerLength = 16

    enum SampleFormat: UInt8 {
        case float32 = 1
    }

    static func makeHeader(sampleRate: Double, channelCount: Int, isInterleaved: Bool) -> Data {
        let clampedChannels = UInt8(max(1, min(255, channelCount)))
        let flags: UInt8 = isInterleaved ? 0x01 : 0x00
        let sampleRateUInt32 = UInt32(max(1, min(UInt32.max, UInt32(sampleRate.rounded()))))

        var data = Data(capacity: headerLength)
        data.append(contentsOf: [0x41, 0x43, 0x53, 0x54]) // "ACST"
        data.append(0x01) // version
        data.append(SampleFormat.float32.rawValue)
        data.append(clampedChannels)
        data.append(flags)
        data.appendUInt32BE(sampleRateUInt32)
        data.appendUInt32BE(0)
        return data
    }

    static func packetize(_ payload: Data) -> Data {
        var data = Data(capacity: 4 + payload.count)
        data.appendUInt32BE(UInt32(payload.count))
        data.append(payload)
        return data
    }
}

private extension Data {
    mutating func appendUInt32BE(_ value: UInt32) {
        var v = value.bigEndian
        Swift.withUnsafeBytes(of: &v) { raw in
            append(contentsOf: raw)
        }
    }
}
