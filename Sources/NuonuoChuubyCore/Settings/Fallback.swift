/// Names the value a ``Fallback`` property takes when the stored one is unusable.
public protocol FallbackProvider {
	associatedtype Value
	static var fallbackValue: Value { get }
}

/// A value that decodes to a default instead of failing the decode around it.
///
/// `@Fallback<SomeProvider>` on a field means a missing key, an explicit null on a
/// non-optional field, or a value of the wrong type costs that field alone — the rest of
/// the containing type still decodes. Used on every field of a settings file whose reader
/// answers a failed decode by discarding the whole file.
@propertyWrapper
public struct Fallback<T>: Codable
where T: FallbackProvider, T.Value: Codable {
	public var wrappedValue: T.Value

	public init() {
		self.wrappedValue = T.fallbackValue
	}

	public init(wrappedValue: T.Value) {
		self.wrappedValue = wrappedValue
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()

		// `Optional` needs special handling, or it will be always `nil`.
		// Unlike `KeyedDecodingContainer`, specialization doesn't work here.
		// Swift's `Codable` is so fucking annoying. I miss Rust's `serde`.
		if let type = T.Value.self as? any CodableOptional.Type {
			// Do not treat explicit null as a missing key.
			if container.decodeNil() {
				self.wrappedValue = type.none as! T.Value
			} else if let value = try? container.decode(type.wrappedType) {
				self.wrappedValue = value as! T.Value
			} else {
				self.wrappedValue = T.fallbackValue
			}
		} else {
			if let value = try? container.decode(T.Value.self) {
				self.wrappedValue = value
			} else {
				self.wrappedValue = T.fallbackValue
			}
		}
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(wrappedValue)
	}
}

extension Fallback: Sendable
where T.Value: Sendable {}

extension Fallback: Equatable
where T.Value: Equatable {
	public static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.wrappedValue == rhs.wrappedValue
	}
}

extension KeyedDecodingContainer {
	public func decode<T>(_ type: Fallback<T>.Type, forKey key: Key) throws -> Fallback<T>
	where T: FallbackProvider, T.Value: Codable {
		return try decodeIfPresent(type, forKey: key) ?? Fallback()
	}

	public func decode<T, U>(_ type: Fallback<T>.Type, forKey key: Key) throws -> Fallback<T>
	where T: FallbackProvider, T.Value: Codable, T.Value == U? {
		guard contains(key) else { return Fallback() }

		// Do not treat explicit null as a missing key.
		if try decodeNil(forKey: key) {
			return Fallback(wrappedValue: nil)
		}

		// Calling `decode` causes infinite recursion.
		return try decodeIfPresent(type, forKey: key) ?? Fallback()
	}
}

private protocol CodableOptional {
	associatedtype Wrapped: Codable
	static var wrappedType: Wrapped.Type { get }
	static var none: Self { get }
}

extension Optional: CodableOptional
where Wrapped: Codable {
	static var wrappedType: Wrapped.Type { Wrapped.self }
}
