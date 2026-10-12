import Foundation

public enum DialogueCue: String, Sendable, CaseIterable {
	case startup
	case buffet
	case mealSpotted
	case mealQueueContinues
	case iconsHidden
	case manualIconLick
	case curiousIconLick
	case platformLaunch
	case hardLanding
	case veryHungry
	case aBitHungry
	case confidentClimb
	case carefulClimb
	case climbSlip
	case climbSuccess
	case hungryRoll
	case suction
	case exploration
	case sleep
	case wakeForFood
	case wakeNormally
	case comfortablyFull
	case iconTaste
	case feastContinues
	case anotherBite
	case stuffed
	case tastedItem
	case pickedUp
	case released
	case dragThrow
	case terrainHop
	case terrainJumpDown
	case edgeSlide
	case windowMaximized
	case hungryRequestQueued
	case home
	case deleteReactionEnabled
	case deleteReactionDisabled
	case voiceEnabled
	case voiceDisabled
}

public enum PetDialogueCatalog {
	static let nuonuoLines: [DialogueCue: [String]] = [
		.startup: ["早呀。", "我醒啦。", "今天吃什么？", "先发会儿呆。"],
		.buffet: ["好多！", "都是我的？", "吃不完啦。", "嘿嘿，开饭。"],
		.mealSpotted: ["有吃的。", "香香的。", "我来啦。", "那个能吃吗？"],
		.mealQueueContinues: ["还有呀。", "下一个。", "都要吃。", "别跑。"],
		.iconsHidden: ["没有图标……", "藏哪啦？", "舔不到。", "空空的。"],
		.manualIconLick: ["好饿……", "先舔一口。", "就一小口。", "这个能吃吗？"],
		.curiousIconLick: ["什么味呀？", "舔一下。", "看着好香。", "就试试。"],
		.platformLaunch: ["飞起来啦！", "呜哇！", "脚呢？", "好高！"],
		.hardLanding: ["噗叽。", "扁掉啦。", "呼，到了。", "我又圆啦。"],
		.veryHungry: ["好饿……", "饿扁了。", "想吃东西。", "肚子空啦。"],
		.aBitHungry: ["有点饿。", "想吃一口。", "有吃的吗？", "嘴馋了。"],
		.confidentClimb: ["我能上去。", "看我的。", "嘿咻。", "上面有吃的？"],
		.carefulClimb: ["好高……", "慢一点。", "别掉呀。", "我试试。"],
		.climbSlip: ["滑下来啦……", "没抓住。", "呜……差一点。", "再来。"],
		.climbSuccess: ["上来啦。", "嘿嘿。", "我厉害吧。", "这里好高。"],
		.hungryRoll: ["好饿好饿。", "给我吃的。", "我滚一下。", "饿扁啦。"],
		.suction: ["吸过来！", "啊——", "到嘴里来。", "我要吃啦。"],
		.exploration: ["这里是哪？", "没来过。", "看看这边。", "好奇。"],
		.sleep: ["我要睡觉啦。", "困困。", "先睡一会儿。", "晚安。"],
		.wakeForFood: ["有吃的？", "我醒啦！", "香香的！", "开饭吗？"],
		.wakeNormally: ["醒啦。", "还想睡……", "睡饱啦。", "再躺一下？"],
		.comfortablyFull: ["吃饱啦。", "肚子圆圆。", "好撑。", "不动了。"],
		.iconTaste: ["不好吃。", "只有图标味。", "空的。", "再舔一下？"],
		.feastContinues: ["还能吃！", "再来一个。", "都给我。", "还没饱。"],
		.anotherBite: ["下一个。", "还有吗？", "继续吃。", "我还要。"],
		.stuffed: ["吃撑啦。", "肚子好圆。", "真的饱了。", "动不了啦。"],
		.tastedItem: ["{item} 好吃。", "{item} 香香的。", "喜欢 {item}。", "这个叫 {item}？"],
		.pickedUp: ["被抓住啦。", "轻一点。", "要拉长啦。", "呜……"],
		.released: ["放开啦。", "我掉啦。", "脚在哪里？", "转圈圈……"],
		.dragThrow: ["飞走啦！", "呜哇——", "停不下来！", "我被甩啦！"],
		.terrainHop: ["跳一下。", "嘿咻！", "我会飞。", "蹦起来啦。"],
		.terrainJumpDown: ["我跳啦。", "下面接住我。", "走你！", "飞下去。"],
		.edgeSlide: ["滑下去啦。", "慢慢滑。", "手要抓住。", "这是滑梯？"],
		.windowMaximized: ["变大啦！", "被弹飞啦！", "呜哇，好大！", "窗口长大了！"],
		.hungryRequestQueued: ["好饿……等一下。", "站稳就吃。", "马上去舔。", "肚子等不及啦。"],
		.home: ["到家啦。", "回窝。", "这里好。", "不走了。"],
		.deleteReactionEnabled: ["删掉的给我吃。", "我会接住。", "记得叫我。", "有吃的啦。"],
		.deleteReactionDisabled: ["今天不吃。", "先忍一下。", "不追啦。", "图标安全啦。"],
		.voiceEnabled: ["我有声音啦。", "听得到吗？", "嘿嘿，是我。", "我说话啦。"],
		.voiceDisabled: ["我安静啦。", "嘘。", "不说话啦。", "小声一点。"],
	]

	public static func lines(
		for cue: DialogueCue,
		character: PetCharacterProfile = .nuonuo
	) -> [String] {
		if character.usesMischief { return [] }
		return nuonuoLines[cue] ?? []
	}
}

/// Picks a line for a cue, never repeating the cue's own previous pick.
public struct PetDialogueSelector: Sendable {
	private var lastLineByCue: [DialogueCue: Int] = [:]
	private let character: PetCharacterProfile

	public init(character: PetCharacterProfile = .nuonuo) {
		self.character = character
	}

	public mutating func choose(_ cue: DialogueCue, itemName: String? = nil) -> String {
		let options = PetDialogueCatalog.lines(for: cue, character: character)
		guard !options.isEmpty else { return "" }

		var index = Int.random(in: 0..<options.count)
		if options.count > 1, lastLineByCue[cue] == index {
			index = (index + 1) % options.count
		}
		lastLineByCue[cue] = index

		let line = options[index]
		return line.replacingOccurrences(of: "{item}", with: itemName ?? "这份文件")
	}
}
