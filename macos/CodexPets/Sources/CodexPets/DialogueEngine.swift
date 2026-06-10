import Foundation

enum PetMurmurEvent: String, Codable, Equatable, CaseIterable {
    case interactionClick = "interaction.click"
    case interactionSpamClick = "interaction.spam_click"
    case mouseNear = "mouse.near"
    case drag = "interaction.drag"
    case codexRunning = "codex.running"
    case codexLongRunning = "codex.long_running"
    case codexWaiting = "codex.waiting"
    case codexReview = "codex.review"
    case codexSuccess = "codex.success"
    case codexFailed = "codex.failed"
    case userReturned = "user.returned"
    case lateNight = "ambient.late_night"
    case ambient = "ambient"

    var isImportantWorkflowEvent: Bool {
        switch self {
        case .codexWaiting, .codexReview, .codexSuccess, .codexFailed:
            return true
        default:
            return false
        }
    }
}

enum DialogueRarity: String, Codable, Equatable {
    case common
    case rare
    case legendary

    var weightMultiplier: Double {
        switch self {
        case .common: return 1
        case .rare: return 0.3
        case .legendary: return 0.08
        }
    }
}

struct DialogueLine: Codable, Equatable {
    let id: String
    let text: String
    let triggers: [String]
    let moods: [String]
    let semanticGroup: String
    let rarity: DialogueRarity
    let minDaysBeforeRepeat: Int
    let cooldownMinutes: Int
    let tones: [String]
    let requiresInteraction: Bool
    let maxShowsTotal: Int?

    init(
        id: String,
        text: String,
        triggers: [String],
        moods: [String],
        semanticGroup: String,
        rarity: DialogueRarity = .common,
        minDaysBeforeRepeat: Int = 30,
        cooldownMinutes: Int = 60,
        tones: [String] = ["soft"],
        requiresInteraction: Bool = false,
        maxShowsTotal: Int? = nil
    ) {
        self.id = id
        self.text = text
        self.triggers = triggers
        self.moods = moods
        self.semanticGroup = semanticGroup
        self.rarity = rarity
        self.minDaysBeforeRepeat = minDaysBeforeRepeat
        self.cooldownMinutes = cooldownMinutes
        self.tones = tones
        self.requiresInteraction = requiresInteraction
        self.maxShowsTotal = maxShowsTotal
    }
}

struct DialogueLineHistory: Codable, Equatable {
    var count: Int
    var lastShownAt: TimeInterval
}

struct DialogueGroupHistory: Codable, Equatable {
    var lastShownAt: TimeInterval
}

struct DialogueHistory: Codable, Equatable {
    var shown: [String: DialogueLineHistory]
    var groups: [String: DialogueGroupHistory]
    var dailyCount: [String: Int]
    var lastShownAt: TimeInterval?
    var mutedUntil: TimeInterval?
    var mutedLineIDs: Set<String>

    init(
        shown: [String: DialogueLineHistory] = [:],
        groups: [String: DialogueGroupHistory] = [:],
        dailyCount: [String: Int] = [:],
        lastShownAt: TimeInterval? = nil,
        mutedUntil: TimeInterval? = nil,
        mutedLineIDs: Set<String> = []
    ) {
        self.shown = shown
        self.groups = groups
        self.dailyCount = dailyCount
        self.lastShownAt = lastShownAt
        self.mutedUntil = mutedUntil
        self.mutedLineIDs = mutedLineIDs
    }

    func dailyLimitReached(_ limit: Int, now: TimeInterval) -> Bool {
        guard limit >= 0 else { return false }
        return (dailyCount[Self.dayKey(now)] ?? 0) >= limit
    }

    func globalCooldownActive(_ seconds: TimeInterval, now: TimeInterval) -> Bool {
        guard seconds > 0, let lastShownAt else { return false }
        return now - lastShownAt < seconds
    }

    func isMuted(now: TimeInterval) -> Bool {
        guard let mutedUntil else { return false }
        return now < mutedUntil
    }

    func canShow(_ line: DialogueLine, now: TimeInterval, groupCooldownSeconds: TimeInterval) -> Bool {
        if mutedLineIDs.contains(line.id) { return false }
        if let maxShowsTotal = line.maxShowsTotal,
           (shown[line.id]?.count ?? 0) >= maxShowsTotal
        {
            return false
        }
        if let lineHistory = shown[line.id] {
            let exactRepeatSeconds = TimeInterval(max(0, line.minDaysBeforeRepeat)) * 24 * 60 * 60
            let lineCooldownSeconds = TimeInterval(max(0, line.cooldownMinutes)) * 60
            if exactRepeatSeconds > 0, now - lineHistory.lastShownAt < exactRepeatSeconds {
                return false
            }
            if lineCooldownSeconds > 0, now - lineHistory.lastShownAt < lineCooldownSeconds {
                return false
            }
        }
        if let groupHistory = groups[line.semanticGroup] {
            let lineGroupCooldown = TimeInterval(max(0, line.cooldownMinutes)) * 60
            let effectiveGroupCooldown = max(groupCooldownSeconds, lineGroupCooldown)
            if effectiveGroupCooldown > 0, now - groupHistory.lastShownAt < effectiveGroupCooldown {
                return false
            }
        }
        return true
    }

    mutating func record(_ line: DialogueLine, now: TimeInterval) {
        let existing = shown[line.id]
        shown[line.id] = DialogueLineHistory(
            count: (existing?.count ?? 0) + 1,
            lastShownAt: now
        )
        groups[line.semanticGroup] = DialogueGroupHistory(lastShownAt: now)
        dailyCount[Self.dayKey(now), default: 0] += 1
        lastShownAt = now
    }

    mutating func mute(for seconds: TimeInterval, now: TimeInterval) {
        let next = now + max(0, seconds)
        mutedUntil = max(mutedUntil ?? -.infinity, next)
    }

    mutating func muteForToday(now: TimeInterval, calendar: Calendar = .current) {
        let date = Date(timeIntervalSince1970: now)
        if let endOfDay = calendar.dateInterval(of: .day, for: date)?.end {
            mutedUntil = endOfDay.timeIntervalSince1970
        } else {
            mutedUntil = (floor(now / 86_400) + 1) * 86_400
        }
    }

    mutating func muteLine(_ id: String) {
        mutedLineIDs.insert(id)
    }

    private static func dayKey(_ timestamp: TimeInterval) -> String {
        String(Int(floor(timestamp / 86_400)))
    }
}

struct DialogueSettings: Equatable {
    let mode: PetBubbleMode
    let enabledTones: Set<String>
    let dailyLimit: Int
    let globalCooldownSeconds: TimeInterval
    let groupCooldownSeconds: TimeInterval
    let allowLateNight: Bool

    init(
        mode: PetBubbleMode = .all,
        enabledTones: Set<String> = ["soft", "coding"],
        dailyLimit: Int? = nil,
        globalCooldownSeconds: TimeInterval? = nil,
        groupCooldownSeconds: TimeInterval? = nil,
        allowLateNight: Bool = false
    ) {
        self.mode = mode
        self.enabledTones = enabledTones
        self.dailyLimit = dailyLimit ?? mode.defaultDailyMurmurLimit
        self.globalCooldownSeconds = globalCooldownSeconds ?? mode.defaultGlobalMurmurCooldown
        self.groupCooldownSeconds = groupCooldownSeconds ?? mode.defaultSemanticGroupCooldown
        self.allowLateNight = allowLateNight
    }

    func allows(_ line: DialogueLine, event: PetMurmurEvent) -> Bool {
        guard mode != .off else { return false }
        if event == .lateNight, !allowLateNight { return false }
        if mode == .importantOnly, !event.isImportantWorkflowEvent { return false }

        let lineTones = Set(line.tones)
        if !lineTones.isEmpty, lineTones.isDisjoint(with: enabledTones) {
            return false
        }
        if mode == .all, lineTones.contains("chaotic") {
            return false
        }
        return true
    }
}

final class DialogueHistoryStore {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    static func `default`() -> DialogueHistoryStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexPets", isDirectory: true)
        return DialogueHistoryStore(url: base.appendingPathComponent("DialogueHistory.json"))
    }

    func load() -> DialogueHistory {
        guard
            let data = try? Data(contentsOf: url),
            let history = try? JSONDecoder().decode(DialogueHistory.self, from: data)
        else {
            return DialogueHistory()
        }
        return history
    }

    func save(_ history: DialogueHistory) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.prettyCodexPets.encode(history)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Murmurs are delight, not critical state. If persistence fails, stay quiet.
        }
    }
}

final class DialogueEngine {
    let lines: [DialogueLine]
    private let now: () -> TimeInterval
    private let random: () -> Double

    init(
        lines: [DialogueLine] = DialogueEngine.defaultLines,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
        random: @escaping () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.lines = lines
        self.now = now
        self.random = random
    }

    static func petMurmurs(
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
        random: @escaping () -> Double = { Double.random(in: 0..<1) }
    ) -> DialogueEngine {
        DialogueEngine(lines: defaultLines, now: now, random: random)
    }

    func maybeSpeak(
        event: PetMurmurEvent,
        mood: PetMood,
        settings: DialogueSettings,
        history: inout DialogueHistory
    ) -> DialogueLine? {
        let current = now()
        guard !history.isMuted(now: current) else { return nil }
        if !event.isImportantWorkflowEvent {
            guard !history.dailyLimitReached(settings.dailyLimit, now: current) else { return nil }
        }
        guard !history.globalCooldownActive(settings.globalCooldownSeconds, now: current) else { return nil }

        let candidates = lines.filter { line in
            line.triggers.contains(event.rawValue)
                && (line.moods.isEmpty || line.moods.contains(mood.rawValue))
                && settings.allows(line, event: event)
                && history.canShow(line, now: current, groupCooldownSeconds: settings.groupCooldownSeconds)
        }

        guard let selected = weightedPick(candidates, mood: mood, history: history) else {
            return nil
        }
        history.record(selected, now: current)
        return selected
    }

    private func weightedPick(
        _ candidates: [DialogueLine],
        mood: PetMood,
        history: DialogueHistory
    ) -> DialogueLine? {
        let weighted = candidates.map { line -> (line: DialogueLine, weight: Double) in
            var weight = line.rarity.weightMultiplier
            if history.shown[line.id] == nil {
                weight *= 4
            }
            if line.moods.contains(mood.rawValue) {
                weight *= 2
            }
            return (line, max(0.001, weight))
        }
        let total = weighted.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }

        var cursor = min(max(random(), 0), 0.999_999) * total
        for item in weighted {
            if cursor < item.weight {
                return item.line
            }
            cursor -= item.weight
        }
        return weighted.last?.line
    }

    private static func line(
        _ id: String,
        _ event: PetMurmurEvent,
        _ mood: PetMood,
        _ text: String,
        group: String,
        rarity: DialogueRarity = .common,
        days: Int = 30,
        cooldown: Int = 60,
        tones: [String] = ["soft"],
        interaction: Bool = false,
        max: Int? = nil
    ) -> DialogueLine {
        DialogueLine(
            id: id,
            text: text,
            triggers: [event.rawValue],
            moods: [mood.rawValue],
            semanticGroup: group,
            rarity: rarity,
            minDaysBeforeRepeat: days,
            cooldownMinutes: cooldown,
            tones: tones,
            requiresInteraction: interaction,
            maxShowsTotal: max
        )
    }

    static let defaultLines: [DialogueLine] = [
        line("click_001", .interactionClick, .happy, "+1 к уюту.", group: "interaction_petted", cooldown: 180, interaction: true),
        line("click_002", .interactionClick, .happy, "я официально поглажена.", group: "interaction_petted", cooldown: 180, interaction: true),
        line("click_003", .interactionClick, .happy, "мрр. но я ничего не говорила.", group: "interaction_petted", cooldown: 180, interaction: true),
        line("click_004", .interactionClick, .happy, "это было профессиональное поглаживание.", group: "interaction_petted", cooldown: 180, interaction: true),
        line("click_005", .interactionClick, .happy, "мне кажется, мы продуктивны.", group: "interaction_productive", cooldown: 240, interaction: true, max: 4),
        line("click_006", .interactionClick, .happy, "ладно, ещё раз можно.", group: "interaction_petted", cooldown: 180, interaction: true),
        line("click_007", .interactionClick, .happy, "поглаживание принято в backlog.", group: "interaction_backlog", rarity: .rare, cooldown: 420, tones: ["coding"], interaction: true),
        line("click_008", .interactionClick, .happy, "я вижу, это часть workflow.", group: "interaction_workflow", rarity: .rare, cooldown: 420, tones: ["coding"], interaction: true),

        line("spam_001", .interactionSpamClick, .annoyed, "я пиксельная, но чувства настоящие.", group: "spam_feelings", cooldown: 240, interaction: true),
        line("spam_002", .interactionSpamClick, .annoyed, "ладно-ладно, я уже милая.", group: "spam_already_cute", cooldown: 240, interaction: true),
        line("spam_003", .interactionSpamClick, .annoyed, "пожалуйста, не превращай меня в кнопку.", group: "spam_not_button", cooldown: 240, interaction: true),
        line("spam_004", .interactionSpamClick, .annoyed, "я не баг, я фича с ушами.", group: "spam_feature_ears", rarity: .rare, cooldown: 420, tones: ["coding"], interaction: true),

        line("near_001", .mouseNear, .curious, "ты что-то задумал?", group: "cursor_watch", cooldown: 360),
        line("near_002", .mouseNear, .curious, "я вижу курсор.", group: "cursor_watch", cooldown: 360),
        line("near_003", .mouseNear, .curious, "он приближается.", group: "cursor_approaches", cooldown: 360),
        line("near_004", .mouseNear, .curious, "если это drag — я морально готова.", group: "cursor_drag_ready", cooldown: 420),
        line("near_005", .mouseNear, .curious, "мы смотрим друг на друга. продуктивно.", group: "cursor_eye_contact", rarity: .rare, cooldown: 720),

        line("drag_001", .drag, .happy, "переезд без коробок.", group: "drag_moved", cooldown: 240, interaction: true),
        line("drag_002", .drag, .happy, "новое место. новая я.", group: "drag_moved", cooldown: 240, interaction: true),
        line("drag_003", .drag, .happy, "тут лучше. наверное.", group: "drag_new_place", cooldown: 240, interaction: true),
        line("drag_004", .drag, .happy, "меня поставили. я стою.", group: "drag_placed", cooldown: 240, interaction: true),
        line("drag_005", .drag, .happy, "географически я изменилась.", group: "drag_geography", rarity: .rare, cooldown: 420, interaction: true),
        line("drag_006", .drag, .happy, "я уже desktop furniture.", group: "drag_furniture", rarity: .rare, cooldown: 720, tones: ["silly"], interaction: true),

        line("running_001", .codexRunning, .focused, "окей, я пошла копаться в байтах.", group: "running_start", cooldown: 120, tones: ["coding"]),
        line("running_002", .codexRunning, .focused, "делаю вид, что всё под контролем.", group: "running_start", cooldown: 120, tones: ["coding"]),
        line("running_003", .codexRunning, .focused, "работаю тихо. почти.", group: "running_start", cooldown: 120, tones: ["coding"]),
        line("running_004", .codexRunning, .focused, "я в режиме маленького инженера.", group: "running_tiny_engineer", cooldown: 180, tones: ["coding"]),
        line("running_005", .codexRunning, .focused, "сейчас что-нибудь придумаем.", group: "running_start", cooldown: 120, tones: ["coding"]),
        line("running_006", .codexRunning, .focused, "байты шуршат.", group: "running_bytes", rarity: .rare, cooldown: 360, tones: ["silly", "coding"]),

        line("long_running_001", .codexLongRunning, .focused, "я всё ещё тут. просто стала философской.", group: "running_long", cooldown: 360, tones: ["coding"]),
        line("long_running_002", .codexLongRunning, .focused, "долгая задача. я села рядом.", group: "running_long", cooldown: 360, tones: ["soft"]),
        line("long_running_003", .codexLongRunning, .focused, "если что, я охраняю прогресс.", group: "running_guard", cooldown: 360, tones: ["soft"]),
        line("long_running_004", .codexLongRunning, .focused, "байты сопротивляются, но мы терпеливые.", group: "running_bytes_resist", rarity: .rare, cooldown: 720, tones: ["coding"]),

        line("waiting_001", .codexWaiting, .waiting, "кажется, теперь твой ход.", group: "waiting_user_turn", cooldown: 30, tones: ["soft", "coding"]),
        line("waiting_002", .codexWaiting, .waiting, "я принесла вопрос.", group: "waiting_user_turn", cooldown: 30, tones: ["soft", "coding"]),
        line("waiting_003", .codexWaiting, .waiting, "оно ждёт тебя. я тоже, но милее.", group: "waiting_user_turn", cooldown: 60, tones: ["soft"]),
        line("waiting_004", .codexWaiting, .waiting, "там что-то просит внимания.", group: "waiting_attention", cooldown: 45, tones: ["coding"]),
        line("waiting_005", .codexWaiting, .waiting, "я не тороплю. просто смотрю.", group: "waiting_soft", cooldown: 60, tones: ["soft"]),

        line("review_001", .codexReview, .waiting, "я сложила изменения в аккуратную кучку.", group: "review_ready", cooldown: 45, tones: ["coding"]),
        line("review_002", .codexReview, .waiting, "пора посмотреть, что получилось.", group: "review_ready", cooldown: 45, tones: ["coding"]),
        line("review_003", .codexReview, .waiting, "я принесла review. оно свежее.", group: "review_fresh", cooldown: 60, tones: ["coding"]),
        line("review_004", .codexReview, .waiting, "кажется, это уже можно читать.", group: "review_ready", cooldown: 45, tones: ["coding"]),
        line("review_005", .codexReview, .waiting, "готово к человеческому взгляду.", group: "review_human", cooldown: 60, tones: ["coding", "soft"]),

        line("success_001", .codexSuccess, .happy, "получилось. я сделала маленький победный круг.", group: "success_small_victory", cooldown: 45, tones: ["coding"]),
        line("success_002", .codexSuccess, .happy, "ура. можно моргнуть с гордостью.", group: "success_proud", cooldown: 60, tones: ["soft"]),
        line("success_003", .codexSuccess, .happy, "оно зелёное. я довольна.", group: "success_green", cooldown: 45, tones: ["coding"]),
        line("success_004", .codexSuccess, .happy, "мы победили одну маленькую неопределённость.", group: "success_uncertainty", cooldown: 60, tones: ["coding"]),
        line("success_005", .codexSuccess, .happy, "я знала, что у нас лапки не зря.", group: "success_paws", rarity: .rare, cooldown: 120, tones: ["soft"]),
        line("success_006", .codexSuccess, .happy, "зелёный день. я одобряю.", group: "success_green_day", rarity: .rare, cooldown: 180, tones: ["coding"]),

        line("failed_001", .codexFailed, .sad, "упс. я аккуратно положила ошибку на стол.", group: "failed_soft", cooldown: 45, tones: ["soft", "coding"]),
        line("failed_002", .codexFailed, .sad, "что-то хрустнуло. но не мы.", group: "failed_crunch", cooldown: 45, tones: ["soft"]),
        line("failed_003", .codexFailed, .sad, "оно не прошло. я рядом.", group: "failed_nearby", cooldown: 45, tones: ["soft", "coding"]),
        line("failed_004", .codexFailed, .sad, "байты сказали ‘нет’, но неубедительно.", group: "failed_bytes_no", cooldown: 60, tones: ["coding"]),
        line("failed_005", .codexFailed, .sad, "маленький красный флаг. очень маленький.", group: "failed_red_flag", cooldown: 60, tones: ["coding"]),
        line("failed_006", .codexFailed, .sad, "кажется, баг решил пожить с нами.", group: "failed_repeat_bug", rarity: .rare, cooldown: 180, tones: ["coding"]),
        line("failed_007", .codexFailed, .sad, "я уже принесла плед для stack trace.", group: "failed_stack_trace_blanket", rarity: .rare, cooldown: 240, tones: ["coding", "soft"]),

        line("return_001", .userReturned, .happy, "о, ты вернулся.", group: "return_greeting", cooldown: 720, tones: ["soft"]),
        line("return_002", .userReturned, .happy, "я тут немного поспала.", group: "return_slept", cooldown: 720, tones: ["soft"]),
        line("return_003", .userReturned, .happy, "пока тебя не было, я охраняла пиксели.", group: "return_guarded_pixels", cooldown: 720, tones: ["soft"]),
        line("return_004", .userReturned, .happy, "добро пожаловать обратно.", group: "return_greeting", cooldown: 720, tones: ["soft"]),
        line("return_005", .userReturned, .happy, "я делала вид, что не скучала.", group: "return_not_missing", rarity: .rare, cooldown: 1440, tones: ["soft"]),

        line("night_001", .lateNight, .sleepy, "я уже пиксельно зеваю.", group: "night_sleepy", cooldown: 1440, tones: ["soft"]),
        line("night_002", .lateNight, .sleepy, "поздний час. байты тоже хотят спать.", group: "night_bytes", cooldown: 1440, tones: ["coding", "soft"]),
        line("night_003", .lateNight, .sleepy, "я свернулась в маленький if.", group: "night_if", rarity: .rare, cooldown: 1440, tones: ["coding"]),
        line("night_004", .lateNight, .sleepy, "ночной режим: мягкие лапки, тихие мысли.", group: "night_soft", cooldown: 1440, tones: ["soft"]),
        line("night_005", .lateNight, .sleepy, "давай ещё чуть-чуть и потом отдыхать. наверное.", group: "night_soft_nudge", rarity: .rare, cooldown: 1440, tones: ["soft"]),

        line("ambient_001", .ambient, .curious, "я сижу очень ответственно.", group: "ambient_responsible", cooldown: 1440, tones: ["soft"]),
        line("ambient_002", .ambient, .curious, "пиксели под контролем.", group: "ambient_pixels", cooldown: 1440, tones: ["soft"]),
        line("ambient_003", .ambient, .curious, "у меня маленький план. очень маленький.", group: "ambient_tiny_plan", cooldown: 1440, tones: ["soft"]),
        line("ambient_004", .ambient, .curious, "я думала, но тихо.", group: "ambient_thinking", cooldown: 1440, tones: ["soft"]),
        line("ambient_005", .ambient, .curious, "всё идёт маленькими шагами.", group: "ambient_small_steps", cooldown: 1440, tones: ["soft"]),
        line("ambient_006", .ambient, .curious, "я рядом.", group: "ambient_nearby", cooldown: 1440, tones: ["soft"]),

        line("rare_001", .ambient, .curious, "я нашла невидимую крошку. она моя.", group: "rare_invisible_crumb", rarity: .rare, days: 45, cooldown: 4320, tones: ["silly"]),
        line("rare_002", .ambient, .curious, "сегодня я особенно круглая.", group: "rare_round", rarity: .rare, days: 45, cooldown: 4320, tones: ["soft"]),
        line("rare_003", .codexReview, .waiting, "я умею смотреть в сторону проблемы.", group: "rare_problem_side_eye", rarity: .rare, days: 45, cooldown: 4320, tones: ["coding"]),
        line("rare_004", .ambient, .curious, "я положила тревожность в маленькую коробку.", group: "rare_anxiety_box", rarity: .rare, days: 45, cooldown: 4320, tones: ["soft"]),
        line("rare_005", .mouseNear, .curious, "кажется, курсор приручён.", group: "rare_cursor_tamed", rarity: .rare, days: 45, cooldown: 4320, tones: ["soft"]),
        line("egg_001", .ambient, .curious, "легенда гласит, что где-то есть идеальный diff.", group: "egg_perfect_diff", rarity: .legendary, days: 60, cooldown: 10080, tones: ["coding"]),
        line("egg_002", .codexRunning, .focused, "я видела TODO. оно видело меня.", group: "egg_todo", rarity: .legendary, days: 60, cooldown: 10080, tones: ["coding"]),
        line("egg_003", .ambient, .curious, "я не отвлекаю. я украшаю периферию.", group: "egg_periphery", rarity: .legendary, days: 60, cooldown: 10080, tones: ["soft"]),
    ]
}

private extension JSONEncoder {
    static var prettyCodexPets: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
