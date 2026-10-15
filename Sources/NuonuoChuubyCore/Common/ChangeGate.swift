/// Emits only when a value changes, collapsing a run of identical values into one.
struct ChangeGate<Value: Equatable> {
	private var last: Value?

	/// True the first time a value is seen, and again whenever it changes.
	mutating func emits(_ value: Value) -> Bool {
		guard value != last else { return false }
		last = value
		return true
	}

	mutating func reset() {
		last = nil
	}
}
