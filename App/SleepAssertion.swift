import Foundation
import IOKit.pwr_mgt

@MainActor
final class SleepAssertion {
  private var assertion: IOPMAssertionID = 0

  func setActive(_ active: Bool) {
    if active, assertion == 0 {
      IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
        IOPMAssertionLevel(kIOPMAssertionLevelOn),
        "R2 Mountain のアップロード" as CFString,
        &assertion
      )
    } else if !active, assertion != 0 {
      IOPMAssertionRelease(assertion)
      assertion = 0
    }
  }

  deinit {
    if assertion != 0 { IOPMAssertionRelease(assertion) }
  }
}
