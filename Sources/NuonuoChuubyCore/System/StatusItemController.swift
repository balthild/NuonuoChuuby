import AppKit

/// A menu that can carry a slider inline (used for the size control).
final class SliderMenuItemView: NSView {
	let slider: NSSlider
	let label: NSTextField

	init(title: String, value: Double, range: ClosedRange<Double>, target: AnyObject?, action: Selector) {
		slider = NSSlider(
			value: value, minValue: range.lowerBound, maxValue: range.upperBound,
			target: target, action: action)
		slider.isContinuous = true
		label = NSTextField(labelWithString: title)
		label.font = NSFont.menuFont(ofSize: 0)

		super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 30))

		label.frame = NSRect(x: 14, y: 6, width: 116, height: 18)
		slider.frame = NSRect(x: 132, y: 4, width: 96, height: 22)
		addSubview(label)
		addSubview(slider)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }
}

/// Owns the menu-bar item and reflects state back into the menu.
@MainActor
public final class StatusItemController: NSObject, NSMenuDelegate {
	public struct Callbacks {
		public var bringHome: () -> Void
		public var setSize: (Double) -> Void
		public var setFasting: (Bool) -> Void
		public var setQuiet: (Bool) -> Void
		public var setDeleteReaction: (Bool) -> Void
		public var setBubbles: (Bool) -> Void
		public var setMuted: (Bool) -> Void
		public var setLaunchAtLogin: (Bool) -> Void
		public var isLaunchAtLogin: () -> Bool
		public var quit: () -> Void

		public init(
			bringHome: @escaping () -> Void,
			setSize: @escaping (Double) -> Void,
			setFasting: @escaping (Bool) -> Void,
			setQuiet: @escaping (Bool) -> Void,
			setDeleteReaction: @escaping (Bool) -> Void,
			setBubbles: @escaping (Bool) -> Void,
			setMuted: @escaping (Bool) -> Void,
			setLaunchAtLogin: @escaping (Bool) -> Void,
			isLaunchAtLogin: @escaping () -> Bool,
			quit: @escaping () -> Void
		) {
			self.bringHome = bringHome
			self.setSize = setSize
			self.setFasting = setFasting
			self.setQuiet = setQuiet
			self.setDeleteReaction = setDeleteReaction
			self.setBubbles = setBubbles
			self.setMuted = setMuted
			self.setLaunchAtLogin = setLaunchAtLogin
			self.isLaunchAtLogin = isLaunchAtLogin
			self.quit = quit
		}
	}

	private let statusItem: NSStatusItem
	private let callbacks: Callbacks

	private let homeItem = NSMenuItem()
	private let sizeItem = NSMenuItem()
	private let fastingItem = NSMenuItem()
	private let quietItem = NSMenuItem()
	private let deleteReactionItem = NSMenuItem()
	private let bubblesItem = NSMenuItem()
	private let mutedItem = NSMenuItem()
	private let launchItem = NSMenuItem()
	private let quitItem = NSMenuItem()
	private let sizeSlider: NSSlider

	/// Mirrors the current settings into the menu's checkmarks and slider.
	public var settings: PetSettings = PetSettings() {
		didSet { refreshMenuState() }
	}

	public init(characterName: String, callbacks: Callbacks) {
		self.callbacks = callbacks
		// A variable-length item is sized to its glyph; a square item is as wide
		// as the bar is tall, which makes the click highlight visibly too wide.
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		sizeSlider = NSSlider()

		super.init()

		if let button = statusItem.button {
			button.image = NSImage(
				systemSymbolName: "pawprint.fill", accessibilityDescription: characterName)
			button.image?.size = NSSize(width: 18, height: 18)
			button.toolTip = characterName
		}

		let menu = NSMenu()
		menu.delegate = self
		statusItem.menu = menu

		configure(menu)
		refreshMenuState()
	}

	/// Shows the same menu for a right-click on the pet itself.
	public func popUpMenu(atScreenPoint point: NSPoint) {
		refreshMenuState()
		statusItem.menu?.popUp(positioning: nil, at: point, in: nil)
	}

	private func configure(_ menu: NSMenu) {
		homeItem.title = "让她回家"
		homeItem.target = self
		homeItem.action = #selector(bringHome)
		menu.addItem(homeItem)

		sizeItem.view = SliderMenuItemView(
			title: "桌宠尺寸", value: settings.petSize,
			range: PetSizePolicy.fromPercent(PetSizePolicy.minimumPercent)...PetSizePolicy.fromPercent(
				PetSizePolicy.maximumPercent),
			target: self, action: #selector(sizeChanged(_:)))
		menu.addItem(sizeItem)

		menu.addItem(.separator())

		fastingItem.title = "禁食模式（永不饥饿）"
		fastingItem.target = self
		fastingItem.action = #selector(toggleFasting)
		menu.addItem(fastingItem)

		quietItem.title = "安静模式（只站立或睡觉）"
		quietItem.target = self
		quietItem.action = #selector(toggleQuiet)
		menu.addItem(quietItem)

		deleteReactionItem.title = "吃掉删除的文件"
		deleteReactionItem.target = self
		deleteReactionItem.action = #selector(toggleDeleteReaction)
		menu.addItem(deleteReactionItem)

		bubblesItem.title = "显示头顶对话气泡"
		bubblesItem.target = self
		bubblesItem.action = #selector(toggleBubbles)
		menu.addItem(bubblesItem)

		mutedItem.title = "禁音"
		mutedItem.target = self
		mutedItem.action = #selector(toggleMuted)
		menu.addItem(mutedItem)

		menu.addItem(.separator())

		launchItem.title = "开机自启"
		launchItem.target = self
		launchItem.action = #selector(toggleLaunchAtLogin)
		menu.addItem(launchItem)

		menu.addItem(.separator())

		quitItem.title = "退出桌宠"
		quitItem.target = self
		quitItem.action = #selector(quit)
		menu.addItem(quitItem)
	}

	private func refreshMenuState() {
		fastingItem.state = settings.fastingMode ? .on : .off
		quietItem.state = settings.quietMode ? .on : .off
		deleteReactionItem.state = settings.reactToDeletes ? .on : .off
		bubblesItem.state = settings.showSpeechBubbles ? .on : .off
		// The item reads as "mute", so it is checked when sound is off.
		mutedItem.state = settings.soundEnabled ? .off : .on
		launchItem.state = callbacks.isLaunchAtLogin() ? .on : .off

		if let sliderView = sizeItem.view as? SliderMenuItemView {
			sliderView.slider.doubleValue = settings.petSize
			sliderView.label.stringValue = "桌宠尺寸 \(PetSizePolicy.toPercent(settings.petSize))%"
		}
	}

	// MARK: - Actions

	@objc private func bringHome() { callbacks.bringHome() }

	@objc private func sizeChanged(_ sender: NSSlider) {
		callbacks.setSize(sender.doubleValue)
		if let sliderView = sizeItem.view as? SliderMenuItemView {
			sliderView.label.stringValue = "桌宠尺寸 \(PetSizePolicy.toPercent(sender.doubleValue))%"
		}
	}

	@objc private func toggleFasting() { callbacks.setFasting(!settings.fastingMode) }
	@objc private func toggleQuiet() { callbacks.setQuiet(!settings.quietMode) }
	@objc private func toggleDeleteReaction() { callbacks.setDeleteReaction(!settings.reactToDeletes) }
	@objc private func toggleBubbles() { callbacks.setBubbles(!settings.showSpeechBubbles) }
	@objc private func toggleMuted() { callbacks.setMuted(settings.soundEnabled) }
	@objc private func toggleLaunchAtLogin() { callbacks.setLaunchAtLogin(!callbacks.isLaunchAtLogin()) }
	@objc private func quit() { callbacks.quit() }
}
