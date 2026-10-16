import AppKit

/// The menu's minimum width.
///
/// A row carries no width of its own: it stretches to whatever width the menu
/// settles on, so its frame width is only a starting point and this sets the
/// floor.
private let menuMinimumWidth: Double = 240

/// A menu that can carry a slider inline (used for the size control).
///
/// A custom menu-item view replaces the standard rendering, so it is built to
/// match one: the menu's font and colour, the same leading inset as the item
/// titles, and the standard row height.
final class SliderMenuItemView: NSView {
	static let rowHeight: Double = 22
	static let gap: Double = 12
	/// The menu draws its titles in a vibrant context a plain custom view does not
	/// share, so `.labelColor` came out lighter than the titles around it.
	static let titleColor: NSColor = .controlTextColor

	let slider: NSSlider
	let label: NSTextField

	init(
		title: String,
		value: Double,
		range: ClosedRange<Double>,
		target: AnyObject?,
		action: Selector
	) {
		slider = NSSlider(
			value: value,
			minValue: range.lowerBound,
			maxValue: range.upperBound,
			target: target,
			action: action
		)
		slider.isContinuous = true
		slider.controlSize = .mini

		label = NSTextField(labelWithString: title)
		label.font = NSFont.menuFont(ofSize: 0)
		label.textColor = Self.titleColor

		super.init(frame: NSRect(x: 0, y: 0, width: menuMinimumWidth, height: Self.rowHeight))
		// AppKit stretches an item's view to the menu's content width, so the row
		// fills the menu however wide it ends up.
		autoresizingMask = [.width]

		label.translatesAutoresizingMaskIntoConstraints = false
		slider.translatesAutoresizingMaskIntoConstraints = false
		// The title keeps its natural width; the slider absorbs the rest.
		label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
		label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
		slider.setContentHuggingPriority(.defaultLow, for: .horizontal)

		addSubview(label)
		addSubview(slider)
		NSLayoutConstraint.activate([
			label.centerYAnchor.constraint(equalTo: centerYAnchor),
			label.leadingAnchor.constraint(
				equalTo: leadingAnchor,
				constant: StatusItemController.customItemInsetLeft,
			),

			slider.centerYAnchor.constraint(equalTo: centerYAnchor),
			slider.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: Self.gap),
			slider.trailingAnchor.constraint(
				equalTo: trailingAnchor,
				constant: -StatusItemController.customItemInsetRight
			),
		])
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }
}

/// A slim rounded progress bar, drawn rather than built on `NSProgressIndicator`
/// so its height and colour can be set exactly.
final class HungerBarView: NSView {
	static let height: Double = 3

	static let trackColor: NSColor = .secondarySystemFill

	override var allowsVibrancy: Bool { true }

	var fraction: Double = 0 {
		didSet { needsDisplay = true }
	}

	var fillColor: NSColor = .systemGreen {
		didSet { needsDisplay = true }
	}

	override func draw(_ dirtyRect: NSRect) {
		let radius = bounds.height / 2

		Self.trackColor.setFill()
		NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

		let width = bounds.width * CGFloat(fraction.clamp(lower: 0, upper: 1))
		guard width > 0 else { return }
		fillColor.setFill()
		NSBezierPath(
			roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height),
			xRadius: radius,
			yRadius: radius
		).fill()
	}
}

/// The hunger readout: a name and its percentage on one row, a bar beneath them.
final class HungerMenuItemView: NSView {
	static let height: Double = 34
	/// Lighter than the titles around it: this labels a readout rather than naming
	/// a command.
	static let titleColor: NSColor = .secondaryLabelColor

	private static let topInset: Double = 4
	private static let barGap: Double = 8

	private let titleLabel: NSTextField
	private let percentageLabel: NSTextField
	private let bar = HungerBarView()

	convenience init() {
		self.init(frame: NSRect(x: 0, y: 0, width: menuMinimumWidth, height: Self.height))
	}

	override init(frame frameRect: NSRect) {
		titleLabel = NSTextField(labelWithString: "饥饿度")
		titleLabel.font = NSFont.menuFont(ofSize: 0)
		titleLabel.textColor = Self.titleColor

		percentageLabel = NSTextField(labelWithString: "0%")
		percentageLabel.font = NSFont.menuFont(ofSize: 0)
		percentageLabel.textColor = Self.titleColor
		percentageLabel.alignment = .right

		super.init(frame: frameRect)
		// AppKit stretches an item's view to the menu's content width, so the row
		// fills the menu however wide it ends up.
		autoresizingMask = [.width]

		for subview in [titleLabel, percentageLabel, bar] as [NSView] {
			subview.translatesAutoresizingMaskIntoConstraints = false
			addSubview(subview)
		}
		// The name holds its width; the percentage is what gives when the row is
		// narrow.
		titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
		titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
		percentageLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
		percentageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

		NSLayoutConstraint.activate([
			titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: Self.topInset),
			titleLabel.leadingAnchor.constraint(
				equalTo: leadingAnchor,
				constant: StatusItemController.customItemInsetLeft
			),

			percentageLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
			percentageLabel.leadingAnchor.constraint(
				greaterThanOrEqualTo: titleLabel.trailingAnchor,
				constant: 8
			),
			percentageLabel.trailingAnchor.constraint(
				equalTo: trailingAnchor,
				constant: -StatusItemController.customItemInsetRight
			),

			bar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Self.barGap),
			bar.heightAnchor.constraint(equalToConstant: HungerBarView.height),
			bar.leadingAnchor.constraint(
				equalTo: leadingAnchor,
				constant: StatusItemController.customItemInsetLeft + 0.5
			),
			bar.trailingAnchor.constraint(
				equalTo: trailingAnchor,
				constant: -StatusItemController.customItemInsetRight
			),
		])
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

	func update(hunger: Double) {
		let value = HungerDisplayPolicy.clamp(hunger)
		percentageLabel.stringValue = "\(HungerDisplayPolicy.percentage(forHunger: value))%"
		bar.fraction = value / 100
		bar.fillColor = Self.color(for: HungerDisplayPolicy.band(forHunger: value))
	}

	/// The original's palette, so a hunger reads here the way it did there.
	static func color(for band: HungerBand) -> NSColor {
		switch band {
		case .comfortable: return .systemGreen
		case .hungry: return .systemYellow
		case .veryHungry: return .systemOrange
		}
	}
}

/// Owns the menu-bar item and reflects state back into the menu.
@MainActor
public final class StatusItemController: NSObject, NSMenuDelegate {
	static let customItemInsetLeft: Double = 24
	static let customItemInsetRight: Double = 13.5

	public struct Callbacks {
		public var bringHome: () -> Void
		public var setSize: (Double) -> Void
		public var setFasting: (Bool) -> Void
		public var setQuiet: (Bool) -> Void
		public var setDeleteReaction: (Bool) -> Void
		public var setBubbles: (Bool) -> Void
		public var setLogging: (Bool) -> Void
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
			setLogging: @escaping (Bool) -> Void,
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
			self.setLogging = setLogging
			self.setMuted = setMuted
			self.setLaunchAtLogin = setLaunchAtLogin
			self.isLaunchAtLogin = isLaunchAtLogin
			self.quit = quit
		}
	}

	private let statusItem: NSStatusItem
	private let callbacks: Callbacks

	private let hungerItem = NSMenuItem()
	private let homeItem = NSMenuItem()
	private let sizeItem = NSMenuItem()
	private let fastingItem = NSMenuItem()
	private let quietItem = NSMenuItem()
	private let deleteReactionItem = NSMenuItem()
	private let bubblesItem = NSMenuItem()
	private let loggingItem = NSMenuItem()
	private let mutedItem = NSMenuItem()
	private let launchItem = NSMenuItem()
	private let quitItem = NSMenuItem()
	private let sizeSlider: NSSlider

	public var settings: PetSettings = PetSettings() {
		didSet { refreshMenuState() }
	}

	/// How hungry she is right now, `nil` when there is nothing to show.
	///
	/// A closing over the live state rather than a field, because hunger drifts
	/// while the menu is closed and there is no event to refresh on.
	public var hungerSource: (() -> Double?)?

	/// The login-item state, read once and reused afterwards.
	///
	/// Reading it spawns `osascript` and blocks the main thread for ~100 ms — far
	/// too much to pay on every menu display. It is read the first time the menu is
	/// built and again after each toggle, so a change made in System Settings is
	/// not picked up until then.
	private var launchAtLoginEnabled: Bool?

	public init(characterName: String, callbacks: Callbacks) {
		self.callbacks = callbacks
		// A variable-length item is sized to its glyph; a square item is as wide
		// as the bar is tall, which makes the click highlight visibly too wide.
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		sizeSlider = NSSlider()

		super.init()

		if let button = statusItem.button {
			button.image = NSImage(
				systemSymbolName: "pawprint.fill",
				accessibilityDescription: characterName
			)
			button.image?.size = NSSize(width: 18, height: 18)
			button.toolTip = characterName
		}

		let menu = NSMenu()
		menu.delegate = self
		// The rows stretch to this, so it is what sets the menu's width.
		menu.minimumWidth = menuMinimumWidth
		statusItem.menu = menu

		configure(menu)
		refreshMenuState()
	}

	public func menuNeedsUpdate(_ menu: NSMenu) {
		refreshMenuState()
	}

	public func popUpMenu(atScreenPoint point: NSPoint) {
		// No explicit refresh: `menuNeedsUpdate` runs when the menu displays.
		statusItem.menu?.popUp(positioning: nil, at: point, in: nil)
	}

	private func configure(_ menu: NSMenu) {
		// A readout rather than a command, so it takes no highlight and takes no
		// click.
		hungerItem.view = HungerMenuItemView()
		hungerItem.isEnabled = false
		menu.addItem(hungerItem)
		menu.addItem(.separator())

		homeItem.title = "让她回家"
		homeItem.target = self
		homeItem.action = #selector(bringHome)
		menu.addItem(homeItem)

		sizeItem.view = SliderMenuItemView(
			title: "桌宠尺寸",
			value: settings.petSize,
			range: PetSizePolicy.fromPercent(
				PetSizePolicy.minimumPercent
			)...PetSizePolicy.fromPercent(
				PetSizePolicy.maximumPercent
			),
			target: self,
			action: #selector(sizeChanged(_:))
		)
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

		mutedItem.title = "静音"
		mutedItem.target = self
		mutedItem.action = #selector(toggleMuted)
		menu.addItem(mutedItem)

		menu.addItem(.separator())

		// The two switches about the app rather than about her. Logging trades the
		// ~26 µs a line that writing one costs.
		loggingItem.title = "记录日志"
		loggingItem.target = self
		loggingItem.action = #selector(toggleLogging)
		menu.addItem(loggingItem)

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
		loggingItem.state = settings.loggingEnabled ? .on : .off
		// The item reads as "mute", so it is checked when sound is off.
		mutedItem.state = settings.soundEnabled ? .off : .on
		if launchAtLoginEnabled == nil { launchAtLoginEnabled = callbacks.isLaunchAtLogin() }
		launchItem.state = launchAtLoginEnabled == true ? .on : .off

		if let sliderView = sizeItem.view as? SliderMenuItemView {
			sliderView.slider.doubleValue = settings.petSize
			sliderView.label.stringValue = "桌宠尺寸 \(PetSizePolicy.toPercent(settings.petSize))%"
		}

		// Hidden rather than removed while she is fasting, matching where the
		// hunger bar is visible at all: the value in that mode is meaningless
		// rather than merely zero.
		let hunger =
			PetModePolicy.shouldShowProgressDisplay(
				character: settings.character,
				fastingMode: settings.fastingMode,
				infiniteMode: settings.infiniteMode,
				coexistenceMode: settings.coexistenceMode
			) ? hungerSource?() : nil
		if let hunger, let view = hungerItem.view as? HungerMenuItemView {
			view.update(hunger: hunger)
			hungerItem.isHidden = false
		} else {
			hungerItem.isHidden = true
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
	@objc private func toggleDeleteReaction() {
		callbacks.setDeleteReaction(!settings.reactToDeletes)
	}
	@objc private func toggleBubbles() { callbacks.setBubbles(!settings.showSpeechBubbles) }
	@objc private func toggleLogging() { callbacks.setLogging(!settings.loggingEnabled) }
	@objc private func toggleMuted() { callbacks.setMuted(settings.soundEnabled) }
	@objc private func toggleLaunchAtLogin() {
		callbacks.setLaunchAtLogin(!(launchAtLoginEnabled ?? false))
		// Re-read rather than trust the requested value: registering can fail.
		launchAtLoginEnabled = callbacks.isLaunchAtLogin()
	}
	@objc private func quit() { callbacks.quit() }
}
