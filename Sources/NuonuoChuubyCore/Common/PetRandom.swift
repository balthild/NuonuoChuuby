/// The single source of randomness the simulation draws from.
///
/// Every random draw the pet makes — how long she idles, which autonomous action
/// she picks, where she walks, whether a climb slips — comes through here rather
/// than `Double.random`. Left to the global generator, what she does depends on
/// how much randomness anything else in the process drew, which made a couple of
/// physics tests pass or fail by how much the other test suites happened to
/// consume. A test that passes a seed gets the same run every time.
public struct PetRandom: RandomNumberGenerator {
	private var state: UInt64

	/// A reproducible source.
	public init(seed: UInt64) {
		self.state = seed
	}

	/// The running app's source, seeded from the system's entropy.
	public init() {
		self.state = UInt64.random(in: .min ... .max)
	}

	/// SplitMix64: small, fast, and good enough — nothing here depends on the
	/// quality of the sequence beyond it not repeating.
	public mutating func next() -> UInt64 {
		state &+= 0x9E37_79B9_7F4A_7C15
		var z = state
		z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
		z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
		return z ^ (z >> 31)
	}
}
