import Foundation

/// What she has to say about herself when nothing has happened.
///
/// Hunger and fullness only drift, so there is no event to hang these on: every
/// event that could carry one — pleading for food, licking an icon, finishing a
/// meal — already speaks for itself. They are what she reports while standing
/// about instead.
public enum PetMoodSpeech {
	/// The line to say, with the tone to say it in, or `nil` when she has nothing
	/// worth saying.
	///
	/// Being full outranks hunger: eating is the only thing that moves either, and
	/// it moves them opposite ways, so a full pet is one that has just eaten
	/// rather than a hungry one. Fasting removes the hunger reports but not this
	/// one, which is still true of her.
	public static func line(
		life: PetLifeState,
		fastingMode: Bool
	) -> (cue: DialogueCue, voice: VoiceCue)? {
		if LifeBehaviorPolicy.isComfortablyFull(life) {
			return (.comfortablyFull, .calm)
		}
		guard !fastingMode else { return nil }
		if life.hunger >= LifeBehaviorPolicy.veryHungryHungerThreshold {
			return (.veryHungry, .sad)
		}
		if life.hunger >= LifeBehaviorPolicy.aBitHungryHungerThreshold {
			return (.aBitHungry, .question)
		}
		return nil
	}
}
