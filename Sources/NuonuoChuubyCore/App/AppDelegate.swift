import AppKit

/// Application bootstrap: resolve assets, build the pet, and keep it alive.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
	private var environment: AppEnvironment?
	private var displaySpace: DisplaySpace?
	private var surfaceProvider: SurfaceProvider?
	private var controller: PetController?
	private var petWindow: PetWindowController?
	private var speech: PetSpeechCoordinator?
	private var voice: VoicePlaybackService?

	public func applicationDidFinishLaunching(_ notification: Notification) {
		// Required when running the executable directly (no bundle to read
		// LSUIElement from).
		NSApp.setActivationPolicy(.accessory)

		let environment = AppEnvironment()
		self.environment = environment
		DiagnosticsLog.shared.configure(fileURL: environment.logPath)
		DiagnosticsLog.shared.writeEvent("ProcessStarted", [("Version", AppEnvironment.bundleIdentifier)])

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

		let catalog = AssetCatalog(locator: locator)
		let controller = PetController(
			catalog: catalog,
			surfaceProvider: surfaceProvider,
			lifeStore: PetLifeStateStore(stateDirectory: environment.lifeStateDirectory),
			displaySpace: displaySpace,
			profile: .nuonuo,
			petSize: PetSizePolicy.defaultSize
		)
		self.controller = controller

		// Voice and the head bubble are wired before the pet starts so the first
		// frame can already speak.
		let loudness = VoiceLoudness.load(from: locator.file("audio/voice-levels.json"))
		let voice = VoicePlaybackService(
			locator: locator, character: .nuonuo, loudness: loudness)
		let speech = PetSpeechCoordinator(
			voice: voice, bubble: SpeechBubbleWindowController(), displaySpace: displaySpace)
		self.voice = voice
		self.speech = speech
		controller.speech = speech

		let petWindow = PetWindowController(controller: controller, displaySpace: displaySpace)
		petWindow.menuProvider = { [weak self] event in self?.makeContextMenu() }
		self.petWindow = petWindow

		petWindow.show()
		controller.start()
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
	}

	@objc private func displayParametersChanged() {
		let space = DisplaySpace()
		displaySpace = space
		surfaceProvider?.refresh(displaySpace: space)
		controller?.updateDisplaySpace(space)
		petWindow?.updateDisplaySpace(space)
	}

	private func resolveAssets(environment: AppEnvironment) -> AssetLocator? {
		// A development build seeds assets into the bundle; a release build has
		// them downloaded into Application Support.
		AssetLocator.bundled() ?? AssetLocator.installed(environment: environment)
	}

	private func makeContextMenu() -> NSMenu {
		let menu = NSMenu()
		menu.addItem(
			withTitle: "让她回家", action: #selector(bringHome), keyEquivalent: ""
		).target = self
		menu.addItem(.separator())
		menu.addItem(
			withTitle: "退出桌宠", action: #selector(quit), keyEquivalent: ""
		).target = self
		return menu
	}

	@objc private func bringHome() {
		controller?.bringHome()
	}

	@objc private func quit() {
		NSApp.terminate(nil)
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
