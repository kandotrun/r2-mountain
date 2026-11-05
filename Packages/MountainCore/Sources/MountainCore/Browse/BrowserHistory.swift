import Foundation

public struct BrowserHistory: Sendable, Equatable {
  public private(set) var current: FolderPath
  private var backStack: [FolderPath] = []
  private var forwardStack: [FolderPath] = []

  public init(current: FolderPath = .root) { self.current = current }

  public var canGoBack: Bool { !backStack.isEmpty }
  public var canGoForward: Bool { !forwardStack.isEmpty }

  public mutating func visit(_ path: FolderPath) {
    guard path != current else { return }
    backStack.append(current)
    current = path
    forwardStack.removeAll()
  }

  @discardableResult public mutating func goBack() -> FolderPath? {
    guard let previous = backStack.popLast() else { return nil }
    forwardStack.append(current)
    current = previous
    return current
  }

  @discardableResult public mutating func goForward() -> FolderPath? {
    guard let next = forwardStack.popLast() else { return nil }
    backStack.append(current)
    current = next
    return current
  }
}
