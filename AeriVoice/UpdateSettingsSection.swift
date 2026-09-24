import SwiftUI

struct UpdateSettingsSection: View {
  @ObservedObject var updater: AppUpdater

  var body: some View {
    Section("Updates") {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 12) {
          Text("Version")
          Text(updater.installedVersion)
            .foregroundStyle(.secondary)
          Spacer(minLength: 8)
          Text(updater.status)
            .font(.caption).foregroundStyle(.secondary)
          Button(updater.menuTitle) { updater.checkForUpdates() }
            .disabled(!updater.canCheck)
            .fixedSize()
        }
        if let checked = updater.lastSuccessfulCheck {
          Text("Last checked \(checked.formatted(date: .abbreviated, time: .shortened))")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Toggle("Automatically check for updates", isOn: Binding(
        get: { updater.automaticallyChecks }, set: { updater.setAutomaticallyChecks($0) }))
        .disabled(!updater.isEnabled)
      Toggle("Show update alerts", isOn: Binding(
        get: { updater.showsAlerts }, set: { updater.setShowsAlerts($0) }))
        .disabled(!updater.isEnabled || !updater.automaticallyChecks)
        .help("Show notifications and update prompts. Turning this off keeps quiet notices in the menu and Settings.")
    }
  }
}
