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
	private var petWindow: (any PetPresenting)?
	private var speech: PetSpeechCoordinator?
	private var voice: VoicePlaybackService?
	private var statusItem: StatusItemController?
	private var mouseMonitor: MouseMonitor?
	private var desktopIcons: DesktopIconIndex?
	private var deletionWatcher: FileDeletionWatcher?
	/// The fake icons standing in for the desktop icons being eaten, kept together
	/// with the item they stand for: a suspension takes them away and has to be able
	/// to put them back when the meal resumes.
	private var ghostIcons: [Int: (item: DeletedItem, window: GhostIconWindow)] = [:]
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

		guard let store = try? AssetStore(environment: environment) else {
			presentAlert(
				title: "缺少素材清单",
				message: "这个构建里没有素材清单，也没找到随包的素材。请先运行 `make assets`。"
			)
			return nil
		}
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

		// The full-display overlay is the default renderer: it keeps the window still
		// and moves the pet inside it, which measured ~39% less CPU while dragging and
		// ~32% less at idle than moving a panel every frame. `--pet-panel` falls back to
		// the moving-panel renderer until the overlay has been checked on a multi-display
		// setup.
		//
		// It comes before the speech coordinator because the presenter also decides how
		// the head bubble is drawn — as a panel of its own, or as another layer of the
		// overlay — and the coordinator needs whichever it chose.
		let petWindow: any PetPresenting =
			CommandLine.arguments.contains("--pet-panel")
			? PetWindowController(controller: controller, displaySpace: displaySpace)
			: OverlayPetWindowController(controller: controller, displaySpace: displaySpace)
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
		// Self-labelling, so a performance trace can be told apart from one taken
		// with the other renderer without guessing from the launch command.
		DiagnosticsLog.shared.writeEvent(
			"PetPresenter",
			[
				("Kind", CommandLine.arguments.contains("--pet-panel") ? "panel" : "overlay"),
				("Displays", "\(displaySpace.displays.count)"),
			]
		)

		// The index has to be kept warm: a deleted icon's element is gone by the
		// time it is deleted.
		let desktopIcons = DesktopIconIndex()
		DesktopIconIndex.requestTrustIfNeeded(prompt: true)
		desktopIcons.start()
		self.desktopIcons = desktopIcons
		controller.desktopIcons = desktopIcons

		statusItem = makeStatusItem(character: character)

		// The monitor supplies the anchor guess, since macOS exposes no icon
		// positions.
		let mouseMonitor = MouseMonitor(displaySpace: displaySpace)
		mouseMonitor.start()
		self.mouseMonitor = mouseMonitor
		let deletionWatcher = FileDeletionWatcher(anchorProvider: { [weak mouseMonitor] in
			mouseMonitor?.anchor() ?? (PixelPoint(x: 0, y: 0), false)
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

	public func applicationWillTerminate(_ notification: Notification) {
		controller?.persistLifeState()
		controller?.stop()
		desktopIcons?.stop()
		deletionWatcher?.stop()
		mouseMonitor?.stop()
	}

	// MARK: - PetMealDelegate

	public func petController(_ controller: PetController, didBeginMeal item: DeletedItem) {
		let ghost = GhostIconWindow()
		showGhostIcon(ghost, for: item, petSize: controller.petSize)
		ghostIcons[item.id] = (item: item, window: ghost)
	}

	public func petController(_ controller: PetController, didFinishMeal item: DeletedItem) {
		guard let entry = ghostIcons.removeValue(forKey: item.id) else { return }
		entry.window.fadeOut()
	}

	private func showGhostIcon(_ ghost: GhostIconWindow, for item: DeletedItem, petSize: Double) {
		// Both are looked up again rather than remembered, so restoring one after a
		// suspension puts it where the icon and the desktop are *now*.
		let anchor = desktopIcons?.position(of: item.displayName) ?? item.anchor
		ghost.show(
			icon: ShellIconProvider.icon(forPath: item.originalPath),
			at: anchor,
			size: petSize * 0.34,
			displaySpace: displaySpace ?? DisplaySpace()
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
				entry.window.hide()
			} else {
				showGhostIcon(entry.window, for: entry.item, petSize: controller.petSize)
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
					self?.update { $0.reactToDeletes = on }
				},
				setBubbles: { [weak self] on in
					self?.update { $0.showSpeechBubbles = on }
				},
				setMuted: { [weak self] soundEnabled in
					// The item reports the current sound setting, so toggling inverts it.
					self?.update { $0.soundEnabled = !soundEnabled }
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

	// MARK: - Assets

	private func presentAlert(title: String, message: String) {
		let alert = NSAlert()
		alert.messageText = title
		alert.informativeText = message
		alert.alertStyle = .critical
		alert.addButton(withTitle: "好")
		alert.runModal()
	}
}
