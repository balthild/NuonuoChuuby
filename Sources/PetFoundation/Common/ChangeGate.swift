/// Emits only when a value changes, collapsing a run of identical values into one.
public struct ChangeGate<Value: Equatable> {
	private var last: Value?

	public init() {}

	/// True the first time a value is seen, and again whenever it changes.
	public mutating func emits(_ value: Value) -> Bool {
		guard value != last else { return false }
		last = value
		return true
	}

	public mutating func reset() {
		last = nil
	}
}
