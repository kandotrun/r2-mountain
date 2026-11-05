import Foundation

struct JournalEnvelope: Codable {
  let version: Int
  let job: UploadJob
}

struct JournalStore: Sendable {
  let directory: URL

  func prepare() throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  }

  func save(_ job: UploadJob) throws {
    do {
      try prepare()
      let data = try JSONEncoder().encode(JournalEnvelope(version: 1, job: job))
      let destination = directory.appendingPathComponent(job.id.uuidString + ".json")
      try data.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: destination.path)
    } catch { throw UploadError.localStorage }
  }

  func delete(_ id: UUID) throws {
    do {
      try FileManager.default.removeItem(
        at: directory.appendingPathComponent(id.uuidString + ".json"))
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      // Already absent.
    } catch { throw UploadError.localStorage }
  }

  func load() throws -> (jobs: [UploadJob], warnings: [String]) {
    try prepare()
    var jobs: [UploadJob] = []
    var warnings: [String] = []
    for url in try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    where url.pathExtension == "json" {
      do {
        let data = try Data(contentsOf: url)
        let header = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard header?["version"] as? Int == 1 else {
          warnings.append("新しいバージョンの転送記録を保持しました。アプリの更新が必要です。")
          continue
        }
        jobs.append(try JSONDecoder().decode(JournalEnvelope.self, from: data).job)
      } catch {
        let quarantine = directory.appendingPathComponent("quarantine", isDirectory: true)
        try FileManager.default.createDirectory(
          at: quarantine, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        try FileManager.default.moveItem(
          at: url,
          to: quarantine.appendingPathComponent(url.lastPathComponent + "." + UUID().uuidString))
        warnings.append("読み取れない転送記録を隔離しました。")
      }
    }
    return (jobs.sorted { $0.createdAt < $1.createdAt }, warnings)
  }
}
