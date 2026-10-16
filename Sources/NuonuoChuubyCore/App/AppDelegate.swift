import AppKit

/// Application bootstrap: resolve assets and settings, build the pet, and wire
/// the menu bar.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, PetMealDelegate {
	private var environment: AppEnvironment?
	private var settingsStore: SettingsStore?
	private var settings = PetSettings()
	private var displaySpace: DisplaySpace?
	private var surfaceProvider: SurfaceProvider?
	private var controller: PetController?
	private var petWindow: OverlayPetWindowController?
	private var speech: PetSpeechCoordinator?
	private var voice: VoicePlaybackService?
	private var statusItem: StatusItemController?
	private var mouseMonitor: MouseMonitor?
	private var desktopIcons: DesktopIconIndex?
	private var deletionWatcher: FileDeletionWatcher?
	/// The fake icons standing in for the desktop icons being eaten, kept together
	/// with the item they stand for: a suspension takes them away and has to be able
	/// to put them back when the meal resumes.
	private var ghostIcons: [Int: (item: DeletedItem, icon: OverlayGhostIcon)] = [:]
	private var assetSetup: AssetSetupWindowController?

	public func applicationDidFinishLaunching(_ notification: Notification) {
		// Required when running the executable directly (no bundle to read
		// LSUIElement from).
		NSApp.setActivationPolicy(.accessory)

		let environment = AppEnvironment()
		self.environment = environment
		DiagnosticsLog.shared.configure(fileURL: environment.logPath)
		DiagnosticsLog.shared.writeEvent(
			"ProcessStarted",
			[("Bundle", AppEnvironment.bundleIdentifier)]
		)

		let settingsStore = SettingsStore(path: environment.settingsPath)
		self.settingsStore = settingsStore
		settings = settingsStore.load()

		Task { @MainActor in
			guard let locator = await resolveAssets(environment: environment) else {
				NSApp.terminate(nil)
				return
			}
			startPet(locator: locator, environment: environment)
		}
	}

	/// Resolves the asset folder, downloading it when nothing is installed yet.
	private func resolveAssets(environment: AppEnvironment) async -> AssetLocator? {
		if let seeded = AssetLocator.bundled() { return seeded }

		let store = AssetStore(environment: environment)
		if store.isComplete() {
			return AssetLocator(root: store.installDirectory)
		}

		let setup = AssetSetupWindowController()
		self.assetSetup = setup
		setup.show()

		while true {
			do {
				try await store.install { progress in
					Task { @MainActor in
						setup.showProgress(completed: progress.completed, total: progress.total)
					}
				}
				setup.close()
				self.assetSetup = nil
				DiagnosticsLog.shared.writeEvent("AssetsReady", [("Commit", store.manifestCommit)])
				return AssetLocator(root: store.installDirectory)
			} catch {
				DiagnosticsLog.shared.write("asset download failed", error: error)
				setup.showFailure("素材下载失败，请检查网络后重试。")
				await setup.waitForRetry()
			}
		}
	}

	private func startPet(locator: AssetLocator, environment: AppEnvironment) {
		let displaySpace = DisplaySpace()
		self.displaySpace = displaySpace

		let surfaceProvider = SurfaceProvider()
		surfaceProvider.refresh(displaySpace: displaySpace)
		self.surfaceProvider = surfaceProvider

		let character = settings.character
		let catalog = AssetCatalog(locator: locator)
		let controller = PetController(
			catalog: catalog,
			surfaceProvider: surfaceProvider,
			lifeStore: PetLifeStateStore(stateDirectory: environment.lifeStateDirectory),
			displaySpace: displaySpace,
			profile: character,
			petSize: settings.petSize
		)
		self.controller = controller

		// Self-labelling, so a performance trace can be told apart from one taken at
		// another rate without guessing from the launch command.
		DiagnosticsLog.shared.writeEvent(
			"PetFallRefresh",
			[("Rate", controller.fallRefreshDescription)]
		)

		// The voice is wired up before the pet starts so the first frame can already
		// speak.
		let loudness = VoiceLoudness.load(from: locator.file("audio/voice-levels.json"))
		let voice = VoicePlaybackService(
			locator: locator,
			character: character,
			loudness: loudness,
			enabled: settings.soundEnabled,
			volume: settings.voiceVolume
		)
		self.voice = voice

		// The full-display overlay keeps the window still and moves the pet inside it,
		// which measured ~39% less CPU while dragging and ~32% less at idle than moving
		// a panel every frame. It also owns the head bubble and the ghost icons — layers
		// of that same window — so it is built before the speech coordinator, which
		// needs the bubble it chose.
		let petWindow = OverlayPetWindowController(
			controller: controller,
			displaySpace: displaySpace
		)
		petWindow.menuProvider = { [weak self] _ in
			// The status item owns the menu; borrow it for a right-click on the pet.
			self?.statusItem?.popUpMenu(atScreenPoint: NSEvent.mouseLocation)
			return nil
		}
		self.petWindow = petWindow

		let speech = PetSpeechCoordinator(
			voice: voice,
			bubble: petWindow.speechBubble,
			displaySpace: displaySpace,
			character: character
		)
		self.speech = speech
		controller.speech = speech

		petWindow.onPlacementChanged = { [weak speech] frame in
			speech?.updatePetFrame(frame)
		}
		petWindow.onSuspensionChanged = { [weak self] suspended in
			guard let self else { return }
			if suspended { self.speech?.hideBubble() }
			self.placeGhostIcons(suspended: suspended)
		}
		// Self-labelling, so a performance trace can be told apart without guessing
		// from the launch command.
		DiagnosticsLog.shared.writeEvent(
			"PetPresenter",
			[("Displays", "\(displaySpace.displays.count)")]
		)

		// Read at the moment a deletion is detected, when the icon's element is
		// still there — it disappears about half a second later.
		let desktopIcons = DesktopIconIndex()
		DesktopIconIndex.requestTrustIfNeeded(prompt: true)
		desktopIcons.start()
		self.desktopIcons = desktopIcons
		controller.desktopIcons = desktopIcons

		statusItem = makeStatusItem(character: character)
		// Read when the menu opens, so it reports where hunger has drifted to
		// rather than where it stood the last time something changed.
		statusItem?.hungerSource = { [weak controller] in controller?.life.hunger }

		// The monitor is only a fallback now: it supplies the last click or the
		// cursor, for a folder the desktop icon index does not cover.
		let mouseMonitor = MouseMonitor(displaySpace: displaySpace)
		mouseMonitor.start()
		self.mouseMonitor = mouseMonitor

		// The anchor is resolved here, at detection, not when she sets off: the
		// deleted icon's accessibility element is gone within about half a second,
		// while the confirmed meal may start several seconds later.
		let deletionWatcher = FileDeletionWatcher(anchorProvider: {
			[weak desktopIcons, weak mouseMonitor] name in
			if let icon = desktopIcons?.iconForDeletion(of: name) {
				return FileDeletionWatcher.Anchor(
					point: icon.position,
					exact: true,
					iconSize: icon.size
				)
			}
			let fallback = mouseMonitor?.anchor() ?? (point: PixelPoint(x: 0, y: 0), isExact: false)
			return FileDeletionWatcher.Anchor(point: fallback.point, exact: fallback.isExact)
		})
		deletionWatcher.onMealsReady = { [weak self] items in
			self?.controller?.enqueueMeals(items)
		}
		self.deletionWatcher = deletionWatcher
		controller.mealDelegate = self

		applySettings()
		DiagnosticsLog.shared.writeEvent("SettingsApplied")
		petWindow.show()
		controller.start()
		DiagnosticsLog.shared.writeEvent("PetStarted")
		controller.announceStartup()

		NotificationCenter.default.addObserver(
			self,
			selector: #selector(displayParametersChanged),
			name: NSApplication.didChangeScreenParametersNotification,
			object: nil
		)

		// A scripted pinch, so the effect can be checked without a human drag.
		if CommandLine.arguments.contains("--demo-pinch") {
			runPinchDemo(on: controller)
		}

		// A scripted icon lick, so the walk out and the drop afterwards can be
		// watched without waiting for her to get hungry.
		if CommandLine.arguments.contains("--demo-lick") {
			runIconLickDemo(on: controller)
		}
	}

	private func runPinchDemo(on controller: PetController) {
		let geometry = controller.cheekGeometryInView
		let start = CGPoint(x: geometry.rightX, y: geometry.cheekY)
		controller.beginPinch(side: .right, at: start)

		let steps = 60
		for step in 1...steps {
			let progress = Double(step) / Double(steps)
			let point = CGPoint(
				x: start.x + CGFloat(46 * progress),
				y: start.y + CGFloat(6 * progress)
			)
			DispatchQueue.main.asyncAfter(deadline: .now() + progress * 1.2) { [weak controller] in
				controller?.updatePinch(to: point)
			}
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak controller] in
			controller?.endPinch()
		}
	}

	/// Sends her off to lick a desktop icon a moment after launch.
	///
	/// The pause is for the launch, not for the simulation: nothing the walk reads is
	/// set up by the first tick, but starting it on the same frame as the startup line
	/// makes the two indistinguishable.
	///
	/// The one passing `ignoringQuietMode`: quiet mode otherwise refuses a lick
	/// outright, and a demo that silently does nothing is worse than one that says
	/// what it did.
	private func runIconLickDemo(on controller: PetController) {
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak controller] in
			guard let controller, let self else { return }
			let icons = self.desktopIcons?.icons.count ?? 0
			DiagnosticsLog.shared.writeEvent(
				"IconLickDemo",
				[
					// Zero means Accessibility is not granted, so the icons she walks to
					// are the rough Finder-default layout rather than the real ones.
					("Icons", "\(icons)"),
					("QuietMode", "\(controller.quietMode)"),
					("Started", "\(controller.tryBeginIconLick(manual: true, ignoringQuietMode: true))"),
				]
			)
		}
	}

	public func applicationWillTerminate(_ notification: Notification) {
		controller?.persistLifeState()
		controller?.stop()
		desktopIcons?.stop()
		deletionWatcher?.stop()
		mouseMonitor?.stop()
	}

	// MARK: - PetMealDelegate

	public func petController(_ controller: PetController, didBeginMeal item: DeletedItem) {
		// Logged with its anchor and whether that anchor is the icon's real position
		// or a fallback, so "the ghost is in the wrong place" is answerable from the log.
		DiagnosticsLog.shared.writeEvent(
			"GhostShown",
			[
				("Name", item.displayName),
				("Anchor", "\(Int(item.anchor.x)),\(Int(item.anchor.y))"),
				("Size", item.iconSize.map { String(format: "%.0f", $0) } ?? "fallback"),
				("Exact", "\(item.exactAnchor)"),
			]
		)
		let ghost = petWindow?.makeGhostIcon()
		guard let ghost else { return }
		showGhostIcon(ghost, for: item, petSize: controller.petSize)
		ghostIcons[item.id] = (item: item, icon: ghost)
	}

	public func petController(_ controller: PetController, didFinishMeal item: DeletedItem) {
		guard let entry = ghostIcons.removeValue(forKey: item.id) else { return }
		entry.icon.fadeOut()
	}

	/// The icon shivers where the desktop icon was and is then swallowed, which is
	/// what her open mouth is doing in the chewing clip.
	public func petController(
		_ controller: PetController,
		didUpdateMeal item: DeletedItem,
		visual: MealConsumptionVisual
	) {
		ghostIcons[item.id]?.icon.update(visual)
	}

	private func showGhostIcon(
		_ ghost: OverlayGhostIcon,
		for item: DeletedItem,
		petSize: Double
	) {
		// A deleted icon's position and size cannot be re-read — it is gone. Both were
		// resolved when the deletion was detected, while the element still existed, so
		// the ghost matches the real icon instead of a guess scaled to her.
		ghost.show(
			icon: ShellIconProvider.icon(forPath: item.originalPath),
			at: item.anchor,
			size: item.iconSize ?? petSize * 0.34
		)
	}

	/// Puts the fake icons away with her, and brings them back when she returns.
	///
	/// A meal can be interrupted by a fullscreen app, and a fake icon left floating
	/// over one is the same defect as the pet herself being left there.
	private func placeGhostIcons(suspended: Bool) {
		guard let controller else { return }
		for entry in ghostIcons.values {
			if suspended {
				entry.icon.hide()
			} else {
				showGhostIcon(entry.icon, for: entry.item, petSize: controller.petSize)
			}
		}
	}

	@objc private func displayParametersChanged() {
		let space = DisplaySpace()
		displaySpace = space
		surfaceProvider?.refresh(displaySpace: space)
		controller?.updateDisplaySpace(space)
		petWindow?.updateDisplaySpace(space)
	}

	// MARK: - Settings

	private var appPath: String { Bundle.main.bundlePath }

	private func makeStatusItem(character: PetCharacterProfile) -> StatusItemController {
		StatusItemController(
			characterName: character.displayName,
			callbacks: .init(
				bringHome: { [weak self] in self?.controller?.bringHome() },
				setSize: { [weak self] size in
					self?.update { $0.petSize = size }
				},
				setFasting: { [weak self] on in
					self?.update { $0.fastingMode = on }
				},
				setQuiet: { [weak self] on in
					self?.update { $0.quietMode = on }
				},
				setDeleteReaction: { [weak self] on in
					guard let self else { return }
					self.update { $0.reactToDeletes = on }
					// Only she eats deletions, so the toggle is only hers to answer for.
					guard self.settings.character.supportsFood else { return }
					self.speech?.react(
						on ? .deleteReactionEnabled : .deleteReactionDisabled,
						voice: on ? .positive : .calm,
						priority: .normal
					)
				},
				setBubbles: { [weak self] on in
					self?.update { $0.showSpeechBubbles = on }
				},
				setMuted: { [weak self] soundEnabled in
					guard let self else { return }
					// The item reports the current sound setting, so toggling inverts it.
					self.update { $0.soundEnabled = !soundEnabled }
					// Speaking about losing her voice is the one line that cannot be
					// recorded: the clip is already off, so only the bubble appears.
					self.speech?.react(
						self.settings.soundEnabled ? .voiceEnabled : .voiceDisabled,
						voice: self.settings.soundEnabled ? .positive : .calm,
						priority: .normal
					)
				},
				setLaunchAtLogin: { [weak self] enabled in
					guard let self else { return }
					do {
						try StartupRegistrationService.setEnabled(enabled, appPath: self.appPath)
						DiagnosticsLog.shared.writeEvent(
							"StartupRegistrationChanged",
							[("Enabled", "\(enabled)")]
						)
					} catch {
						DiagnosticsLog.shared.write("login item change failed", error: error)
					}
					self.statusItem?.settings = self.settings
				},
				isLaunchAtLogin: { [weak self] in
					guard let self else { return false }
					return StartupRegistrationService.isEnabled(appPath: self.appPath)
				},
				quit: { NSApp.terminate(nil) }
			)
		)
	}

	/// Applies a settings mutation, persists it, and pushes it into the running
	/// pet. Every menu action funnels through here so nothing drifts.
	private func update(_ mutate: (inout PetSettings) -> Void) {
		mutate(&settings)
		settings.normalize()
		settingsStore?.save(settings)
		applySettings()
	}

	private func applySettings() {
		controller?.fastingMode = settings.fastingMode
		controller?.quietMode = settings.quietMode
		controller?.setSize(settings.petSize)
		speech?.showBubbles = settings.showSpeechBubbles
		speech?.isVoiceEnabled = settings.soundEnabled
		speech?.voiceVolume = settings.voiceVolume

		// The menu mirrors the settings; this also runs at startup, since the status
		// item is built before the saved settings are applied.
		statusItem?.settings = settings

		if settings.reactToDeletes, settings.character.supportsFood {
			deletionWatcher?.start(extraFolders: settings.watchedFolders)
		} else {
			deletionWatcher?.stop()
		}
	}
}
