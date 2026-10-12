import Testing

@testable import NuonuoChuubyCore

/// The ride log is written once per response change, not once per frame.
@Suite("Change gate")
struct ChangeGateTests {
	@Test("A repeated value is emitted only once")
	func repeatedValueEmitsOnce() {
		var gate = ChangeGate<PlatformMotionResponse>()
		// `#expect` cannot take a mutating call, so each result is hoisted.
		let first = gate.emits(.follow)
		let second = gate.emits(.follow)
		let third = gate.emits(.follow)
		#expect(first)
		#expect(!second)
		#expect(!third)
	}

	@Test("A changed value is emitted again")
	func changeEmitsAgain() {
		var gate = ChangeGate<PlatformMotionResponse>()
		let follow = gate.emits(.follow)
		let launch = gate.emits(.launchUpward)
		let repeatLaunch = gate.emits(.launchUpward)
		#expect(follow)
		#expect(launch)
		#expect(!repeatLaunch)
	}

	@Test("Reset makes the next value emit again")
	func resetReemits() {
		var gate = ChangeGate<PlatformMotionResponse>()
		let first = gate.emits(.follow)
		let suppressed = gate.emits(.follow)
		gate.reset()
		let afterReset = gate.emits(.follow)
		#expect(first)
		#expect(!suppressed)
		#expect(afterReset)
	}
}
