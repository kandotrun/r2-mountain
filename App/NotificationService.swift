import Foundation
import MountainCore
import UserNotifications

@MainActor
final class NotificationService {
  func requestPermission() async -> Bool {
    (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]))
      ?? false
  }

  /// Asks once, when the first upload starts, so the prompt has a clear reason.
  func requestPermissionIfUndetermined() async {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    if settings.authorizationStatus == .notDetermined { _ = await requestPermission() }
  }

  func notify(_ job: UploadJob) async {
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    guard
      settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    else {
      return
    }
    let content = UNMutableNotificationContent()
    content.title = job.state == .completed ? "アップロード完了" : "アップロードを確認してください"
    content.body = job.sourceURL.lastPathComponent
    content.sound = .default
    let request = UNNotificationRequest(
      identifier: job.id.uuidString, content: content, trigger: nil)
    try? await center.add(request)
  }
}
