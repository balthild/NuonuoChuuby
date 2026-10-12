/// Emits only when a value changes.
///
/// A signal that stays the same for a whole gesture — a dragged window's ride
/// response, say — would otherwise be recorded once per frame. This collapses a
/// run of identical values into a single emission.
struct ChangeGate<Value: Equatable> {
	private var last: Value?

	/// True the first time a value is seen, and again whenever it changes.
	mutating func emits(_ value: Value) -> Bool {
		guard value != last else { return false }
		last = value
		return true
	}

	/// Forgets the last value, so the next one emits afresh.
	mutating func reset() {
		last = nil
	}
}
