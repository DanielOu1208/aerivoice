import Foundation
import UserNotifications

@MainActor
protocol UpdateNotifying {
  func requestPermission() async
  func post(_ update: AvailableUpdate) async -> Bool
  func clear()
}

@MainActor
final class UpdateNotifications: UpdateNotifying {
  nonisolated static let identifier = "AeriVoice.UpdateAvailable"
  nonisolated static let category = "AERIVOICE_UPDATE"
  nonisolated static let action = "SHOW_AERIVOICE_UPDATE"
  private let center = UNUserNotificationCenter.current()

  func requestPermission() async {
    guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
    _ = try? await center.requestAuthorization(options: [.alert])
  }

  func post(_ update: AvailableUpdate) async -> Bool {
    guard await center.notificationSettings().authorizationStatus == .authorized else { return false }
    let content = UNMutableNotificationContent()
    content.title = "AeriVoice update available"
    content.body = "Version \(update.version) is ready. Click to review and install."
    content.categoryIdentifier = Self.category
    content.userInfo = ["build": update.build]
    do {
      try await center.add(UNNotificationRequest(
        identifier: Self.identifier, content: content, trigger: nil))
      return true
    } catch { return false }
  }

  func clear() {
    center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
    center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
  }
}
