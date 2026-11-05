import Foundation
import Testing

@testable import MountainCore

@Suite("Object keys keep remote folder bytes and store local names as NFC")
struct KeyNormalizationTests {
  private let nfdFolder = "テ\u{3099}ータ/"

  @Test("A destination prefix listed in NFD is kept byte for byte")
  func keepsRemotePrefixBytes() throws {
    let key = try ObjectKey.make(prefix: nfdFolder, relativePath: "e\u{301}.mov")
    #expect(key.utf8.starts(with: nfdFolder.utf8))
    #expect(Array(key.utf8.dropFirst(nfdFolder.utf8.count)) == Array("é.mov".utf8))
  }

  @Test("Bare prefixes still gain a separator")
  func joinsBarePrefixes() throws {
    #expect(try ObjectKey.make(prefix: "backup", relativePath: "a.txt") == "backup/a.txt")
    #expect(try ObjectKey.make(prefix: "/backup/", relativePath: "a.txt") == "backup/a.txt")
    #expect(try ObjectKey.make(prefix: "", relativePath: "a.txt") == "a.txt")
  }

  @Test("Renamed keys stay NFC and keep the folder bytes")
  func suffixedKeepsNormalization() {
    let renamed = ObjectKey.suffixed("動画/ガイド.mov", ordinal: 2)
    #expect(Array(renamed.utf8) == Array("動画/ガイド 2.mov".precomposedStringWithCanonicalMapping.utf8))
    let inNFDFolder = ObjectKey.suffixed(nfdFolder + "clip.mov", ordinal: 3)
    #expect(Array(inNFDFolder.utf8) == Array((nfdFolder + "clip 3.mov").utf8))
    #expect(Array(ObjectKey.suffixed("a/パ", ordinal: 2).utf8) == Array("a/パ 2".utf8))
    #expect(ObjectKey.suffixed("a/.env", ordinal: 2) == "a/.env 2")
    #expect(ObjectKey.suffixed("a.b/file", ordinal: 2) == "a.b/file 2")
  }
}

@Suite("Finding an existing folder before creating one")
struct ExistingFolderTests {
  private func listing(_ names: [String]) -> FolderListing {
    FolderListing(
      path: .root,
      folders: names.map {
        RemoteEntry(key: $0 + "/", name: $0, kind: .folder, size: nil, lastModified: nil)
      },
      files: [], isTruncated: false)
  }

  @Test("An exact match wins")
  func exactMatch() throws {
    let typed = try FolderPath.root.appending("データ")
    #expect(listing(["データ"]).existingFolder(matching: typed)?.prefix == "データ/")
  }

  @Test("A folder stored in NFD is reused when the same name is typed in NFC")
  func canonicalMatchOpensStoredBytes() throws {
    let stored = "テ\u{3099}ータ"
    let typed = try FolderPath.root.appending("データ")
    let found = listing([stored]).existingFolder(matching: typed)
    #expect(found.map { Array($0.prefix.utf8) } == Array((stored + "/").utf8))
  }

  @Test("No match means a new folder is needed")
  func noMatch() throws {
    #expect(listing(["写真"]).existingFolder(matching: try FolderPath.root.appending("動画")) == nil)
  }
}
