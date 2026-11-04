import Foundation
import PetBehaviour
import PetFoundation

@MainActor
extension PetController {
	/// Accepts deleted items, subject to the mode and queue limits, then starts
	/// eating if she is free.
	@discardableResult
	public func enqueueMeals(_ items: [DeletedItem]) -> Int {
		guard profile.supportsFood, PetModePolicy.allowsDeletionMeal(quietMode: quietMode) else {
			return 0
		}

		var acceptedItems: [DeletedItem] = []
		let hadMealsPending = activeMeal != nil || !mealQueue.isEmpty
		for item in items {
			guard
				MealQueuePolicy.canAcceptDeletion(
					queuedCount: mealQueue.count,
					hasActiveDeletionMeal: activeMeal != nil
				)
			else {
				DiagnosticsLog.shared.writeEvent("MealQueueFull", [("Dropped", "1")])
				break
			}
			mealQueue.enqueue(item)
			acceptedItems.append(item)
		}
		guard !acceptedItems.isEmpty else { return 0 }

		if burstTracker.register(detectedAt: Date()) {
			announce(.buffet, voice: .positive, priority: .important)
		} else if hadMealsPending {
			announce(.mealQueueContinues, voice: .positive, priority: .normal)
		} else {
			announce(.mealSpotted, voice: .question, priority: .normal)
		}

		// Their icons go up straight away, whether or not she can set off now.
		mealDelegate?.petController(self, didEnqueueMeals: acceptedItems)

		// Being inside a window is no reason to sit out a meal: she leaves through
		// whichever wall faces the food and runs to it.
		let escaping = WindowEnclosureBehaviorPolicy.shouldEscapeForMeal(
			isEnclosed: enclosure != nil,
			pendingMeals: mealQueue.count
		)
		guard activeMeal == nil else { return acceptedItems.count }
		if escaping {
			_ = beginNextMeal()
			return acceptedItems.count
		}
		// A meal is not something she sleeps through: she is woken for it. The
		// other steps she can be interrupted at are the ones she is not already
		// busy eating in.
		switch state {
		case .sleeping:
			beginWake(forMeal: true)
		case .waking:
			wakeForMeal = true
		case .idle, .curious, .licking:
			_ = beginNextMeal()
		case .running where movementPurpose != .meal:
			_ = beginNextMeal()
		default:
			// She cannot leave yet — airborne, mid-clip, on a wall — so she says she
			// is waiting rather than going silent about the food she just saw.
			announce(.hungryRequestQueued, voice: .question, priority: .normal)
		}
		return acceptedItems.count
	}

	/// Starts walking to the next queued meal. Returns false when there is none.
	@discardableResult
	func beginNextMeal() -> Bool {
		guard activeMeal == nil, !quietMode else { return false }
		guard let item = mealQueue.dequeue() else { return false }

		wakeForMeal = false
		releaseEnclosureForMeal(target: item.anchor)
		activeMeal = item
		targetPoint = item.anchor
		enter(.running, clip: "run", purpose: .meal)
		remainderX = 0
		remainderY = 0
		mealDelegate?.petController(self, didBeginMeal: item)
		DiagnosticsLog.shared.writeEvent(
			"MealRunStarted",
			[
				("Name", item.displayName),
				("Target", "\(Int(item.anchor.x)),\(Int(item.anchor.y))"),
			]
		)
		return true
	}

	/// Sends her to lick an icon when she is hungry but has nothing to eat.
	///
	/// - Parameter ignoringQuietMode: quiet mode is meant to stop this — the original's
	///   own menu item returns silently when it is on — so nothing that speaks for the
	///   user passes this. It is for the launch-argument demo, which has been asked for
	///   explicitly and has no other way to be seen.
	@discardableResult
	public func tryBeginIconLick(manual: Bool, ignoringQuietMode: Bool = false) -> Bool {
		guard profile.supportsFood, ignoringQuietMode || !quietMode else { return false }
		guard WindowEnclosureBehaviorPolicy.allowsIconLick(isEnclosed: enclosure != nil) else {
			DiagnosticsLog.shared.writeEvent(
				"IconLickSuppressedInEnclosure",
				[("Manual", "\(manual)")]
			)
			return false
		}

		let display = displaySpace.display(containing: foot) ?? displaySpace.displays.first
		guard let workArea = display?.visibleFrame else { return false }
		// The real Finder positions when Accessibility allows them; otherwise the
		// Finder-default layout approximation, which is not where the icons are.
		let realIcons = desktopIcons?.positions ?? []
		// Whether these are the real Finder positions decides what she has to say
		// when the lick finishes; the guessed grid is somewhere to lick, not
		// something to taste.
		iconLickUsedRealIcons = !realIcons.isEmpty
		let candidates =
			realIcons.isEmpty ? DesktopIconGrid.positions(count: 12, in: workArea) : realIcons
		guard
			let target = IconLickTargetSelector.choose(
				candidates: candidates,
				origin: lickPoint,
				randomUnit: Double.random(in: 0..<1, using: &random)
			)
		else { return false }

		targetPoint = target
		enter(.running, clip: "run", purpose: .iconLick)
		remainderX = 0
		remainderY = 0
		announce(
			manual ? .manualIconLick : .curiousIconLick,
			voice: manual ? .aggrieved : .question,
			priority: manual ? .important : .normal
		)
		return true
	}

	/// Walks in two dimensions to a free-standing target (a meal or an icon).
	func updateMealRun(_ delta: Double) {
		let isMeal = movementPurpose == .meal
		let contact = isMeal ? mouthPoint : lickPoint

		let deltaX = targetPoint.x - contact.x
		let deltaY = targetPoint.y - contact.y
		let distance = (deltaX * deltaX + deltaY * deltaY).squareRoot()

		if distance < 18 || stateElapsed > 6.5 {
			foot.x += deltaX
			foot.y += deltaY
			if isMeal {
				beginChomp()
			} else {
				beginLickAnimation()
			}
			return
		}

		let speed =
			min(max(distance * 3.2, 250), isMeal ? 720 : 640) * displayScale
			* profile.movementSpeedMultiplier
		let desiredX = deltaX / distance * speed
		let desiredY = deltaY / distance * speed
		let response = min(1, delta * 7.5)
		velocity.x += (desiredX - velocity.x) * response
		velocity.y += (desiredY - velocity.y) * response

		let movementX = SubpixelMotion.takeWholePixels(velocity.x * delta, remainder: &remainderX)
		let movementY = SubpixelMotion.takeWholePixels(velocity.y * delta, remainder: &remainderY)
		foot.x += Double(movementX)
		foot.y += Double(movementY)
		if abs(velocity.x) > 8 { facing = velocity.x < 0 ? -1 : 1 }
	}

	private func beginChomp() {
		enter(.chomping, clip: "chomp", facing: 1)
		remainderX = 0
		remainderY = 0
		if let item = activeMeal, !item.exactAnchor {
			announce(.suction, voice: .positive, priority: .normal)
		} else if !mealQueue.isEmpty {
			// Biting into a meal with more still waiting behind it.
			announce(.anotherBite, voice: .positive, priority: .normal)
		}
	}

	private func beginLickAnimation() {
		enter(.licking, clip: "lick")
		remainderX = 0
		remainderY = 0
	}

	func beginHungryPlea() {
		enter(.rolling, clip: "hungry", purpose: MovementPurpose.unset, transientSeconds: 1.6)
		announce(.hungryRoll, voice: .sad, priority: .important)
	}

	func beginRoll() {
		enter(
			.rolling,
			clip: "roll",
			purpose: MovementPurpose.unset,
			transientSeconds: animator.durationSeconds
		)
		announce(.hungryRoll, voice: .sad, priority: .important)
	}

	func reportMealVisual() {
		guard state == .chomping, let item = activeMeal else { return }
		let geometry = profile.geometry
		var visual = MealConsumptionAnimation.visual(
			elapsed: stateElapsed,
			from: PixelPoint(x: geometry.mouthCanvasX, y: geometry.mouthCanvasY),
			to: PixelPoint(
				x: geometry.suctionMouthCanvasX,
				y: geometry.suctionMouthCanvasY
			)
		)
		// The path is authored in canvas units; the presenter draws in screen points.
		visual.center = screenPoint(canvasX: visual.center.x, canvasY: visual.center.y)
		mealDelegate?.petController(self, didUpdateMeal: item, visual: visual)
	}

	/// Turns an interrupted meal back into a queued one rather than losing it.
	///
	/// `reason` is only for the log: from the outside, a meal she abandoned and a
	/// meal she never went for look exactly the same.
	func requeueActiveMeal(reason: String) {
		guard let item = activeMeal else { return }
		mealQueue.requeueAtFront(item)
		activeMeal = nil
		mealDelegate?.petController(self, didFinishMeal: item)
		DiagnosticsLog.shared.writeEvent(
			"MealRequeued",
			[("Name", item.displayName), ("Reason", reason)]
		)
	}

	/// Drops every meal, in progress and queued, and takes their icons down.
	///
	/// `reason` is for the log; unlike an interrupted meal these are not coming
	/// back, so they are worth telling apart from one that was merely postponed.
	func discardAllMeals(reason: String) {
		var dropped: [DeletedItem] = []
		if let item = activeMeal {
			dropped.append(item)
			activeMeal = nil
		}
		while let item = mealQueue.dequeue() {
			dropped.append(item)
		}
		guard !dropped.isEmpty else { return }
		for item in dropped {
			mealDelegate?.petController(self, didFinishMeal: item)
		}
		DiagnosticsLog.shared.writeEvent(
			"MealsDiscarded",
			[("Reason", reason), ("Count", "\(dropped.count)")]
		)
	}

	func completeActiveMeal() {
		guard let item = activeMeal else { return }
		activeMeal = nil

		life.registerMeal(
			path: item.originalPath,
			nourishment: Double.random(in: 6...14, using: &random)
		)
		persistLifeStateQuietly()
		mealDelegate?.petController(self, didFinishMeal: item)

		let stuffed = LifeBehaviorPolicy.isComfortablyFull(life)
		announce(
			stuffed ? .stuffed : .tastedItem,
			voice: .affirmative,
			priority: .normal,
			itemName: item.displayName
		)

		enter(
			.satisfied,
			clip: stuffed ? "satisfied" : "satisfied_quick",
			purpose: MovementPurpose.unset,
			transientSeconds: animator.durationSeconds
		)
		DiagnosticsLog.shared.writeEvent(
			"MealCompleted",
			[
				("Name", item.displayName),
				("Hunger", String(format: "%.1f", life.hunger)),
				("Fullness", String(format: "%.1f", life.fullness)),
				("Queued", "\(mealQueue.count)"),
			]
		)
	}

	/// What to do once a meal finishes: carry on down the queue, or settle.
	func advanceAfterMeal() {
		if !mealQueue.isEmpty, beginNextMeal() {
			announce(.feastContinues, voice: .positive, priority: .normal)
			return
		}
		returnToIdle()
	}

	func beginSleep() {
		wakeForMeal = false
		enter(.sleeping, clip: "sleep_enter")
		sleepRemaining = min(60, max(LifeBehaviorPolicy.minimumNapSeconds, life.sleepiness / 36 * 60))
		announce(.sleep, voice: .calm, priority: .important)
	}

	/// Starts the get-up animation. A wake already running just records the reason.
	private func beginWake(forMeal: Bool) {
		let starting = state != .waking
		wakeForMeal = wakeForMeal || forMeal
		guard starting else { return }
		enter(
			.waking,
			clip: "sleep_exit",
			purpose: MovementPurpose.unset,
			transientSeconds: animator.durationSeconds
		)
		if forMeal {
			announce(.wakeForFood, voice: .question, priority: .normal)
		}
	}

	func updateSleeping(_ delta: Double) {
		if animator.currentClip == "sleep_enter", animator.isCompleted {
			animator.play("sleep")
		}
		sleepRemaining -= delta
		if sleepRemaining <= 0, life.sleepiness <= 10 {
			beginWake(forMeal: false)
		}
	}

	/// Ends a wake-up, whichever way it ended. Woken for a meal, she goes for it;
	/// woken on her own, she simply says so. Both entry points must agree, so the
	/// decision lives here rather than at each of them.
	func finishWaking() {
		let wokenForMeal = wakeForMeal
		wakeForMeal = false
		if wokenForMeal, beginNextMeal() { return }
		announce(.wakeNormally, voice: .calm)
		returnToIdle()
	}

	// MARK: - Cheek pinch
}
