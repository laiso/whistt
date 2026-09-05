import Foundation

public enum PCM16AudioFixtureError: Error, Equatable {
    case invalidWave
    case unsupportedWaveFormat
    case missingAudioData
}

public enum PCM16AudioFixture {
    public static func load(path: String) throws -> Data {
        try decode(Data(contentsOf: URL(fileURLWithPath: path)))
    }

    public static func decode(_ fileData: Data) throws -> Data {
        guard fileData.count >= 12,
              String(decoding: fileData[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: fileData[8..<12], as: UTF8.self) == "WAVE" else {
            return fileData
        }

        var offset = 12
        var formatIsSupported = false
        var audioData: Data?
        while offset + 8 <= fileData.count {
            let chunkID = String(decoding: fileData[offset..<(offset + 4)], as: UTF8.self)
            let chunkSize = Int(uint32LE(fileData, at: offset + 4))
            let contentStart = offset + 8
            let contentEnd = contentStart + chunkSize
            guard contentEnd <= fileData.count else { throw PCM16AudioFixtureError.invalidWave }

            if chunkID == "fmt " {
                guard chunkSize >= 16 else { throw PCM16AudioFixtureError.invalidWave }
                formatIsSupported = uint16LE(fileData, at: contentStart) == 1
                    && uint16LE(fileData, at: contentStart + 2) == 1
                    && uint32LE(fileData, at: contentStart + 4) == 24_000
                    && uint16LE(fileData, at: contentStart + 14) == 16
            } else if chunkID == "data" {
                audioData = fileData.subdata(in: contentStart..<contentEnd)
            }

            offset = contentEnd + (chunkSize % 2)
        }

        guard formatIsSupported else { throw PCM16AudioFixtureError.unsupportedWaveFormat }
        guard let audioData else { throw PCM16AudioFixtureError.missingAudioData }
        return audioData
    }

    private static func uint16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func uint32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
