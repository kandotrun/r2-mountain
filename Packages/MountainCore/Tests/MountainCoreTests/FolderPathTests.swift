import Foundation
import Testing

@testable import MountainCore

@Suite struct FolderNameTests {
  @Test func trimsAndNormalizesToNFC() throws {
    #expect(try FolderName.validate("  素材\n") == "素材")
    #expect(try FolderName.validate("\u{3000}写真\t") == "写真")
    let normalized = try FolderName.validate("Cafe\u{301}")
    #expect(Array(normalized.utf8) == Array("Caf\u{E9}".utf8))
  }

  @Test func rejectsInvalidNames() {
    #expect(throws: FolderNameError.empty) { try FolderName.validate("") }
    #expect(throws: FolderNameError.empty) { try FolderName.validate(" \n\t ") }
    #expect(throws: FolderNameError.containsSlash) { try FolderName.validate("a/b") }
    #expect(throws: FolderNameError.containsSlash) { try FolderName.validate("/") }
    #expect(throws: FolderNameError.reserved) { try FolderName.validate(".") }
    #expect(throws: FolderNameError.reserved) { try FolderName.validate(" .. ") }
    #expect(throws: FolderNameError.invalidCharacters) { try FolderName.validate("a\u{0}b") }
    #expect(throws: FolderNameError.invalidCharacters) { try FolderName.validate("a\tb") }
    #expect(throws: FolderNameError.invalidCharacters) { try FolderName.validate("x\u{7F}") }
    #expect(throws: FolderNameError.invalidCharacters) { try FolderName.validate("x\u{85}y") }
  }

  @Test func slashIsDetectedEvenWhenCombinedWithAMark() {
    #expect(throws: FolderNameError.containsSlash) { try FolderName.validate("a/\u{301}b") }
  }

  @Test func allowsDotsInsideNames() throws {
    #expect(try FolderName.validate("...") == "...")
    #expect(try FolderName.validate(".config") == ".config")
  }

  @Test func limitsNameToKeyLengthIncludingSlash() throws {
    #expect(try FolderName.validate(String(repeating: "a", count: 1023)).utf8.count == 1023)
    #expect(throws: FolderNameError.tooLong) {
      try FolderName.validate(String(repeating: "a", count: 1024))
    }
    #expect(throws: FolderNameError.tooLong) {
      try FolderName.validate(String(repeating: "あ", count: 342))
    }
  }

  @Test func errorsHaveJapaneseDescriptions() {
    #expect(FolderNameError.empty.localizedDescription == "フォルダ名を入力してください。")
    #expect(FolderNameError.containsSlash.localizedDescription == "フォルダ名に「/」は使えません。")
    #expect(FolderNameError.reserved.localizedDescription == "「.」や「..」はフォルダ名に使えません。")
    #expect(FolderNameError.invalidCharacters.localizedDescription == "フォルダ名に制御文字は使えません。")
    #expect(FolderNameError.tooLong.localizedDescription == "フォルダのパスが長すぎます（1024バイトまで）。")
  }
}

@Suite struct FolderPathTests {
  @Test func rootHasNoComponents() {
    let root = FolderPath.root
    #expect(root.components.isEmpty)
    #expect(root.prefix == "")
    #expect(root.isRoot)
    #expect(root.name == nil)
    #expect(root.parent == nil)
    #expect(root.lineage == [root])
    #expect(root.description == "")
  }

  @Test func componentsBuildPrefixAndNavigation() throws {
    let path = try FolderPath(components: ["backup", " 素材 "])
    #expect(path.components == ["backup", "素材"])
    #expect(path.prefix == "backup/素材/")
    #expect(path.description == "backup/素材/")
    #expect(!path.isRoot)
    #expect(path.name == "素材")
    #expect(path.parent == (try FolderPath(components: ["backup"])))
    #expect(path.parent?.parent == .root)
    #expect(
      path.lineage == [.root, try FolderPath(components: ["backup"]), path])
  }

  @Test func componentInitializerValidatesEveryName() {
    #expect(throws: FolderNameError.reserved) { try FolderPath(components: ["a", ".."]) }
    #expect(throws: FolderNameError.containsSlash) { try FolderPath(components: ["a/b"]) }
    #expect(throws: FolderNameError.empty) { try FolderPath(components: [""]) }
  }

  @Test func totalPrefixIsLimitedTo1024Bytes() throws {
    let half = String(repeating: "a", count: 511)
    #expect(try FolderPath(components: [half, half]).prefix.utf8.count == 1024)
    #expect(throws: FolderNameError.tooLong) { try FolderPath(components: [half, half + "a"]) }
    let base = try FolderPath(components: [half])
    #expect(try base.appending(half).prefix.utf8.count == 1024)
    #expect(throws: FolderNameError.tooLong) { try base.appending(half + "a") }
  }

  @Test func appendingValidatesAndNormalizes() throws {
    let path = try FolderPath.root.appending(" e\u{301}t\u{E9} ").appending("2026")
    #expect(Array(path.prefix.utf8) == Array("\u{E9}t\u{E9}/2026/".utf8))
    #expect(throws: FolderNameError.containsSlash) { try FolderPath.root.appending("a/b") }
    #expect(throws: FolderNameError.empty) { try FolderPath.root.appending("  ") }
  }

  @Test func prefixParsingIsLenientAboutSlashes() throws {
    #expect(FolderPath(prefix: "") == .root)
    #expect(FolderPath(prefix: "/") == .root)
    #expect(FolderPath(prefix: "a/b/") == (try FolderPath(components: ["a", "b"])))
    #expect(FolderPath(prefix: "/a//b") == (try FolderPath(components: ["a", "b"])))
    #expect(FolderPath(prefix: "写真/2026")?.prefix == "写真/2026/")
  }

  @Test func prefixParsingSplitsOnSlashBytes() throws {
    let path = try #require(FolderPath(prefix: "a/\u{301}b/"))
    #expect(path.components.count == 2)
    #expect(Array(path.prefix.utf8) == Array("a/\u{301}b/".utf8))
  }

  @Test func prefixParsingRejectsInvalidComponents() {
    #expect(FolderPath(prefix: "a/../b/") == nil)
    #expect(FolderPath(prefix: "./") == nil)
    #expect(FolderPath(prefix: "a/\u{0}/") == nil)
    #expect(FolderPath(prefix: "a/b\n/") == nil)
    #expect(FolderPath(prefix: String(repeating: "a/", count: 513)) == nil)
  }

  @Test func prefixParsingKeepsStoredNamesByteExact() throws {
    // Trimming or normalizing would point at another S3 prefix; rejecting would hide the folder.
    for stored in [
      "Project /", " a/b\u{3000}/", "Cafe\u{301}/", "テ\u{3099}ータ/写真/", "a/ /", " .. /",
    ] {
      let path = try #require(FolderPath(prefix: stored))
      #expect(Array(path.prefix.utf8) == Array(stored.utf8))
    }
    let padded = try #require(FolderPath(prefix: "Project /"))
    #expect(padded.name == "Project ")
    #expect(try padded.appending(" 2026 ").prefix == "Project /2026/")
    #expect(padded.lineage.map(\.prefix) == ["", "Project /"])
  }

  @Test func equalityComparesBytesNotCanonicalEquivalence() throws {
    let composed = try #require(FolderPath(prefix: "Caf\u{E9}/"))
    let decomposed = try #require(FolderPath(prefix: "Cafe\u{301}/"))
    #expect(composed != decomposed)
    #expect(Set([composed, decomposed]).count == 2)
    #expect(composed == (try FolderPath(components: ["Cafe\u{301}"])))
  }

  @Test func codableRoundTripsAndValidatesOnDecode() throws {
    let path = try FolderPath(components: ["backup", "素材"])
    let data = try JSONEncoder().encode([path, .root])
    #expect(try JSONDecoder().decode([FolderPath].self, from: data) == [path, .root])
    let stored = try #require(FolderPath(prefix: "Project /テ\u{3099}ータ/"))
    let decoded = try JSONDecoder().decode(
      FolderPath.self, from: try JSONEncoder().encode(stored))
    #expect(Array(decoded.prefix.utf8) == Array(stored.prefix.utf8))
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode([FolderPath].self, from: Data(#"["a/../"]"#.utf8))
    }
  }

  @Test func hashableUsesComponents() throws {
    let set: Set<FolderPath> = [
      try FolderPath(components: ["a"]), FolderPath(prefix: "/a/")!, .root,
    ]
    #expect(set.count == 2)
  }
}
