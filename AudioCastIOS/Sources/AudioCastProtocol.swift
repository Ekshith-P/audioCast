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

    struct Header {
        let sampleRate: Double
        let channelCount: Int
        let isInterleaved: Bool
        let sampleFormat: SampleFormat
    }

    static func decodeHeader(_ data: Data) -> Header? {
        guard data.count >= headerLength else { return nil }
        let magic = Array(data[0..<4])
        guard magic == [0x41, 0x43, 0x53, 0x54] else { return nil }

        let version = data[4]
        guard version == 0x01 else { return nil }

        guard let sampleFormat = SampleFormat(rawValue: data[5]) else { return nil }

        let channelCount = Int(data[6])
        let flags = data[7]
        let isInterleaved = (flags & 0x01) != 0
        let sampleRate = Double(readUInt32BE(data, offset: 8))

        return Header(
            sampleRate: sampleRate,
            channelCount: max(1, channelCount),
            isInterleaved: isInterleaved,
            sampleFormat: sampleFormat
        )
    }

    static func makeHeader(sampleRate: Double, channelCount: Int, isInterleaved: Bool) -> Data {
        var header = Data(capacity: headerLength)
        // Magic
        header.append(contentsOf: [0x41, 0x43, 0x53, 0x54])
        // Version
        header.append(0x01)
        // Sample format
        header.append(SampleFormat.float32.rawValue)
        // Channel count
        header.append(UInt8(channelCount))
        // Flags
        header.append(isInterleaved ? 0x01 : 0x00)
        // Sample rate
        header.appendUInt32BE(UInt32(sampleRate))
        // Reserved
        header.append(contentsOf: [0, 0, 0, 0])
        return header
    }

    static func packetize(_ payload: Data) -> Data {
        var data = Data(capacity: 4 + payload.count)
        data.appendUInt32BE(UInt32(payload.count))
        data.append(payload)
        return data
    }

    static func readUInt32BE(_ data: Data, offset: Int) -> UInt32 {
        guard data.count >= offset + 4 else { return 0 }
        let b0 = UInt32(data[offset]) << 24
        let b1 = UInt32(data[offset + 1]) << 16
        let b2 = UInt32(data[offset + 2]) << 8
        let b3 = UInt32(data[offset + 3])
        return b0 | b1 | b2 | b3
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
