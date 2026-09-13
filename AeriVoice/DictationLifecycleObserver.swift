import Foundation
import UserNotifications

/// Reports coordinator task bodies, not completion of provider-owned resources.
@MainActor
protocol DictationLifecycleObserving: AnyObject {
  func workStarted(id: UUID, kind: String)
  func workFinished(id: UUID)
}

/// Captured by the task so clearing its handle never reports premature completion.
@MainActor
final class DictationLifecycleWork {
  private let observer: DictationLifecycleObserving
  private let id = UUID()

  init(observer: DictationLifecycleObserving, kind: String) {
    self.observer = observer
    observer.workStarted(id: id, kind: kind)
  }

  func finish() {
    observer.workFinished(id: id)
  }
}

@MainActor
protocol DictationNotificationPosting {
  func postReadinessError(_ error: Error)
}

struct SystemDictationNotifications: DictationNotificationPosting {
  func postReadinessError(_ error: Error) {
    let notification = UNMutableNotificationContent()
    notification.title = "AeriVoice needs attention"
    notification.body = error.localizedDescription
    notification.categoryIdentifier = "OPEN_SETTINGS"
    let request = UNNotificationRequest(
      identifier: UUID().uuidString, content: notification, trigger: nil)
    UNUserNotificationCenter.current().add(request)
  }
}
