import AppKit
import SwiftUI

enum CredentialInput {
  static func pastedValue(from pasteboard: NSPasteboard = .general) -> String? {
    pasteboard.string(forType: .string)
  }
}

struct SettingsPageHeader: View {
  let title: String
  let subtitle: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.system(size: 24, weight: .semibold))
      Text(subtitle).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 22)
    .padding(.top, 20)
    .padding(.bottom, 14)
  }
}

struct ExperimentalBadge: View {
  var body: some View {
    Text("Experimental")
      .font(.caption2.weight(.semibold))
      .foregroundStyle(.orange)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(.orange.opacity(0.12), in: Capsule())
      .accessibilityLabel("Experimental provider")
  }
}

struct VocabularyTagEditor: View {
  @Binding var vocabulary: String

  @State private var draft = ""
  @State private var validationMessage: String?
  @FocusState private var focusedTerm: String?
  @FocusState private var isInputFocused: Bool

  private var terms: [String] { VocabularyNormalizer.parse(vocabulary) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        TextField("", text: $draft, prompt: Text("Add a name or phrase"))
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("Add a name or phrase")
          .focused($isInputFocused)
          .onSubmit(addTerm)
          .onChange(of: draft) { validationMessage = nil }
        Button("Add", action: addTerm)
          .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }

      Group {
        if terms.isEmpty {
          ContentUnavailableView(
            "No dictionary terms",
            systemImage: "text.badge.plus",
            description: Text("Add names and terms AeriVoice should recognize.")
          )
          .frame(maxWidth: .infinity, minHeight: 84)
        } else {
          ScrollView {
            VocabularyTagFlowLayout(spacing: 7) {
              ForEach(terms, id: \.self) { term in
                vocabularyTag(term)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
          }
          .frame(minHeight: 70, maxHeight: 170)
        }
      }
      .background(.background, in: RoundedRectangle(cornerRadius: 9))
      .overlay {
        RoundedRectangle(cornerRadius: 9)
          .stroke(.separator.opacity(0.7), lineWidth: 1)
      }

      HStack(alignment: .firstTextBaseline) {
        if let validationMessage {
          Label(validationMessage, systemImage: "exclamationmark.circle.fill")
            .foregroundStyle(.orange)
        } else {
          Text("Names and phrases are sent to Soniox as recognition hints.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text("\(terms.count) \(terms.count == 1 ? "term" : "terms")")
          .foregroundStyle(.secondary)
      }
      .font(.caption)
    }
  }

  private func vocabularyTag(_ term: String) -> some View {
    HStack(spacing: 5) {
      Text(term)
        .lineLimit(1)
        .truncationMode(.middle)
      Button {
        removeTerm(term)
      } label: {
        Image(systemName: "xmark")
          .font(.caption2.weight(.bold))
          .frame(width: 15, height: 15)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Remove \(term)")
    }
    .padding(.leading, 10)
    .padding(.trailing, 6)
    .padding(.vertical, 5)
    .foregroundStyle(.primary)
    .background(.tint.opacity(focusedTerm == term ? 0.2 : 0.11), in: Capsule())
    .overlay {
      Capsule().stroke(.tint.opacity(focusedTerm == term ? 0.7 : 0), lineWidth: 1)
    }
    .frame(maxWidth: 280)
    .focusable()
    .focused($focusedTerm, equals: term)
    .onTapGesture { focusedTerm = term }
    .onKeyPress(.delete) {
      removeTerm(term)
      return .handled
    }
    .accessibilityElement(children: .contain)
  }

  private func addTerm() {
    switch VocabularyNormalizer.adding(draft, to: vocabulary) {
    case .added(let updated):
      vocabulary = updated.joined(separator: "\n")
      draft = ""
      validationMessage = nil
      isInputFocused = true
    case .empty:
      break
    case .duplicate:
      validationMessage = "That term is already in the dictionary."
      isInputFocused = true
    case .multipleTerms:
      validationMessage = "Add one name or phrase at a time."
      isInputFocused = true
    case .limitExceeded:
      validationMessage = "The dictionary has reached its size limit."
      isInputFocused = true
    }
  }

  private func removeTerm(_ term: String) {
    vocabulary = VocabularyNormalizer.removing(term, from: vocabulary).joined(separator: "\n")
    if focusedTerm == term { focusedTerm = nil }
    validationMessage = nil
  }
}

private struct VocabularyTagFlowLayout: Layout {
  let spacing: CGFloat

  func sizeThatFits(
    proposal: ProposedViewSize, subviews: Subviews, cache: inout Void
  ) -> CGSize {
    layout(subviews: subviews, availableWidth: proposal.width).size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void
  ) {
    let result = layout(subviews: subviews, availableWidth: bounds.width)
    for (index, origin) in result.origins.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
        proposal: .unspecified)
    }
  }

  private func layout(subviews: Subviews, availableWidth: CGFloat?) -> LayoutResult {
    let maximumWidth = availableWidth ?? .greatestFiniteMagnitude
    var origins: [CGPoint] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var contentWidth: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0, x + size.width > maximumWidth {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      origins.append(CGPoint(x: x, y: y))
      contentWidth = max(contentWidth, x + size.width)
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }

    let width = availableWidth ?? contentWidth
    let height = subviews.isEmpty ? 0 : y + rowHeight
    return LayoutResult(origins: origins, size: CGSize(width: width, height: height))
  }

  private struct LayoutResult {
    let origins: [CGPoint]
    let size: CGSize
  }
}

struct CredentialEditorView: View {
  @ObservedObject var model: AppModel
  let kind: CredentialKind
  var allowsRemoval = true

  @State private var candidate = ""
  @State private var isReplacing = false
  @State private var confirmsRemoval = false
  @State private var showsErrorDetails = false
  @FocusState private var isCandidateFocused: Bool

  private var status: CredentialStatus { model.credentialStatus(for: kind) }
  private var hasSavedKey: Bool { model.hasCredential(kind) }
  private var canImportLegacyKey: Bool { model.canImportLegacyCredential(kind) }
  private var apiKeyLabel: String { "\(kind.label) API key" }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text(kind.label).font(.headline)
        if kind == .groq { ExperimentalBadge() }
        Spacer()
        credentialStatus
      }

      Text(description).font(.callout).foregroundStyle(.secondary)

      if canImportLegacyKey {
        HStack(alignment: .center, spacing: 12) {
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text("Beta.1 key found").font(.callout.weight(.medium))
              Text("Import it without pasting it again. macOS may request access once.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          } icon: {
            Image(systemName: "key.fill")
          }
          Spacer()
          Button("Import from beta.1") {
            model.importLegacyCredential(kind)
          }
          .disabled(status == .validating)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
      }

      if hasSavedKey && !isReplacing {
        HStack {
          Button("Replace Key…") { isReplacing = true }
          if allowsRemoval {
            Button("Remove", role: .destructive) { confirmsRemoval = true }
          }
          Spacer()
        }
      } else {
        VStack(alignment: .leading, spacing: 6) {
          Text(apiKeyLabel)
            .font(.subheadline.weight(.medium))
          HStack {
            SecureField(
              hasSavedKey ? "Paste a replacement key" : "Paste your \(kind.label) key",
              text: $candidate
            )
            .textFieldStyle(.roundedBorder)
            .textContentType(.password)
            .focused($isCandidateFocused)
            .accessibilityLabel(apiKeyLabel)
            Button {
              pasteCredential()
            } label: {
              Label("Paste", systemImage: "doc.on.clipboard")
            }
            .help("Paste the \(kind.label) API key from the clipboard")
            .disabled(status == .validating)
            Button(hasSavedKey ? "Verify & Replace" : "Verify & Save") { verifyAndSave() }
              .disabled(
                candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  || status == .validating)
            if hasSavedKey || status == .validating {
              Button("Cancel") {
                model.cancelCredentialValidation(kind)
                candidate = ""
                isReplacing = false
              }
            }
          }
          Text(
            "The key stays hidden and is saved to your Mac’s Keychain only after verification."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }

      if case .error(let message) = status {
        VStack(alignment: .leading, spacing: 5) {
          Label(errorSummary(message), systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
          if message != errorSummary(message) {
            DisclosureGroup("Details", isExpanded: $showsErrorDetails) {
              Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 3)
            }
            .font(.caption)
          }
          if hasSavedKey {
            Text("Your existing verified key is still active.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .alert("Remove \(kind.label) credential?", isPresented: $confirmsRemoval) {
      Button("Cancel", role: .cancel) {}
      Button("Remove", role: .destructive) {
        model.remove(kind)
        candidate = ""
        isReplacing = false
      }
    } message: {
      Text("AeriVoice will stop using this credential until another key is verified.")
    }
    .onChange(of: status) { _, newStatus in
      guard newStatus == .saved else { return }
      candidate = ""
      isReplacing = false
      showsErrorDetails = false
    }
  }

  @ViewBuilder private var credentialStatus: some View {
    switch status {
    case .missing:
      Label("Not connected", systemImage: "circle")
        .foregroundStyle(.secondary)
    case .saved:
      Label("Verified", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
    case .validating:
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Checking…").foregroundStyle(.secondary)
      }
    case .error:
      Label(hasSavedKey ? "Replacement failed" : "Not saved", systemImage: "xmark.circle.fill")
        .foregroundStyle(.red)
    }
  }

  private var description: String {
    switch kind {
    case .soniox:
      "Required for realtime speech transcription. The key is stored only in your Mac’s Keychain."
    case .openRouter:
      "Recommended stable connection for configurable AI transcript cleanup."
    case .groq:
      "Direct Qwen cleanup for evaluation. Models, limits, and behavior may change."
    }
  }

  private func errorSummary(_ message: String) -> String {
    if message.count <= 120 { return message }
    return "AeriVoice couldn’t verify this credential."
  }

  private func verifyAndSave() {
    model.validateAndSave(candidate, kind: kind)
  }

  private func pasteCredential() {
    guard let clipboardValue = CredentialInput.pastedValue() else { return }
    candidate = clipboardValue
    isCandidateFocused = true
  }
}

struct PermissionStatusRow: View {
  let title: String
  let detail: String
  let granted: Bool
  let actionTitle: String
  let action: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
        .foregroundStyle(granted ? .green : .orange)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if granted {
        Text("Allowed").foregroundStyle(.secondary)
      } else {
        Button(actionTitle, action: action)
      }
    }
  }
}
