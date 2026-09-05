import XCTest
@testable import WhisttCore

final class PCM16AudioFixtureTests: XCTestCase {
    func testRawPCMIsReturnedUnchanged() throws {
        let raw = Data([0x01, 0x02, 0x03, 0x04])
        XCTAssertEqual(try PCM16AudioFixture.decode(raw), raw)
    }

    func testSupportedWaveExtractsDataAfterUnknownChunk() throws {
        let samples = Data([0x01, 0x02, 0x03, 0x04])
        let wave = makeWave(samples: samples, extraChunk: ("JUNK", Data([0x00, 0x01, 0x02])))
        XCTAssertEqual(try PCM16AudioFixture.decode(wave), samples)
    }

    func testWaveRejectsWrongSampleRate() {
        let wave = makeWave(samples: Data([0x00, 0x00]), sampleRate: 16_000)
        XCTAssertThrowsError(try PCM16AudioFixture.decode(wave)) { error in
            XCTAssertEqual(error as? PCM16AudioFixtureError, .unsupportedWaveFormat)
        }
    }

    func testWaveRejectsTruncatedChunk() {
        var wave = Data("RIFF\0\0\0\0WAVEdata".utf8)
        appendUInt32LE(100, to: &wave)
        XCTAssertThrowsError(try PCM16AudioFixture.decode(wave)) { error in
            XCTAssertEqual(error as? PCM16AudioFixtureError, .invalidWave)
        }
    }

    private func makeWave(
        samples: Data,
        sampleRate: UInt32 = 24_000,
        extraChunk: (String, Data)? = nil
    ) -> Data {
        var body = Data()
        appendChunk(id: "fmt ", data: formatChunk(sampleRate: sampleRate), to: &body)
        if let extraChunk { appendChunk(id: extraChunk.0, data: extraChunk.1, to: &body) }
        appendChunk(id: "data", data: samples, to: &body)

        var wave = Data("RIFF".utf8)
        appendUInt32LE(UInt32(body.count + 4), to: &wave)
        wave.append(Data("WAVE".utf8))
        wave.append(body)
        return wave
    }

    private func formatChunk(sampleRate: UInt32) -> Data {
        var data = Data()
        appendUInt16LE(1, to: &data)
        appendUInt16LE(1, to: &data)
        appendUInt32LE(sampleRate, to: &data)
        appendUInt32LE(sampleRate * 2, to: &data)
        appendUInt16LE(2, to: &data)
        appendUInt16LE(16, to: &data)
        return data
    }

    private func appendChunk(id: String, data: Data, to output: inout Data) {
        output.append(Data(id.utf8))
        appendUInt32LE(UInt32(data.count), to: &output)
        output.append(data)
        if data.count % 2 == 1 { output.append(0) }
    }

    private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8(value >> 8))
    }

    private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }
}
