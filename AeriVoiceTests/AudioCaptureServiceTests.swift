import AVFoundation
import XCTest

@testable import AeriVoice

final class AudioCaptureServiceTests: XCTestCase {
  func testConverterAdaptsFromNinetySixToFortyEightKilohertz() throws {
    let converter = try XCTUnwrap(PCM16AudioConverter())
    let ninetySixKilohertz = try makeBuffer(sampleRate: 96_000, frameCount: 960)
    let fortyEightKilohertz = try makeBuffer(sampleRate: 48_000, frameCount: 480)

    let first = try XCTUnwrap(converter.convert(ninetySixKilohertz))
    let second = try XCTUnwrap(converter.convert(fortyEightKilohertz))

    XCTAssertGreaterThan(first.count, 0)
    XCTAssertGreaterThan(second.count, 0)
    XCTAssertEqual(first.count, second.count, accuracy: 16)
  }

  func testConverterAdaptsFromFortyEightToNinetySixKilohertz() throws {
    let converter = try XCTUnwrap(PCM16AudioConverter())
    let fortyEightKilohertz = try makeBuffer(sampleRate: 48_000, frameCount: 480)
    let ninetySixKilohertz = try makeBuffer(sampleRate: 96_000, frameCount: 960)

    let first = try XCTUnwrap(converter.convert(fortyEightKilohertz))
    let second = try XCTUnwrap(converter.convert(ninetySixKilohertz))

    XCTAssertGreaterThan(first.count, 0)
    XCTAssertGreaterThan(second.count, 0)
    XCTAssertEqual(first.count, second.count, accuracy: 16)
  }

  private func makeBuffer(
    sampleRate: Double, frameCount: AVAudioFrameCount
  ) throws -> AVAudioPCMBuffer {
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
        interleaved: false))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
    buffer.frameLength = frameCount
    let samples = try XCTUnwrap(buffer.floatChannelData?[0])
    for frame in 0..<Int(frameCount) {
      samples[frame] = sin(Float(frame) * 0.05)
    }
    return buffer
  }
}
