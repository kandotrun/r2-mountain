import Darwin
import Foundation
import MountainCore

enum StartupSetupImporter {
  static func consumeIfRequested(journalDirectory: URL) throws -> SavedR2Settings? {
    let arguments = ProcessInfo.processInfo.arguments
    let indices = arguments.indices.filter { arguments[$0] == "--setup-file" }
    guard !indices.isEmpty else { return nil }
    guard indices.count == 1, let index = indices.first, arguments.indices.contains(index + 1)
    else {
      throw SetupError.invalidFile
    }
    let path = arguments[index + 1]
    var status = stat()
    guard lstat(path, &status) == 0,
      status.st_mode & S_IFMT == S_IFREG,
      status.st_mode & 0o777 == 0o600,
      status.st_uid == geteuid(),
      status.st_size > 0, status.st_size < 16_384
    else { throw SetupError.invalidFile }
    let existing =
      (try? FileManager.default.contentsOfDirectory(
        at: journalDirectory, includingPropertiesForKeys: nil
      )) ?? []
    guard !existing.contains(where: { $0.pathExtension == "json" }) else {
      throw SetupError.savedTransfers
    }
    let file = URL(fileURLWithPath: path)
    let payload: Payload
    do { payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: file)) } catch {
      throw SetupError.invalidFile
    }
    let settings = SavedR2Settings(
      accountID: payload.accountID,
      accessKeyID: payload.accessKeyID,
      bucket: payload.bucket,
      jurisdiction: payload.jurisdiction
    )
    do { try settings.configuration.validate() } catch { throw SetupError.invalidFile }
    guard payload.accessKeyID.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil,
      payload.accessKeyID.caseInsensitiveCompare(payload.accountID) != .orderedSame,
      !payload.secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw SetupError.invalidFile }
    try CredentialStore().save(
      payload.secretAccessKey, accountID: payload.accountID, accessKeyID: payload.accessKeyID
    )
    settings.save()
    do { try FileManager.default.removeItem(at: file) } catch { throw SetupError.cannotRemoveFile }
    return settings
  }

  private struct Payload: Decodable {
    let accountID: String
    let bucket: String
    let jurisdiction: R2Configuration.Jurisdiction
    let accessKeyID: String
    let secretAccessKey: String
  }

  private enum SetupError: LocalizedError {
    case invalidFile, savedTransfers, cannotRemoveFile

    var errorDescription: String? {
      switch self {
      case .invalidFile:
        "接続設定ファイルを読み込めません。所有者、アクセス権、入力項目を確認してください。"
      case .savedTransfers:
        "保存済みの転送があります。接続設定の変更は設定画面から行ってください。"
      case .cannotRemoveFile:
        "接続設定は保存されましたが、一時的な設定ファイルを削除できませんでした。"
      }
    }
  }
}
