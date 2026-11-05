import Testing

@testable import MountainCore

private struct DomainFailure: Error {}

/// Records the system calls in order and fails or holds the ones a test asks for.
@MainActor
private final class FakeFinderSystem: FinderDomainSystem {
  var record: FinderDomainRecord
  var registered: [FinderDomainState]
  var failing: Set<String> = []
  var holdsAdd = false
  private(set) var events: [String] = []
  private var held: [CheckedContinuation<Void, Never>] = []

  init(enabled: Bool = false, registered: [String] = [], for connection: FinderConnection? = nil) {
    record = FinderDomainRecord(isEnabled: enabled, connection: connection)
    self.registered = registered.map { FinderDomainState(id: $0, userEnabled: true) }
  }

  var isHolding: Bool { !held.isEmpty }
  var signals: Int { events.filter { $0.hasPrefix("signal") }.count }

  func domains() async throws -> [FinderDomainState] {
    if failing.contains("domains") { throw DomainFailure() }
    return registered
  }

  func addDomain(_ id: String) async throws {
    events.append("add \(id)")
    if holdsAdd { await withCheckedContinuation { held.append($0) } }
    if failing.contains("add \(id)") { throw DomainFailure() }
    registered.append(FinderDomainState(id: id, userEnabled: true))
  }

  func removeDomain(_ id: String) async throws {
    events.append("remove \(id)")
    if failing.contains("remove \(id)") { throw DomainFailure() }
    registered.removeAll { $0.id == id }
  }

  func signalDomain(_ id: String) { events.append("signal \(id)") }

  func publish(_ connection: FinderConnection?) {
    events.append("publish \(connection?.bucket ?? "none")")
  }

  func release() {
    holdsAdd = false
    let waiting = held
    held = []
    for continuation in waiting { continuation.resume() }
  }
}

/// Lets a test decide when each poll interval ends.
@MainActor
private final class ManualSleeper {
  private(set) var requests: [Duration] = []
  private var waiting: [CheckedContinuation<Void, Never>] = []

  var isWaiting: Bool { !waiting.isEmpty }

  func sleep(for duration: Duration) async throws {
    requests.append(duration)
    await withCheckedContinuation { waiting.append($0) }
    try Task.checkCancellation()
  }

  func wake() {
    let woken = waiting
    waiting = []
    for continuation in woken { continuation.resume() }
  }
}

private let account = String(repeating: "a", count: 32)

private func connection(
  _ bucket: String, account: String = account, jurisdiction: String = "standard",
  accessKeyID: String = "key"
) -> FinderConnection {
  FinderConnection(
    accountID: account, bucket: bucket, jurisdiction: jurisdiction, accessKeyID: accessKeyID)
}

@MainActor
private func makeController(_ system: FakeFinderSystem, sleeper: ManualSleeper = ManualSleeper())
  -> FinderDomainController
{
  FinderDomainController(system: system, pollInterval: .seconds(90)) {
    try await sleeper.sleep(for: $0)
  }
}

/// Gives the controller's own tasks a chance to run.
@MainActor
private func settle(until condition: () -> Bool = { false }) async {
  for _ in 0..<200 where !condition() { await Task.yield() }
}

@Suite @MainActor struct FinderDomainControllerTests {
  @Test func nothingChangesBeforeTheConnectionIsKnown() async {
    let system = FakeFinderSystem(enabled: true, registered: ["drive"], for: connection("drive"))
    let controller = makeController(system)
    await controller.refresh()
    await controller.setEnabled(true)
    #expect(system.events.isEmpty)
    #expect(system.registered.map(\.id) == ["drive"])
    #expect(system.record.connection == connection("drive"))
  }

  @Test func switchingBucketsRemovesTheOldDomainBeforeTheExtensionSeesTheNewBucket() async {
    let system = FakeFinderSystem(enabled: true, registered: ["photos"], for: connection("photos"))
    let controller = makeController(system)
    await controller.connectionDidChange(to: connection("drive"))
    #expect(system.events == ["remove photos", "publish drive", "add drive"])
    #expect(system.record.connection == connection("drive"))
    #expect(controller.status == .on(userEnabled: true))
    #expect(controller.domainID == "drive")
  }

  @Test func failedRemovalKeepsTheOldConnectionUntilARetrySucceeds() async {
    let system = FakeFinderSystem(enabled: true, registered: ["photos"], for: connection("photos"))
    system.failing = ["remove photos"]
    let controller = makeController(system)
    await controller.connectionDidChange(to: connection("drive"))
    #expect(system.events == ["remove photos"])
    #expect(system.record.connection == connection("photos"))
    guard case .failed(let message) = controller.status else {
      Issue.record("Expected failure, got \(controller.status)")
      return
    }
    #expect(!message.isEmpty)
    system.failing = []
    await controller.refresh()
    #expect(system.events == ["remove photos", "remove photos", "publish drive", "add drive"])
    #expect(controller.status == .on(userEnabled: true))
  }

  @Test func anotherAccountOrJurisdictionReplacesADomainOfTheSameName() async {
    let system = FakeFinderSystem(enabled: true, registered: ["drive"], for: connection("drive"))
    let controller = makeController(system)
    await controller.connectionDidChange(to: connection("drive", jurisdiction: "eu"))
    #expect(system.events == ["remove drive", "publish drive", "add drive"])
    #expect(system.record.connection == connection("drive", jurisdiction: "eu"))
    let other = String(repeating: "b", count: 32)
    await controller.connectionDidChange(
      to: connection("drive", account: other, jurisdiction: "eu"))
    #expect(system.events.suffix(3) == ["remove drive", "publish drive", "add drive"])
    #expect(system.record.connection?.accountID == other)
  }

  @Test func domainOfUnknownOriginIsReplaced() async {
    let system = FakeFinderSystem(enabled: true, registered: ["drive"])
    let controller = makeController(system)
    await controller.connectionDidChange(to: connection("drive"))
    #expect(system.events == ["remove drive", "publish drive", "add drive"])
  }

  @Test func newAccessKeyForTheSameBucketKeepsTheDomain() async {
    let system = FakeFinderSystem(enabled: true, registered: ["drive"], for: connection("drive"))
    let controller = makeController(system)
    await controller.connectionDidChange(to: connection("drive", accessKeyID: "rotated"))
    #expect(system.events == ["publish drive"])
    #expect(system.record.connection == connection("drive", accessKeyID: "rotated"))
    #expect(controller.status == .on(userEnabled: true))
  }

  @Test func turnedOffFinderOnlyPublishesTheConnection() async {
    let system = FakeFinderSystem()
    let controller = makeController(system)
    await controller.connectionDidChange(to: connection("drive"))
    #expect(system.events == ["publish drive"])
    #expect(controller.status == .off)
    #expect(controller.domainID == nil)
  }

  @Test func missingConnectionRemovesDomainsAndClearsTheExtensionConfiguration() async {
    let system = FakeFinderSystem(enabled: true, registered: ["drive"], for: connection("drive"))
    let controller = makeController(system)
    await controller.connectionDidChange(to: nil)
    #expect(system.events == ["remove drive", "publish none"])
    #expect(system.record.connection == nil)
    #expect(controller.status == .off)
  }

  @Test func refreshDoesNotPublishAgain() async {
    let system = FakeFinderSystem(enabled: true)
    let controller = makeController(system)
    await controller.connectionDidChange(to: connection("drive"))
    await controller.refresh()
    await controller.refresh()
    #expect(system.events == ["publish drive", "add drive"])
  }

  @Test func enablingRemembersTheChoiceAndShowsProgress() async {
    let system = FakeFinderSystem()
    let controller = makeController(system)
    var changes = 0
    controller.onChange = { changes += 1 }
    await controller.connectionDidChange(to: connection("drive"))
    system.holdsAdd = true
    let enabling = Task { await controller.setEnabled(true) }
    await settle { system.isHolding }
    #expect(controller.isEnabled)
    #expect(system.record.isEnabled)
    #expect(controller.status == .enabling)
    system.release()
    await enabling.value
    #expect(controller.status == .on(userEnabled: true))
    #expect(system.events == ["publish drive", "add drive"])
    #expect(system.record.connection == connection("drive"))
    #expect(changes >= 3)
  }

  @Test func disablingRemovesTheDomain() async {
    let system = FakeFinderSystem(enabled: true, registered: ["drive"], for: connection("drive"))
    let controller = makeController(system)
    await controller.connectionDidChange(to: connection("drive"))
    await controller.setEnabled(false)
    #expect(system.events == ["publish drive", "remove drive"])
    #expect(system.record == FinderDomainRecord(isEnabled: false, connection: nil))
    #expect(controller.status == .off)
  }

  @Test func togglingWhileSwitchingBucketsRunsOneChangeAtATime() async {
    let system = FakeFinderSystem()
    let controller = makeController(system)
    await controller.connectionDidChange(to: connection("drive"))
    system.holdsAdd = true
    let enabling = Task { await controller.setEnabled(true) }
    await settle { system.isHolding }
    let switching = Task { await controller.connectionDidChange(to: connection("photos")) }
    await settle()
    #expect(system.events == ["publish drive", "add drive"])
    system.release()
    await enabling.value
    await switching.value
    #expect(
      system.events == [
        "publish drive", "add drive", "remove drive", "publish photos", "add photos",
      ])
    #expect(system.record.connection == connection("photos"))
  }

  @Test func pollingSignalsTheDomainEveryIntervalWhileShown() async {
    let sleeper = ManualSleeper()
    let system = FakeFinderSystem(enabled: true)
    let controller = makeController(system, sleeper: sleeper)
    #expect(!controller.isPolling)
    await controller.connectionDidChange(to: connection("drive"))
    await settle { sleeper.isWaiting }
    #expect(controller.isPolling)
    #expect(sleeper.requests == [.seconds(90)])
    #expect(system.signals == 0)
    sleeper.wake()
    await settle { sleeper.requests.count == 2 }
    #expect(system.events.last == "signal drive")
    await controller.setEnabled(false)
    #expect(!controller.isPolling)
    sleeper.wake()
    await settle()
    #expect(system.signals == 1)
    #expect(sleeper.requests.count == 2)
  }

  @Test func pollingStopsWhenTheDomainFails() async {
    let system = FakeFinderSystem(enabled: true)
    system.failing = ["add drive"]
    let controller = makeController(system)
    await controller.connectionDidChange(to: connection("drive"))
    guard case .failed = controller.status else {
      Issue.record("Expected failure, got \(controller.status)")
      return
    }
    #expect(!controller.isPolling)
    #expect(system.record.connection == nil)
    system.failing = []
    await controller.refresh()
    #expect(controller.isPolling)
    system.failing = ["domains"]
    await controller.refresh()
    #expect(!controller.isPolling)
  }

  @Test func changesAreSignalledOnlyWhileTheDomainIsShown() async {
    let system = FakeFinderSystem()
    let controller = makeController(system)
    await controller.connectionDidChange(to: connection("drive"))
    controller.signalChanges()
    #expect(system.signals == 0)
    await controller.setEnabled(true)
    controller.signalChanges()
    #expect(system.events.last == "signal drive")
  }
}
