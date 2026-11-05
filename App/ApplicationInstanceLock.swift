import Darwin
import Foundation

final class ApplicationInstanceLock {
  private let descriptor: Int32

  init(directory: URL) throws {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    descriptor = open(
      directory.appendingPathComponent("application.lock").path, O_CREAT | O_RDWR, 0o600)
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      close(descriptor)
      throw CocoaError(.fileLocking)
    }
  }

  deinit {
    flock(descriptor, LOCK_UN)
    close(descriptor)
  }
}
