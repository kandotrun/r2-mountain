import Foundation
import Testing

@testable import MountainCore

private func folder(_ prefix: String) -> FolderPath { FolderPath(prefix: prefix)! }

@Suite struct BrowserHistoryTests {
  @Test func startsWithoutNavigation() {
    let history = BrowserHistory()
    #expect(history.current == .root)
    #expect(!history.canGoBack)
    #expect(!history.canGoForward)
    #expect(BrowserHistory(current: folder("a/")).current == folder("a/"))
  }

  @Test func backAndForwardWalkVisitedFolders() {
    var history = BrowserHistory()
    history.visit(folder("a/"))
    history.visit(folder("a/b/"))
    #expect(history.canGoBack)
    #expect(history.goBack() == folder("a/"))
    #expect(history.goBack() == .root)
    #expect(history.goBack() == nil)
    #expect(history.current == .root)
    #expect(history.canGoForward)
    #expect(history.goForward() == folder("a/"))
    #expect(history.goForward() == folder("a/b/"))
    #expect(history.goForward() == nil)
    #expect(history.current == folder("a/b/"))
  }

  @Test func visitingClearsForwardStack() {
    var history = BrowserHistory()
    history.visit(folder("a/"))
    history.goBack()
    history.visit(folder("c/"))
    #expect(!history.canGoForward)
    #expect(history.goBack() == .root)
  }

  @Test func revisitingCurrentFolderIsNoOp() {
    var history = BrowserHistory(current: folder("a/"))
    history.visit(folder("/a"))
    #expect(!history.canGoBack)
    #expect(history == BrowserHistory(current: folder("a/")))
  }
}

@Suite struct RecentFoldersTests {
  @Test func recordsMostRecentFirstWithoutDuplicates() {
    var recents = RecentFolders(limit: 3)
    recents.record(folder("a/"))
    recents.record(.root)
    recents.record(folder("b/"))
    recents.record(folder("a/"))
    #expect(recents.items == [folder("a/"), folder("b/"), .root])
    recents.record(folder("c/"))
    #expect(recents.items == [folder("c/"), folder("a/"), folder("b/")])
  }

  @Test func initializerClampsLimitAndCleansItems() {
    #expect(RecentFolders().limit == 6)
    let clamped = RecentFolders(items: [folder("a/"), folder("b/")], limit: 0)
    #expect(clamped.limit == 1)
    #expect(clamped.items == [folder("a/")])
    let deduped = RecentFolders(items: [folder("a/"), .root, folder("a/"), folder("b/")], limit: 2)
    #expect(deduped.items == [folder("a/"), .root])
  }

  @Test func codableRoundTripsAndDropsInvalidStoredItems() throws {
    let recents = RecentFolders(items: [folder("a/b/"), .root], limit: 4)
    let decoded = try JSONDecoder().decode(
      RecentFolders.self, from: try JSONEncoder().encode(recents))
    #expect(decoded == recents)
    let stored = Data(#"{"items":["a/","../","a/","b/","c/"],"limit":2}"#.utf8)
    let repaired = try JSONDecoder().decode(RecentFolders.self, from: stored)
    #expect(repaired.items == [folder("a/"), folder("b/")])
    #expect(repaired.limit == 2)
    let legacy = try JSONDecoder().decode(RecentFolders.self, from: Data(#"{"items":[]}"#.utf8))
    #expect(legacy.limit == 6)
  }
}
