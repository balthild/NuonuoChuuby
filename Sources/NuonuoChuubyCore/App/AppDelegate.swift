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
	private var petWindow: PetWindowController?
	private var speech: PetSpeechCoordinator?
	private var voice: VoicePlaybackService?
	private var statusItem: StatusItemController?
	private var mouseMonitor: MouseMonitor?
	private var deletionWatcher: FileDeletionWatcher?
	private var ghostIcons: [Int: GhostIconWindow] = [:]

	public func applicationDidFinishLaunching(_ notification: Notification) {
		// Required when running the executable directly (no bundle to read
		// LSUIElement from).
		NSApp.setActivationPolicy(.accessory)

		let environment = AppEnvironment()
		self.environment = environment
		DiagnosticsLog.shared.configure(fileURL: environment.logPath)
		DiagnosticsLog.shared.writeEvent("ProcessStarted", [("Bundle", AppEnvironment.bundleIdentifier)])

		let settingsStore = SettingsStore(path: environment.settingsPath)
		self.settingsStore = settingsStore
		settings = settingsStore.load()

		guard let locator = resolveAssets(environment: environment) else {
			presentMissingAssetsAlert()
			NSApp.terminate(nil)
			return
		}

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

		// Voice and the head bubble are wired before the pet starts so the first
		// frame can already speak.
		let loudness = VoiceLoudness.load(from: locator.file("audio/voice-levels.json"))
		let voice = VoicePlaybackService(
			locator: locator, character: character, loudness: loudness,
			enabled: settings.soundEnabled, volume: settings.voiceVolume)
		let speech = PetSpeechCoordinator(
			voice: voice, bubble: SpeechBubbleWindowController(), displaySpace: displaySpace,
			character: character)
		self.voice = voice
		self.speech = speech
		controller.speech = speech

		let petWindow = PetWindowController(controller: controller, displaySpace: displaySpace)
		petWindow.menuProvider = { [weak self] _ in
			// The status item owns the menu; borrow it for a right-click on the pet.
			self?.statusItem?.popUpMenu(atScreenPoint: NSEvent.mouseLocation)
			return nil
		}
		// Keep the bubble glued to the pet as it walks, falls and is dragged.
		petWindow.onPlacementChanged = { [weak speech] frame in
			speech?.updatePetFrame(frame)
		}
		self.petWindow = petWindow

		statusItem = makeStatusItem(character: character)

		// The pet eats files the user deletes from a watched folder. The monitor
		// supplies the anchor guess, since macOS exposes no icon positions.
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
	}

	public func applicationWillTerminate(_ notification: Notification) {
		controller?.persistLifeState()
		controller?.stop()
		deletionWatcher?.stop()
		mouseMonitor?.stop()
	}

	// MARK: - PetMealDelegate

	public func petController(_ controller: PetController, didBeginMeal item: DeletedItem) {
		let ghost = GhostIconWindow()
		ghost.show(
			icon: ShellIconProvider.icon(forPath: item.originalPath),
			at: item.anchor,
			size: controller.petSize * 0.34,
			displaySpace: displaySpace ?? DisplaySpace())
		ghostIcons[item.id] = ghost
	}

	public func petController(_ controller: PetController, didFinishMeal item: DeletedItem) {
		guard let ghost = ghostIcons.removeValue(forKey: item.id) else { return }
		ghost.fadeOut()
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
						DiagnosticsLog.shared.writeEvent("StartupRegistrationChanged", [("Enabled", "\(enabled)")])
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
			))
	}

	/// Applies a settings mutation, persists it, and pushes it into the running
	/// pet. Every menu action funnels through here so nothing drifts.
	private func update(_ mutate: (inout PetSettings) -> Void) {
		mutate(&settings)
		settings.normalize()
		settingsStore?.save(settings)
		applySettings()
		statusItem?.settings = settings
	}

	private func applySettings() {
		controller?.fastingMode = settings.fastingMode
		controller?.quietMode = settings.quietMode
		controller?.setSize(settings.petSize)
		speech?.showBubbles = settings.showSpeechBubbles
		speech?.isVoiceEnabled = settings.soundEnabled
		speech?.voiceVolume = settings.voiceVolume

		// Reaction to deletions is a user toggle, so the watcher follows it.
		if settings.reactToDeletes, settings.character.supportsFood {
			deletionWatcher?.start(extraFolders: settings.watchedFolders)
		} else {
			deletionWatcher?.stop()
		}
	}

	// MARK: - Assets

	private func resolveAssets(environment: AppEnvironment) -> AssetLocator? {
		// A development build seeds assets into the bundle; a release build has
		// them downloaded into Application Support.
		AssetLocator.bundled() ?? AssetLocator.installed(environment: environment)
	}

	private func presentMissingAssetsAlert() {
		let alert = NSAlert()
		alert.messageText = "缺少桌宠素材"
		alert.informativeText = "找不到糯糯的序列帧与语音。请先运行 `make assets`，或等待首次启动下载完成。"
		alert.alertStyle = .critical
		alert.addButton(withTitle: "好")
		alert.runModal()
	}
}
