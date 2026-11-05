import Foundation
import Testing

@testable import MountainCore

@Suite struct JournalTests {
  @Test func corruptionIsIsolatedAndPermissionsArePrivate() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = JournalStore(directory: root)
    try store.prepare()
    try Data("broken".utf8).write(to: root.appendingPathComponent("broken.json"))
    try Data("{\"version\":99}".utf8).write(to: root.appendingPathComponent("future.json"))
    let recovered = try store.load()
    #expect(recovered.jobs.isEmpty)
    #expect(recovered.warnings.count == 2)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("future.json").path))
    #expect(
      !FileManager.default.fileExists(atPath: root.appendingPathComponent("broken.json").path))
    let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
  }

  @Test func deleteRemovesOnlyThatJournalAndToleratesMissingFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = JournalStore(directory: root)
    let kept = makeJob(.paused)
    let removed = makeJob(.completed)
    try store.save(kept)
    try store.save(removed)
    try store.delete(removed.id)
    #expect(journalFiles(root) == [kept.id.uuidString + ".json"])
    #expect(try store.load().jobs == [kept])
    try store.delete(removed.id)
    try JournalStore(directory: root.appendingPathComponent("absent")).delete(kept.id)
  }

  @Test func folderImportSkipsLinksAndMacMetadata() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for name in ["normal.txt", ".hidden", ".DS_Store", "._normal.txt"] {
      try Data("hello".utf8).write(to: root.appendingPathComponent(name))
    }
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("loop"), withDestinationURL: root)
    let imported = try SourceImporter.collect([root])
    #expect(Set(imported.sources.map { $0.url.lastPathComponent }) == ["normal.txt", ".hidden"])
    #expect(imported.skipped.contains(".DS_Store"))
    #expect(imported.skipped.contains("loop"))
    #expect(imported.sources.allSatisfy { $0.relativePath.hasPrefix(root.lastPathComponent + "/") })
  }
}
