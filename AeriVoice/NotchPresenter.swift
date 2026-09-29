import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class NotchViewModel: ObservableObject {
  @Published var state = NotchState(phase: .idle)
  @Published var reservedTopHeight: CGFloat = 0
  @Published var contentBandHeight = NotchGeometry.externalFallbackHeight
  @Published var isPresented = false
}

@MainActor
enum NotchPanelPinning {
  static func configure(_ panel: NSPanel) {
    panel.hidesOnDeactivate = false
    panel.isMovable = false
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]
  }

  static func keepOrderedWhileHidden(_ panel: NSPanel) {
    panel.alphaValue = 0
    if !panel.isVisible { panel.orderFrontRegardless() }
  }
}

@MainActor
final class NotchPresenter: NSObject, NotchPresenting {
  private let model: NotchViewModel
  private let panel: NSPanel
  private var hideTask: Task<Void, Never>?
  private var panelDisplayLink: CADisplayLink?
  private var motion: NotchMotion?
  private var visibleSample = NotchMotionSample(size: .zero, contentOpacity: 0)
  private let renderingView: NotchRenderingView
  private var activeGeometry: NotchGeometry?
  private var presentationGeneration = 0
  private var transitionGeneration = 0
  private var targetVisible = false
  #if DEBUG
    private var benchmark: NotchBenchmarkMetrics?
  #endif

  override init() {
    let model = NotchViewModel()
    self.model = model
    let hostingView = NSHostingView(rootView: NotchContentView(model: model))
    hostingView.sizingOptions = []
    hostingView.safeAreaRegions = []
    renderingView = NotchRenderingView(content: hostingView)
    panel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    super.init()
    configurePanel()

    panel.contentView = renderingView
    prewarmPanel()
    NotificationCenter.default.addObserver(
      self, selector: #selector(screenParametersChanged(_:)),
      name: NSApplication.didChangeScreenParametersNotification, object: nil)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  func present(state: NotchState) {
    hideTask?.cancel()
    presentationGeneration += 1
    if model.state != state { model.state = state }
    let wasTargetVisible = targetVisible
    targetVisible = true

    guard !wasTargetVisible else { return }
    guard let (screen, geometry) = resolveGeometry() else {
      targetVisible = false
      return
    }
    activeGeometry = geometry
    updateLayout(for: geometry)

    let collapsedFrame = NotchPanelGeometry.collapsedFrame(
      for: geometry, screenFrame: screen.frame)
    if panel.alphaValue == 0 {
      visibleSample = NotchMotionSample(size: collapsedFrame.size, contentOpacity: 0)
    }
    model.isPresented = true
    panel.alphaValue = 1
    if !panel.isVisible { panel.orderFrontRegardless() }
    beginTransition(isOpening: true, to: geometry.frame.size)
  }

  func hide(after delay: Duration) {
    hideTask?.cancel()
    let generation = presentationGeneration
    hideTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self, self.presentationGeneration == generation else { return }
      self.beginHide()
    }
  }

  #if DEBUG
    /// Candidate-only synthetic rendering exercise. Caller owns writing the returned JSON.
    /// Shows generic statuses only and never starts dictation, microphone, or a provider.
    static func runSyntheticBenchmark(cycles: Int = 30) async throws -> Data {
      let presenter = NotchPresenter()
      presenter.benchmark = NotchBenchmarkMetrics()
      defer {
        presenter.stopTransition()
        presenter.hideTask?.cancel()
        presenter.panel.close()
      }
      for _ in 0..<max(0, cycles) {
        presenter.present(state: NotchState(phase: .recording))
        try await Task.sleep(for: .milliseconds(320))
        presenter.present(state: NotchState(phase: .processing))
        try await Task.sleep(for: .milliseconds(40))
        presenter.beginHide()
        try await Task.sleep(for: .milliseconds(220))
      }
      var metrics = presenter.benchmark ?? NotchBenchmarkMetrics()
      metrics.cycles = max(0, cycles)
      metrics.hiddenDisplayLinkStopped = presenter.panelDisplayLink == nil
      metrics.hiddenPulsePaused = !presenter.model.isPresented
      return try JSONEncoder().encode(metrics)
    }
  #endif

  private func configurePanel() {
    panel.level = .statusBar
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.animationBehavior = .none
    NotchPanelPinning.configure(panel)
  }

  private func prewarmPanel() {
    guard let (screen, geometry) = resolveGeometry() else { return }
    updateLayout(for: geometry)
    visibleSample = NotchMotionSample(
      size: NotchPanelGeometry.collapsedFrame(for: geometry, screenFrame: screen.frame).size,
      contentOpacity: 0)
    renderingView.render(visibleSample)
    panel.contentView?.layoutSubtreeIfNeeded()
    pinHiddenPanel()
  }

  private func beginHide() {
    guard targetVisible else { return }
    targetVisible = false
    guard let screen = panel.screen ?? resolveGeometry()?.0 else {
      stopTransition()
      pinHiddenPanel()
      return
    }
    let geometry = activeGeometry ?? NotchGeometry.calculate(for: screen)
    beginTransition(
      isOpening: false,
      to: NotchPanelGeometry.collapsedFrame(for: geometry, screenFrame: screen.frame).size)
  }

  private func beginTransition(isOpening: Bool, to targetSize: CGSize) {
    let now = CACurrentMediaTime()
    // Core Animation continues between callbacks. Sample its common clock before
    // replacing the old animations, rather than reusing a previous callback's value.
    stopTransition(at: now)
    transitionGeneration += 1
    let plan = NotchTransitionPlan(
      isOpening: isOpening,
      reducesMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    let nextMotion = NotchMotion(
      plan: plan, generation: transitionGeneration, start: visibleSample,
      targetSize: targetSize, startTime: now)
    motion = nextMotion
    visibleSample = nextMotion.sample(at: 0)
    renderingView.animate(nextMotion)
    #if DEBUG
      benchmark?.transitionSetupMilliseconds += (CACurrentMediaTime() - now) * 1_000
    #endif
    let displayLink = panel.displayLink(
      target: self, selector: #selector(advancePanelAnimation(_:)))
    panelDisplayLink = displayLink
    displayLink.add(to: .main, forMode: .common)
  }

  @objc private func advancePanelAnimation(_ displayLink: CADisplayLink) {
    guard displayLink === panelDisplayLink, let motion else { return }
    let now = CACurrentMediaTime()
    // This callback observes completion and diagnostics only. All intermediate
    // paths and opacity are interpolated by Core Animation without app commits.
    #if DEBUG
      benchmark?.record(timestamp: displayLink.timestamp, renderDuration: 0)
      defer { benchmark?.renderMilliseconds += (CACurrentMediaTime() - now) * 1_000 }
    #endif
    guard now - motion.startTime >= motion.plan.duration else { return }
    guard motion.canComplete(generation: transitionGeneration, targetVisible: targetVisible)
    else { return }
    stopTransition(at: now)
    if !motion.plan.isOpening { pinHiddenPanel() }
  }

  private func stopTransition(at time: TimeInterval = CACurrentMediaTime()) {
    panelDisplayLink?.invalidate()
    panelDisplayLink = nil
    if let motion {
      visibleSample = motion.sample(at: max(0, time - motion.startTime))
      renderingView.stopAnimation(at: visibleSample)
    }
    motion = nil
    #if DEBUG
      benchmark?.lastTimestamp = nil
    #endif
  }

  private func pinHiddenPanel() {
    model.isPresented = false
    NotchPanelPinning.keepOrderedWhileHidden(panel)
  }

  private func resolveGeometry() -> (NSScreen, NotchGeometry)? {
    let screen =
      NSScreen.main ?? NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
      ?? NSScreen.screens.first
    return screen.map { ($0, NotchGeometry.calculate(for: $0)) }
  }

  private func updateLayout(for geometry: NotchGeometry) {
    let frame = NotchMotion.panelFrame(expandedFrame: geometry.frame)
    if panel.frame != frame {
      panel.setFrame(frame, display: false)
      #if DEBUG
        benchmark?.panelFrameChanges += 1
      #endif
    }
    renderingView.configure(expandedSize: geometry.frame.size)
    let reservedTopHeight = geometry.isExternalFallback ? 0 : geometry.physicalNotchHeight
    let contentBandHeight = geometry.frame.height - reservedTopHeight
    if model.reservedTopHeight != reservedTopHeight {
      model.reservedTopHeight = reservedTopHeight
    }
    if model.contentBandHeight != contentBandHeight {
      model.contentBandHeight = contentBandHeight
    }
  }

  @objc private func screenParametersChanged(_: Notification) {
    activeGeometry = nil
    stopTransition()
    transitionGeneration += 1

    guard let (screen, geometry) = resolveGeometry() else {
      targetVisible = false
      pinHiddenPanel()
      return
    }
    updateLayout(for: geometry)
    activeGeometry = geometry
    visibleSample = NotchMotionSample(
      size: targetVisible
        ? geometry.frame.size
        : NotchPanelGeometry.collapsedFrame(
          for: geometry, screenFrame: screen.frame
        ).size,
      contentOpacity: targetVisible ? 1 : 0)
    renderingView.render(visibleSample)
    model.isPresented = targetVisible
    if targetVisible {
      panel.alphaValue = 1
      if !panel.isVisible { panel.orderFrontRegardless() }
    } else {
      pinHiddenPanel()
    }
  }
}

#if DEBUG
  private struct NotchBenchmarkMetrics: Encodable {
    var cycles = 0
    var frames = 0
    var panelFrameChanges = 0
    var renderMilliseconds = 0.0
    var transitionSetupMilliseconds = 0.0
    var maximumFrameIntervalMilliseconds = 0.0
    var hiddenDisplayLinkStopped = false
    var hiddenPulsePaused = false
    var lastTimestamp: TimeInterval?

    enum CodingKeys: String, CodingKey {
      case cycles, frames, panelFrameChanges, renderMilliseconds, transitionSetupMilliseconds
      case maximumFrameIntervalMilliseconds, hiddenDisplayLinkStopped, hiddenPulsePaused
    }

    mutating func record(timestamp: TimeInterval, renderDuration: TimeInterval) {
      frames += 1
      renderMilliseconds += renderDuration * 1_000
      if let previous = lastTimestamp {
        maximumFrameIntervalMilliseconds = max(
          maximumFrameIntervalMilliseconds, (timestamp - previous) * 1_000)
      }
      lastTimestamp = timestamp
    }
  }
#endif

private enum NotchStyle {
  static let normalTextOpacity = 0.72
  static let pulseMinimumOpacity = normalTextOpacity * 0.55
  static let pulseMaximumOpacity = 0.82
  static let normalText = Color.white.opacity(normalTextOpacity)
  static let textFont = Font.system(size: 13, weight: .medium)
}

private struct NotchContentView: View {
  @ObservedObject var model: NotchViewModel

  var body: some View {
    VStack(spacing: 0) {
      Color.clear.frame(height: model.reservedTopHeight)
      contentRow
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: model.contentBandHeight)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  @ViewBuilder private var contentRow: some View {
    switch model.state.phase {
    case .starting, .recording:
      if let warning = model.state.warning, model.state.transcript.displayText.isEmpty {
        Text(warning)
          .font(NotchStyle.textFont)
          .foregroundStyle(.orange)
          .lineLimit(1)
      } else if model.state.transcript.displayText.isEmpty {
        PulsingEllipsisLabel(label: "Listening", isPresented: model.isPresented)
      } else {
        LiveTranscriptLine(snapshot: model.state.transcript)
      }
    case .processing, .cleaning, .inserting:
      PulsingEllipsisLabel(label: "Refining", isPresented: model.isPresented)
    case .success:
      if let warning = model.state.warning {
        Text(warning)
          .font(NotchStyle.textFont)
          .foregroundStyle(.orange)
          .lineLimit(1)
      } else {
        Image(systemName: "checkmark")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.green)
      }
    case .error(let message):
      HStack(spacing: 6) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        Text(message)
          .foregroundStyle(NotchStyle.normalText)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .font(NotchStyle.textFont)
    case .idle: EmptyView()
    }
  }
}

private struct PulsingEllipsisLabel: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let label: String
  let isPresented: Bool

  private let cycleDuration = 1.8 / 1.75

  var body: some View {
    let characters = Array(label + "...")
    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !isPresented)) {
      context in
      HStack(alignment: .firstTextBaseline, spacing: 0) {
        ForEach(characters.indices, id: \.self) { index in
          Text(String(characters[index]))
            .opacity(opacity(for: index, outOf: characters.count, at: context.date))
        }
      }
    }
    .font(NotchStyle.textFont)
    .foregroundStyle(.white)
  }

  private func opacity(for index: Int, outOf characterCount: Int, at date: Date) -> Double {
    guard !reduceMotion else { return NotchStyle.normalTextOpacity }
    let progress = date.timeIntervalSinceReferenceDate / cycleDuration
    let phaseOffset = Double(index) / Double(characterCount)
    let wave = (sin(2 * .pi * (progress - phaseOffset)) + 1) / 2
    let focusedWave = pow(wave, 3)
    return NotchStyle.pulseMinimumOpacity
      + ((NotchStyle.pulseMaximumOpacity - NotchStyle.pulseMinimumOpacity) * focusedWave)
  }
}

private struct LiveTranscriptLine: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let snapshot: TranscriptSnapshot

  private let endAnchor = "live-transcript-end"

  var body: some View {
    let tail = TranscriptTail.make(from: snapshot)
    ViewThatFits(in: .horizontal) {
      transcriptText(tail)
        .fixedSize(horizontal: true, vertical: false)

      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 0) {
            transcriptText(tail)
              .fixedSize(horizontal: true, vertical: false)
            Color.clear.frame(width: 1, height: 1).id(endAnchor)
          }
        }
        .onAppear { proxy.scrollTo(endAnchor, anchor: .trailing) }
        .onChange(of: tail.displayText) { _, _ in
          if reduceMotion {
            proxy.scrollTo(endAnchor, anchor: .trailing)
          } else {
            withAnimation(.easeOut(duration: 0.08)) {
              proxy.scrollTo(endAnchor, anchor: .trailing)
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .center)
    .frame(height: 18)
    .clipped()
  }

  private func transcriptText(_ tail: TranscriptSnapshot) -> some View {
    Text(tail.displayText)
      .font(NotchStyle.textFont)
      .foregroundStyle(NotchStyle.normalText)
  }
}

/// Hosts transcript content at its final size; only compositor properties change per frame.
@MainActor
private final class NotchRenderingView: NSView {
  private let content: NSView
  private let fill = CAShapeLayer()
  private let clip = CAShapeLayer()
  private let rim = CAShapeLayer()

  override var isFlipped: Bool { true }

  init(content: NSView) {
    self.content = content
    super.init(frame: .zero)
    wantsLayer = true
    layer?.addSublayer(fill)
    addSubview(content)
    content.wantsLayer = true
    content.layer?.mask = clip
    layer?.addSublayer(rim)
    fill.fillColor = NSColor.black.cgColor
    rim.fillColor = nil
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(expandedSize: CGSize) {
    let contentFrame = CGRect(
      x: (bounds.width - expandedSize.width) / 2, y: 0,
      width: expandedSize.width, height: expandedSize.height)
    if content.frame != contentFrame { content.frame = contentFrame }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fill.frame = bounds
    rim.frame = bounds
    clip.frame = content.bounds
    let scale = window?.backingScaleFactor ?? 2
    for shape in [fill, clip, rim] { shape.contentsScale = scale }
    rim.lineWidth = 2 / scale
    effectiveAppearance.performAsCurrentDrawingAppearance {
      rim.strokeColor = NSColor.separatorColor.cgColor
    }
    CATransaction.commit()
  }

  private static let animationKey = "notchTransition"

  private struct Paths {
    let fill: CGPath
    let rim: CGPath
    let clip: CGPath
  }

  private func paths(for sample: NotchMotionSample) -> Paths {
    let rect = CGRect(
      x: (bounds.width - sample.size.width) / 2, y: 0,
      width: sample.size.width, height: sample.size.height)
    let shape = BottomRoundedRectangle(radius: min(14, rect.height))
    return Paths(
      fill: shape.path(in: rect).cgPath,
      rim: NotchRimShape(cornerRadius: 14, lineWidth: rim.lineWidth).path(in: rect).cgPath,
      // NSHostingView uses flipped coordinates, matching the top-anchored paths.
      clip: shape.path(in: rect.offsetBy(dx: -content.frame.minX, dy: 0)).cgPath)
  }

  private func apply(paths: Paths, opacity: CGFloat) {
    fill.path = paths.fill
    rim.path = paths.rim
    clip.path = paths.clip
    content.layer?.opacity = Float(opacity)
  }

  func render(_ sample: NotchMotionSample) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    apply(paths: paths(for: sample), opacity: sample.contentOpacity)
    CATransaction.commit()
  }

  func stopAnimation(at sample: NotchMotionSample) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // Replacing the model values and removing animations in the same transaction
    // prevents an interrupted transition from flashing its old target geometry.
    apply(paths: paths(for: sample), opacity: sample.contentOpacity)
    for layer in [fill, rim, clip, content.layer].compactMap({ $0 }) {
      layer.removeAnimation(forKey: Self.animationKey)
    }
    CATransaction.commit()
  }

  func animate(_ motion: NotchMotion) {
    let keyframes = motion.keyframes()
    let paths = keyframes.map { self.paths(for: $0.sample) }
    guard let finalPaths = paths.last, let finalSample = keyframes.last?.sample else { return }
    let keyTimes = keyframes.map { NSNumber(value: $0.time / motion.plan.duration) }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // The model already has the final values when animations are removed at the
    // end. Backwards fill holds the initial values until the shared start time.
    apply(paths: finalPaths, opacity: finalSample.contentOpacity)
    addAnimation(
      to: fill, keyPath: "path", values: paths.map(\.fill), keyTimes: keyTimes, motion: motion)
    addAnimation(
      to: rim, keyPath: "path", values: paths.map(\.rim), keyTimes: keyTimes, motion: motion)
    addAnimation(
      to: clip, keyPath: "path", values: paths.map(\.clip), keyTimes: keyTimes, motion: motion)
    if let contentLayer = content.layer {
      addAnimation(
        to: contentLayer, keyPath: "opacity",
        values: keyframes.map { NSNumber(value: Double($0.sample.contentOpacity)) },
        keyTimes: keyTimes, motion: motion)
    }
    CATransaction.commit()
  }

  private func addAnimation(
    to layer: CALayer, keyPath: String, values: [Any], keyTimes: [NSNumber], motion: NotchMotion
  ) {
    let animation = CAKeyframeAnimation(keyPath: keyPath)
    animation.values = values
    animation.keyTimes = keyTimes
    animation.calculationMode = .linear
    animation.timingFunction = CAMediaTimingFunction(name: .linear)
    animation.duration = motion.plan.duration
    animation.beginTime = layer.convertTime(motion.startTime, from: nil)
    animation.fillMode = .backwards
    animation.isRemovedOnCompletion = true
    layer.add(animation, forKey: Self.animationKey)
  }

}

private struct NotchRimShape: Shape {
  var cornerRadius: CGFloat
  let lineWidth: CGFloat

  var animatableData: CGFloat {
    get { cornerRadius }
    set { cornerRadius = newValue }
  }

  func path(in rect: CGRect) -> Path {
    let inset = lineWidth / 2
    let radius = min(max(cornerRadius - inset, 0), rect.width / 2, rect.height)
    let minX = rect.minX + inset
    let maxX = rect.maxX - inset
    let minY = rect.minY
    let maxY = rect.maxY - inset

    var path = Path()
    path.move(to: CGPoint(x: minX, y: minY))
    path.addLine(to: CGPoint(x: minX, y: maxY - radius))
    path.addQuadCurve(
      to: CGPoint(x: minX + radius, y: maxY),
      control: CGPoint(x: minX, y: maxY))
    path.addLine(to: CGPoint(x: maxX - radius, y: maxY))
    path.addQuadCurve(
      to: CGPoint(x: maxX, y: maxY - radius),
      control: CGPoint(x: maxX, y: maxY))
    path.addLine(to: CGPoint(x: maxX, y: minY))
    return path
  }
}

private struct BottomRoundedRectangle: Shape {
  let radius: CGFloat
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
      control: CGPoint(x: rect.maxX, y: rect.maxY)
    )
    path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
    path.addQuadCurve(
      to: CGPoint(x: rect.minX, y: rect.maxY - radius),
      control: CGPoint(x: rect.minX, y: rect.maxY)
    )
    path.closeSubpath()
    return path
  }
}
