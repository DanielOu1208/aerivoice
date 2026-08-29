import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class NotchViewModel: ObservableObject {
  @Published var state = NotchState(phase: .idle)
  @Published var reservedTopHeight: CGFloat = 0
  @Published var contentBandHeight = NotchGeometry.externalFallbackHeight
  @Published var contentVisible = false
}

private struct PanelFrameAnimation {
  let plan: NotchTransitionPlan
  let generation: Int
  let startFrame: CGRect
  let targetFrame: CGRect
  let screenFrame: CGRect
  let startTime: TimeInterval
}

@MainActor
final class NotchPresenter: NSObject, NotchPresenting {
  private let model: NotchViewModel
  private let panel: NSPanel
  private var hideTask: Task<Void, Never>?
  private var pendingTransitionCompletionTask: Task<Void, Never>?
  private var panelDisplayLink: CADisplayLink?
  private var panelFrameAnimation: PanelFrameAnimation?
  private var activeGeometry: NotchGeometry?
  private var presentationGeneration = 0
  private var transitionGeneration = 0
  private var targetVisible = false

  override init() {
    let model = NotchViewModel()
    self.model = model
    panel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    super.init()
    configurePanel()

    let hostingView = NSHostingView(rootView: NotchContentView(model: model))
    hostingView.sizingOptions = []
    hostingView.safeAreaRegions = []
    panel.contentView = hostingView
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

    guard !panel.isVisible || !wasTargetVisible else { return }
    guard let (screen, geometry) = resolveGeometry() else { return }
    activeGeometry = geometry
    updateLayout(for: geometry)

    let startFrame =
      panel.isVisible
      ? panel.frame
      : NotchFrameInterpolator.collapsedFrame(for: geometry, screenFrame: screen.frame)
    if !panel.isVisible {
      model.contentVisible = false
      panel.setFrame(startFrame, display: false)
      panel.orderFrontRegardless()
    }
    beginTransition(
      isOpening: true, from: startFrame, to: geometry.frame, screenFrame: screen.frame)
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

  private func configurePanel() {
    panel.level = .statusBar
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.animationBehavior = .none
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]
  }

  private func prewarmPanel() {
    guard let (_, geometry) = resolveGeometry() else { return }
    updateLayout(for: geometry)
    panel.setFrame(geometry.frame, display: false)
    panel.contentView?.layoutSubtreeIfNeeded()
  }

  private func beginHide() {
    guard panel.isVisible else { return }
    targetVisible = false
    let screen = panel.screen ?? resolveGeometry()?.0
    guard let screen else {
      panel.orderOut(nil)
      activeGeometry = nil
      model.contentVisible = false
      return
    }
    let geometry = activeGeometry ?? NotchGeometry.calculate(for: screen)
    activeGeometry = geometry
    let targetFrame = NotchFrameInterpolator.collapsedFrame(
      for: geometry, screenFrame: screen.frame)
    beginTransition(
      isOpening: false, from: panel.frame, to: targetFrame, screenFrame: screen.frame)
  }

  private func beginTransition(
    isOpening: Bool, from startFrame: CGRect, to targetFrame: CGRect, screenFrame: CGRect
  ) {
    stopTransition()
    transitionGeneration += 1
    let generation = transitionGeneration
    let plan = NotchTransitionPlan(
      isOpening: isOpening,
      reducesMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    animateContent(for: plan)

    if plan.reducesMotion {
      panel.setFrame(targetFrame, display: true)
      pendingTransitionCompletionTask = Task { @MainActor [weak self] in
        do {
          try await Task.sleep(for: .seconds(plan.duration))
        } catch {
          return
        }
        self?.completeTransition(plan, generation: generation)
      }
      return
    }

    panelFrameAnimation = PanelFrameAnimation(
      plan: plan, generation: generation, startFrame: startFrame, targetFrame: targetFrame,
      screenFrame: screenFrame, startTime: CACurrentMediaTime())
    let displayLink = panel.displayLink(
      target: self, selector: #selector(advancePanelAnimation(_:)))
    panelDisplayLink = displayLink
    displayLink.add(to: .main, forMode: .common)
  }

  private func animateContent(for plan: NotchTransitionPlan) {
    if plan.reducesMotion {
      withAnimation(.easeOut(duration: plan.duration)) {
        model.contentVisible = plan.isOpening
      }
    } else if plan.isOpening {
      withAnimation(.easeOut(duration: 0.12).delay(plan.duration * 0.25)) {
        model.contentVisible = true
      }
    } else {
      withAnimation(.easeOut(duration: plan.duration * 0.35)) {
        model.contentVisible = false
      }
    }
  }

  @objc private func advancePanelAnimation(_ displayLink: CADisplayLink) {
    guard displayLink === panelDisplayLink, let animation = panelFrameAnimation else { return }
    let elapsedTime = max(displayLink.targetTimestamp - animation.startTime, 0)
    let frame = NotchFrameInterpolator.frame(
      from: animation.startFrame, to: animation.targetFrame,
      progress: animation.plan.progress(at: elapsedTime), screenFrame: animation.screenFrame)
    panel.setFrame(frame, display: false)

    guard elapsedTime >= animation.plan.duration else { return }
    panel.setFrame(animation.targetFrame, display: true)
    stopTransition()
    completeTransition(animation.plan, generation: animation.generation)
  }

  private func stopTransition() {
    panelDisplayLink?.invalidate()
    panelDisplayLink = nil
    panelFrameAnimation = nil
    pendingTransitionCompletionTask?.cancel()
    pendingTransitionCompletionTask = nil
  }

  private func completeTransition(_ plan: NotchTransitionPlan, generation: Int) {
    guard generation == transitionGeneration, targetVisible == plan.isOpening else { return }
    if !plan.isOpening {
      panel.orderOut(nil)
      activeGeometry = nil
      model.contentVisible = false
    }
  }

  private func resolveGeometry() -> (NSScreen, NotchGeometry)? {
    let screen =
      NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
      ?? NSScreen.screens.first
    return screen.map { ($0, NotchGeometry.calculate(for: $0)) }
  }

  private func updateLayout(for geometry: NotchGeometry) {
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
    guard panel.isVisible else { return }
    stopTransition()
    transitionGeneration += 1

    guard targetVisible else {
      panel.orderOut(nil)
      model.contentVisible = false
      return
    }
    guard let (_, geometry) = resolveGeometry() else {
      panel.orderOut(nil)
      targetVisible = false
      model.contentVisible = false
      return
    }
    activeGeometry = geometry
    updateLayout(for: geometry)
    panel.setFrame(geometry.frame, display: true)
    model.contentVisible = true
  }
}

private struct NotchContentView: View {
  @ObservedObject var model: NotchViewModel

  var body: some View {
    let shape = BottomRoundedRectangle(radius: 14)
    ZStack(alignment: .top) {
      shape.fill(.black)
      VStack(spacing: 0) {
        Color.clear.frame(height: model.reservedTopHeight)
        contentRow
          .padding(.horizontal, 16)
          .frame(maxWidth: .infinity)
          .frame(height: model.contentBandHeight)
          .opacity(model.contentVisible ? 1 : 0)
      }
      .clipShape(shape)
      TopSeamGuard()
      NotchRimOverlay(cornerRadius: 14)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder private var contentRow: some View {
    switch model.state.phase {
    case .starting, .recording:
      if let warning = model.state.warning, model.state.transcript.displayText.isEmpty {
        Text(warning)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.orange)
          .lineLimit(1)
      } else if model.state.transcript.displayText.isEmpty {
        Text("Listening…")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.white.opacity(0.62))
      } else {
        LiveTranscriptLine(snapshot: model.state.transcript)
      }
    case .processing:
      statusRow("Finishing…")
    case .cleaning:
      statusRow("Cleaning up…")
    case .inserting:
      statusRow("Inserting…")
    case .success:
      Image(systemName: "checkmark")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.green)
    case .error(let message):
      HStack(spacing: 6) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        Text(message).foregroundStyle(.white).lineLimit(1).truncationMode(.tail)
      }
      .font(.system(size: 12, weight: .medium))
    case .idle: EmptyView()
    }
  }

  private func statusRow(_ label: String) -> some View {
    HStack(spacing: 7) {
      ProgressView().controlSize(.small).tint(.white.opacity(0.72))
      Text(label).foregroundStyle(.white.opacity(0.72))
    }
    .font(.system(size: 12, weight: .medium))
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

  private func transcriptText(_ tail: TranscriptSnapshot) -> Text {
    Text(
      "\(Text(tail.confirmed).foregroundStyle(.white))\(Text(tail.provisional).foregroundStyle(.white.opacity(0.58)))"
    )
    .font(.system(size: 13, weight: .medium))
  }
}

private struct TopSeamGuard: View {
  @Environment(\.displayScale) private var displayScale

  var body: some View {
    Rectangle()
      .fill(.black)
      .frame(height: 1 / max(displayScale, 1))
  }
}

private struct NotchRimOverlay: View {
  @Environment(\.displayScale) private var displayScale

  let cornerRadius: CGFloat

  private var lineWidth: CGFloat { 2 / max(displayScale, 1) }

  var body: some View {
    NotchRimShape(cornerRadius: cornerRadius, lineWidth: lineWidth)
      .stroke(Color(nsColor: .separatorColor), lineWidth: lineWidth)
      .allowsHitTesting(false)
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
