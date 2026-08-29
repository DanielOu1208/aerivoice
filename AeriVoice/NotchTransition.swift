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

enum NotchFrameInterpolator {
  static func frame(
    from startFrame: CGRect, to targetFrame: CGRect, progress: CGFloat, screenFrame: CGRect
  ) -> CGRect {
    let width = startFrame.width + (targetFrame.width - startFrame.width) * progress
    let height = startFrame.height + (targetFrame.height - startFrame.height) * progress
    return CGRect(
      x: screenFrame.midX - width / 2, y: screenFrame.maxY - height, width: width, height: height)
  }

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
