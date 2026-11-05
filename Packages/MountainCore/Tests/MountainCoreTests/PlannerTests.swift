import Foundation
import Testing

@testable import MountainCore

@Suite struct PlannerTests {
  @Test func boundariesAndLargeFiles() throws {
    #expect(try MultipartPlan(size: 0).usesMultipart == false)
    #expect(try MultipartPlan(size: 64 * 1_048_576 - 1).usesMultipart == false)
    #expect(try MultipartPlan(size: 64 * 1_048_576).usesMultipart)
    let plan = try MultipartPlan(size: 50 * 1_073_741_824)
    #expect(plan.partSize == 64 * 1_048_576)
    #expect(plan.partCount == 800)
    #expect(throws: UploadError.self) { try MultipartPlan(size: Int64.max) }
    #expect(throws: UploadError.self) { try MultipartPlan(size: -1) }
  }

  @Test func unicodeAndSuffixes() throws {
    #expect(
      try ObjectKey.make(prefix: "backup/", relativePath: "素材/e\u{301}.mov") == "backup/素材/é.mov")
    #expect(ObjectKey.suffixed("backup/file.tar.gz", ordinal: 2) == "backup/file.tar 2.gz")
    #expect(ObjectKey.suffixed(".hidden", ordinal: 2) == ".hidden 2")
    #expect(throws: UploadError.self) { try ObjectKey.make(prefix: "a/../b", relativePath: "x") }
  }
}
