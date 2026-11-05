import Testing

@testable import MountainCore

@Suite struct FinderDomainPlanTests {
  @Test func enablingRegistersTheBucket() {
    let plan = FinderDomainPlan(registered: [], bucket: "drive", enabled: true)
    #expect(plan == FinderDomainPlan(remove: [], add: "drive"))
    #expect(!plan.isEmpty)
  }

  @Test func registeredBucketIsLeftAlone() {
    let plan = FinderDomainPlan(registered: ["drive"], bucket: "drive", enabled: true)
    #expect(plan == FinderDomainPlan(remove: [], add: nil))
    #expect(plan.isEmpty)
  }

  @Test func bucketChangeReplacesOtherDomains() {
    #expect(
      FinderDomainPlan(registered: ["old"], bucket: "drive", enabled: true)
        == FinderDomainPlan(remove: ["old"], add: "drive"))
    #expect(
      FinderDomainPlan(registered: ["old", "drive", "older"], bucket: "drive", enabled: true)
        == FinderDomainPlan(remove: ["old", "older"], add: nil))
  }

  @Test func replacingRegistersTheBucketAgain() {
    #expect(
      FinderDomainPlan(
        registered: ["drive", "old"], bucket: "drive", enabled: true, replacing: true)
        == FinderDomainPlan(remove: ["drive", "old"], add: "drive"))
    #expect(
      FinderDomainPlan(registered: [], bucket: "drive", enabled: true, replacing: true)
        == FinderDomainPlan(remove: [], add: "drive"))
    #expect(
      FinderDomainPlan(registered: ["drive"], bucket: "drive", enabled: false, replacing: true)
        == FinderDomainPlan(remove: ["drive"], add: nil))
  }

  @Test func disablingRemovesEveryDomain() {
    #expect(
      FinderDomainPlan(registered: ["drive", "old"], bucket: "drive", enabled: false)
        == FinderDomainPlan(remove: ["drive", "old"], add: nil))
  }

  @Test func missingBucketRegistersNothing() {
    #expect(
      FinderDomainPlan(registered: ["old"], bucket: "", enabled: true)
        == FinderDomainPlan(remove: ["old"], add: nil))
  }

  @Test func statusIsOffWhenDisabledOrWithoutBucket() {
    let registered = [FinderDomainState(id: "drive", userEnabled: true)]
    #expect(FinderStatus(enabled: false, bucket: "drive", registered: registered) == .off)
    #expect(FinderStatus(enabled: true, bucket: "", registered: registered) == .off)
  }

  @Test func statusFollowsTheSystemSwitchOfTheBucketDomain() {
    #expect(
      FinderStatus(
        enabled: true, bucket: "drive",
        registered: [
          FinderDomainState(id: "old", userEnabled: false),
          FinderDomainState(id: "drive", userEnabled: true),
        ]) == .on(userEnabled: true))
    #expect(
      FinderStatus(
        enabled: true, bucket: "drive",
        registered: [FinderDomainState(id: "drive", userEnabled: false)])
        == .on(userEnabled: false))
  }

  @Test func statusReportsMissingDomain() {
    let status = FinderStatus(
      enabled: true, bucket: "drive", registered: [FinderDomainState(id: "old", userEnabled: true)])
    guard case .failed(let message) = status else {
      Issue.record("Expected failure, got \(status)")
      return
    }
    #expect(!message.isEmpty)
  }

  @Test func onlyAnActiveDomainIsShownInFinder() {
    #expect(FinderStatus.on(userEnabled: true).isAvailableInFinder)
    #expect(!FinderStatus.on(userEnabled: false).isAvailableInFinder)
    #expect(!FinderStatus.enabling.isAvailableInFinder)
    #expect(!FinderStatus.off.isAvailableInFinder)
    #expect(!FinderStatus.failed("x").isAvailableInFinder)
  }
}
