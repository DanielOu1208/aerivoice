import AppKit
import SwiftUI

enum NotchTransitionCurve: Equatable {
  case spring
  case easeOut
}

struct NotchTransitionPlan: Equatable {
  static let openDuration: TimeInterval = 0.26
  static let closeDuration: TimeInterval = 0.16
  static let reduceMotionDuration: TimeInterval = 0.08
  static let openSpring = Spring(settlingDuration: openDuration, dampingRatio: 0.84)

  let isOpening: Bool
  let duration: TimeInterval
  let curve: NotchTransitionCurve
  let reducesMotion: Bool

  init(isOpening: Bool, reducesMotion: Bool) {
    self.isOpening = isOpening
    self.reducesMotion = reducesMotion
    if reducesMotion {
      duration = Self.reduceMotionDuration
      curve = .easeOut
    } else if isOpening {
      duration = Self.openDuration
      curve = .spring
    } else {
      duration = Self.closeDuration
      curve = .easeOut
    }
  }

  func progress(at elapsedTime: TimeInterval) -> CGFloat {
    guard duration > 0 else { return 1 }
    if elapsedTime >= duration { return 1 }

    let elapsedTime = max(elapsedTime, 0)
    switch curve {
    case .spring:
      return Self.openSpring.value(
        fromValue: 0, toValue: 1, initialVelocity: 0, time: elapsedTime)
    case .easeOut:
      return UnitCurve.easeOut.value(at: elapsedTime / duration)
    }
  }
}

enum NotchPanelGeometry {
  static func collapsedFrame(for geometry: NotchGeometry, screenFrame: CGRect) -> CGRect {
    let width =
      geometry.physicalNotchWidth > 0
      ? geometry.physicalNotchWidth
      : min(NotchGeometry.physicalNotchReferenceWidth, geometry.frame.width)
    let height = max(1, geometry.physicalNotchHeight)
    return CGRect(
      x: screenFrame.midX - width / 2, y: screenFrame.maxY - height, width: width, height: height)
  }
}

struct NotchMotionSample: Equatable {
  let size: CGSize
  let contentOpacity: CGFloat
}

struct NotchMotionKeyframe {
  let time: TimeInterval
  let sample: NotchMotionSample
}

/// A single clock for geometry and opacity, also usable without a window in tests.
struct NotchMotion {
  let plan: NotchTransitionPlan
  let generation: Int
  let start: NotchMotionSample
  let targetSize: CGSize
  let startTime: TimeInterval

  static func panelFrame(expandedFrame: CGRect) -> CGRect {
    // The .84 damping spring overshoots by less than 1%. Leave 2% plus a pixel
    // so all paths remain inside the resident transparent panel, including rounding.
    let width = ceil(expandedFrame.width * 1.02) + 2
    let height = ceil(expandedFrame.height * 1.02) + 1
    return CGRect(
      x: expandedFrame.midX - width / 2, y: expandedFrame.maxY - height,
      width: width, height: height)
  }

  private var opacityDelay: TimeInterval {
    plan.isOpening && !plan.reducesMotion ? plan.duration * 0.25 : 0
  }

  private var opacityDuration: TimeInterval {
    if plan.reducesMotion { return plan.duration }
    return plan.isOpening ? 0.12 : plan.duration * 0.35
  }

  /// Dense keyframes retain the short spring and exact fade boundaries while the
  /// render server runs the animation independently of the app's display callbacks.
  func keyframes() -> [NotchMotionKeyframe] {
    let intervals = max(1, Int(ceil(plan.duration * 240)))
    var times = (0...intervals).map { Double($0) / Double(intervals) * plan.duration }
    times.append(opacityDelay)
    times.append(min(plan.duration, opacityDelay + opacityDuration))
    return Set(times).sorted().map { NotchMotionKeyframe(time: $0, sample: sample(at: $0)) }
  }

  func sample(at elapsed: TimeInterval) -> NotchMotionSample {
    let progress = plan.reducesMotion ? CGFloat(1) : plan.progress(at: elapsed)
    let fadeTime = min(1, max(0, (elapsed - opacityDelay) / opacityDuration))
    let fadeProgress = CGFloat(UnitCurve.easeOut.value(at: fadeTime))
    let targetOpacity: CGFloat = plan.isOpening ? 1 : 0
    return NotchMotionSample(
      size: CGSize(
        width: start.size.width + (targetSize.width - start.size.width) * progress,
        height: start.size.height + (targetSize.height - start.size.height) * progress),
      contentOpacity: start.contentOpacity + (targetOpacity - start.contentOpacity) * fadeProgress)
  }

  func canComplete(generation: Int, targetVisible: Bool) -> Bool {
    self.generation == generation && plan.isOpening == targetVisible
  }
}
