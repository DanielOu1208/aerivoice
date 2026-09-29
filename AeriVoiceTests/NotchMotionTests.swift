import AppKit
import XCTest

@testable import AeriVoice

final class NotchMotionTests: XCTestCase {
  private let collapsed = CGSize(width: 220, height: 38)
  private let expanded = CGSize(width: 360, height: 72)

  func testInterruptedCloseReopensFromRenderedGeometryAndOpacity() {
    let close = NotchMotion(
      plan: .init(isOpening: false, reducesMotion: false), generation: 1,
      start: .init(size: expanded, contentOpacity: 1), targetSize: collapsed, startTime: 0)
    let visible = close.sample(at: 0.025)
    XCTAssertGreaterThan(visible.contentOpacity, 0)
    XCTAssertLessThan(visible.contentOpacity, 1)
    let reopen = NotchMotion(
      plan: .init(isOpening: true, reducesMotion: false), generation: 2,
      start: visible, targetSize: expanded, startTime: 0.025)
    XCTAssertEqual(reopen.sample(at: 0), visible)
    XCTAssertFalse(close.canComplete(generation: 2, targetVisible: true))
    XCTAssertFalse(close.canComplete(generation: 1, targetVisible: true))
    XCTAssertTrue(reopen.canComplete(generation: 2, targetVisible: true))
    XCTAssertEqual(reopen.sample(at: 0.26), .init(size: expanded, contentOpacity: 1))
  }

  func testRepeatedInterruptionsStayInsideFixedPanel() {
    let frame = CGRect(x: -1000, y: 800, width: expanded.width, height: expanded.height)
    let panel = NotchMotion.panelFrame(expandedFrame: frame)
    XCTAssertEqual(panel.midX, frame.midX)
    XCTAssertEqual(panel.maxY, frame.maxY)
    var sample = NotchMotionSample(size: collapsed, contentOpacity: 0)
    for index in 0..<120 {
      let opening = index.isMultiple(of: 2)
      let motion = NotchMotion(
        plan: .init(isOpening: opening, reducesMotion: false), generation: index,
        start: sample, targetSize: opening ? expanded : collapsed, startTime: 0)
      for time in stride(from: 0.0, through: motion.plan.duration, by: 0.001) {
        let rendered = motion.sample(at: time)
        XCTAssertLessThan(rendered.size.width, panel.width)
        XCTAssertLessThan(rendered.size.height, panel.height)
        XCTAssertTrue((0...1).contains(rendered.contentOpacity))
      }
      sample = motion.sample(at: Double(index % 13 + 1) * 0.01)
    }
  }

  func testReduceMotionSnapsGeometryAndFadesForEightyMilliseconds() {
    let motion = NotchMotion(
      plan: .init(isOpening: true, reducesMotion: true), generation: 1,
      start: .init(size: collapsed, contentOpacity: 0.2), targetSize: expanded, startTime: 0)
    XCTAssertEqual(motion.sample(at: 0).size, expanded)
    XCTAssertEqual(motion.sample(at: 0).contentOpacity, 0.2)
    XCTAssertGreaterThan(motion.sample(at: 0.04).contentOpacity, 0.2)
    XCTAssertEqual(motion.sample(at: 0.08).contentOpacity, 1)
  }

  func testOpeningKeyframesIncludeFadeBoundariesAndSpringOvershoot() {
    let motion = NotchMotion(
      plan: .init(isOpening: true, reducesMotion: false), generation: 1,
      start: .init(size: collapsed, contentOpacity: 0.3), targetSize: expanded, startTime: 100)
    let keyframes = motion.keyframes()
    XCTAssertEqual(keyframes.first?.time, 0)
    XCTAssertEqual(keyframes.first?.sample, .init(size: collapsed, contentOpacity: 0.3))
    XCTAssertEqual(keyframes.last?.time, 0.26)
    XCTAssertEqual(keyframes.last?.sample, .init(size: expanded, contentOpacity: 1))
    XCTAssertTrue(zip(keyframes, keyframes.dropFirst()).allSatisfy { $0.time < $1.time })
    let fadeStart = motion.plan.duration * 0.25
    XCTAssertEqual(keyframes.first { $0.time == fadeStart }?.sample.contentOpacity, 0.3)
    XCTAssertEqual(keyframes.first { $0.time == fadeStart + 0.12 }?.sample.contentOpacity, 1)
    XCTAssertGreaterThan(keyframes.map { $0.sample.size.width }.max() ?? 0, expanded.width)
  }

  func testKeyframeInterpolationTracksMotionForInterruptedTransitions() {
    let opening = NotchMotion(
      plan: .init(isOpening: true, reducesMotion: false), generation: 1,
      start: .init(size: collapsed, contentOpacity: 0), targetSize: expanded, startTime: 100)
    let visible = opening.sample(at: 0.093)
    let closing = NotchMotion(
      plan: .init(isOpening: false, reducesMotion: false), generation: 2,
      start: visible, targetSize: collapsed, startTime: 100.093)
    XCTAssertEqual(closing.keyframes().first?.sample, visible)
    XCTAssertFalse(opening.canComplete(generation: 2, targetVisible: false))

    // Core Animation linearly interpolates adjacent path and opacity keyframes.
    // Bound the approximation across the entire curve, including fade boundaries.
    for motion in [opening, closing] {
      let keyframes = motion.keyframes()
      for (left, right) in zip(keyframes, keyframes.dropFirst()) {
        let exact = motion.sample(at: (left.time + right.time) / 2)
        XCTAssertEqual(
          (left.sample.size.width + right.sample.size.width) / 2,
          exact.size.width, accuracy: 0.5)
        XCTAssertEqual(
          (left.sample.size.height + right.sample.size.height) / 2,
          exact.size.height, accuracy: 0.2)
        XCTAssertEqual(
          (left.sample.contentOpacity + right.sample.contentOpacity) / 2,
          exact.contentOpacity, accuracy: 0.005)
      }
    }
  }

  func testReducedMotionKeyframesKeepGeometryStillThroughFade() {
    for isOpening in [true, false] {
      let motion = NotchMotion(
        plan: .init(isOpening: isOpening, reducesMotion: true), generation: 1,
        start: .init(size: collapsed, contentOpacity: 0.4), targetSize: expanded, startTime: 0)
      let keyframes = motion.keyframes()
      XCTAssertTrue(keyframes.allSatisfy { $0.sample.size == expanded })
      XCTAssertEqual(keyframes.first?.sample.contentOpacity, 0.4)
      XCTAssertEqual(keyframes.last?.sample.contentOpacity, isOpening ? 1 : 0)
      XCTAssertEqual(keyframes.last?.time, 0.08)
    }
  }

}
