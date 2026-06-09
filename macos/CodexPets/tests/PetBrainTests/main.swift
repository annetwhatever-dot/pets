import Cocoa
import Foundation

private final class TestClock {
    var now: TimeInterval

    init(_ now: TimeInterval = 0) {
        self.now = now
    }

    func advance(_ seconds: TimeInterval) {
        now += seconds
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func expectDecision(_ decision: PetDecision?, _ message: String) -> PetDecision {
    guard let decision else {
        fputs("FAIL: expected decision — \(message)\n", stderr)
        exit(1)
    }
    return decision
}

private func murmurLine(
    _ id: String,
    trigger: PetMurmurEvent,
    text: String,
    group: String,
    mood: PetMood = .happy,
    rarity: DialogueRarity = .common,
    minDaysBeforeRepeat: Int = 30,
    cooldownMinutes: Int = 60,
    tones: [String] = ["soft"],
    requiresInteraction: Bool = false,
    maxShowsTotal: Int? = nil
) -> DialogueLine {
    DialogueLine(
        id: id,
        text: text,
        triggers: [trigger.rawValue],
        moods: [mood.rawValue],
        semanticGroup: group,
        rarity: rarity,
        minDaysBeforeRepeat: minDaysBeforeRepeat,
        cooldownMinutes: cooldownMinutes,
        tones: tones,
        requiresInteraction: requiresInteraction,
        maxShowsTotal: maxShowsTotal
    )
}

private func testMouseProximityRequiresDwellAndCooldown() {
    let clock = TestClock()
    let brain = PetBrain(mode: .default, now: { clock.now })

    expect(brain.handle(.mouseNear(distance: 110)) == nil, "near cursor should dwell before curious")
    clock.advance(0.45)
    let curious = expectDecision(brain.handle(.mouseNear(distance: 100)), "near cursor after dwell")
    expect(curious.mood == .curious, "near cursor after dwell should be curious")
    expect(curious.stateID == "waiting", "curious should use waiting pose")
    expect(curious.bubble != nil, "curious proximity can show a short murmur in default mode")

    clock.advance(1)
    expect(brain.handle(.mouseNear(distance: 90)) == nil, "curious should respect cooldown")
}

private func testFocusModeAndReduceMotionStayQuiet() {
    let clock = TestClock()
    let brain = PetBrain(mode: .focus, reduceMotion: true, now: { clock.now })

    clock.advance(1)
    expect(brain.handle(.mouseNear(distance: 80)) == nil, "focus mode should ignore passive mouse proximity")

    let running = expectDecision(brain.handle(.codexState("running")), "running still matters in focus mode")
    expect(running.mood == .focused, "running should map to focused mood")
    expect(running.stateID == "running", "running should keep running state id")
    expect(running.bubble == nil, "running should be quiet")
    expect(running.playback == .staticFrame(0), "reduce motion should force static playback")
}

private func testCodexEventsMapToEmotionsAndBubbles() {
    let clock = TestClock(1_700_000_000)
    let brain = PetBrain(
        mode: .default,
        bubbleMode: .all,
        now: { clock.now },
        dialogueNow: { clock.now },
        dialogueEngine: DialogueEngine(
            lines: [
                murmurLine("success", trigger: .codexSuccess, text: "оно зелёное. я довольна.", group: "success_green", mood: .happy, tones: ["coding"]),
                murmurLine("waiting", trigger: .codexWaiting, text: "кажется, теперь твой ход.", group: "waiting_user_turn", mood: .waiting),
            ],
            now: { clock.now },
            random: { 0 }
        )
    )

    let success = expectDecision(
        brain.handle(.codexEvent(type: "task.succeeded", label: "Tests passed", importance: .low)),
        "task success"
    )
    expect(success.mood == .happy, "task.succeeded should be happy")
    expect(success.stateID == "waving", "task.succeeded should wave")
    expect(success.bubble == "оно зелёное. я довольна.", "success should use a curated murmur")
    expect(success.duration == 1.6, "success should be short")

    clock.advance(4 * 60)
    let needsUser = expectDecision(
        brain.handle(.codexEvent(type: "task.needs_user", label: "Review changes?", importance: .medium)),
        "needs user"
    )
    expect(needsUser.mood == .waiting, "task.needs_user should be waiting")
    expect(needsUser.stateID == "waiting", "task.needs_user should use waiting pose")
    expect(needsUser.bubble == "кажется, теперь твой ход.", "needs-user event should use a curated murmur")
}

private func testClickSpamBecomesAnnoyed() {
    let clock = TestClock()
    let brain = PetBrain(mode: .default, now: { clock.now })

    for _ in 0..<4 {
        _ = brain.handle(.clicked(count: 1))
        clock.advance(1)
    }
    let annoyed = expectDecision(brain.handle(.clicked(count: 1)), "spam click threshold")
    expect(annoyed.mood == .annoyed, "5 clicks in 10s should become annoyed")
    expect(annoyed.stateID == "failed", "annoyed should use failed/startled pose")
    expect(annoyed.bubble != nil, "spam click should get one short anti-spam murmur")
}

private func testIdleAttentionBudgetCapsMicroIdle() {
    let clock = TestClock()
    let brain = PetBrain(mode: .default, now: { clock.now })
    var activeIdleCount = 0

    for _ in 0..<24 {
        if let decision = brain.handle(.idlePulse), decision.mood != .calm {
            activeIdleCount += 1
        }
        clock.advance(5)
    }

    expect(activeIdleCount <= 5, "default mode should cap micro-idle decisions to 5/min, got \(activeIdleCount)")
}

private func testLongRunningSettlesToWaitingPose() {
    let clock = TestClock()
    let brain = PetBrain(mode: .playful, now: { clock.now })

    _ = brain.handle(.codexState("running"))
    clock.advance(6 * 60)
    let settled = expectDecision(brain.handle(.idlePulse), "long-running task should settle")
    expect(settled.mood == .focused, "long-running task should stay focused")
    expect(settled.stateID == "waiting", "long-running task should stop endless running")
    expect(settled.playback == .staticFrame(0), "long-running task should be static")
}

private func testManualAnimatedStatesPlayOnce() {
    let brain = PetBrain(mode: .default)

    let wave = expectDecision(brain.handle(.codexState("waving")), "manual waving state")
    expect(wave.stateID == "waving", "manual waving should keep state")
    expect(wave.playback == .playOnce, "manual waving should play once")

    let jump = expectDecision(brain.handle(.codexState("jumping")), "manual jumping state")
    expect(jump.stateID == "jumping", "manual jumping should keep state")
    expect(jump.playback == .playOnce, "manual jumping should play once")
}

private func testDoubleClickOverridesSingleClickCooldown() {
    let clock = TestClock()
    let brain = PetBrain(mode: .default, now: { clock.now })

    _ = brain.handle(.clicked(count: 1))
    clock.advance(0.2)
    let doubleClick = expectDecision(brain.handle(.clicked(count: 2)), "double-click should not be swallowed by happy cooldown")
    expect(doubleClick.mood == .happy, "double-click should be happy")
    expect(doubleClick.stateID == "jumping", "double-click should use petting/jumping pose")
}

private func testSuccessEventStillAppliesDuringHappyCooldown() {
    let clock = TestClock()
    let brain = PetBrain(mode: .default, now: { clock.now })

    _ = brain.handle(.clicked(count: 1))
    _ = brain.handle(.codexState("running"))
    clock.advance(1)
    let success = expectDecision(
        brain.handle(.codexEvent(type: "task.succeeded", label: "Tests passed", importance: .low)),
        "success should not be dropped during happy cooldown"
    )
    expect(success.mood == .happy, "success should remain happy")
    expect(success.stateID == "waving", "success should visibly complete")
}

private func testReduceMotionOffResumesRunningPlayback() {
    let clock = TestClock()
    let brain = PetBrain(mode: .default, reduceMotion: true, now: { clock.now })

    let reduced = expectDecision(brain.handle(.codexState("running")), "running in reduce motion")
    expect(reduced.playback == .staticFrame(0), "running should be static while reduce motion is on")

    let resumed = expectDecision(brain.handle(.reduceMotionChanged(false)), "turning reduce motion off")
    expect(resumed.mood == .focused, "running should still be focused")
    expect(resumed.stateID == "running", "running state should be preserved")
    if case .loopWithPause = resumed.playback {
        // expected
    } else {
        fputs("FAIL: running should resume loopWithPause after reduce motion is disabled\n", stderr)
        exit(1)
    }
}

private func testMouseLeavingRadiusResetsDwell() {
    let clock = TestClock()
    let brain = PetBrain(mode: .default, now: { clock.now })

    expect(brain.handle(.mouseNear(distance: 100)) == nil, "initial near starts dwell")
    clock.advance(0.45)
    expect(brain.handle(.mouseNear(distance: 300)) == nil, "leaving radius should reset dwell")
    clock.advance(0.1)
    expect(brain.handle(.mouseNear(distance: 100)) == nil, "re-enter should require a fresh dwell")
}

private func testDialogueEngineAvoidsExactAndSemanticRepeats() {
    let clock = TestClock(1_700_000_000)
    var history = DialogueHistory()
    let settings = DialogueSettings(
        mode: .all,
        dailyLimit: 10,
        globalCooldownSeconds: 0,
        groupCooldownSeconds: 60 * 60
    )
    let engine = DialogueEngine(
        lines: [
            murmurLine("success_a", trigger: .codexSuccess, text: "получилось.", group: "success_small_victory"),
            murmurLine("success_b", trigger: .codexSuccess, text: "ура.", group: "success_small_victory"),
            murmurLine("success_c", trigger: .codexSuccess, text: "зелёный день.", group: "success_green_day"),
        ],
        now: { clock.now },
        random: { 0 }
    )

    let first = engine.maybeSpeak(event: .codexSuccess, mood: .happy, settings: settings, history: &history)
    expect(first?.id == "success_a", "first unseen line should be selected")

    let second = engine.maybeSpeak(event: .codexSuccess, mood: .happy, settings: settings, history: &history)
    expect(second?.id == "success_c", "semantic group cooldown should skip similar success lines")

    clock.advance(2 * 60 * 60)
    let third = engine.maybeSpeak(event: .codexSuccess, mood: .happy, settings: settings, history: &history)
    expect(third?.id == "success_b", "exact repeat should be blocked while sibling group line can return later")
}

private func testDialogueModesAndDailyBudget() {
    let clock = TestClock(1_700_000_000)
    let lines = [
        murmurLine("click", trigger: .interactionClick, text: "+1 к уюту.", group: "interaction_petted", mood: .happy, requiresInteraction: true),
        murmurLine("near", trigger: .mouseNear, text: "я вижу курсор.", group: "cursor_watch", mood: .curious),
        murmurLine("review", trigger: .codexReview, text: "пора посмотреть.", group: "review_ready", mood: .waiting, tones: ["coding"]),
    ]
    let engine = DialogueEngine(lines: lines, now: { clock.now }, random: { 0 })

    var silentHistory = DialogueHistory()
    let silent = engine.maybeSpeak(
        event: .codexReview,
        mood: .waiting,
        settings: DialogueSettings(mode: .off, dailyLimit: 10, globalCooldownSeconds: 0),
        history: &silentHistory
    )
    expect(silent == nil, "silent mode should block all murmurs")

    var quietHistory = DialogueHistory()
    let quietClick = engine.maybeSpeak(
        event: .interactionClick,
        mood: .happy,
        settings: DialogueSettings(mode: .importantOnly, dailyLimit: 10, globalCooldownSeconds: 0),
        history: &quietHistory
    )
    expect(quietClick == nil, "quiet mode should skip interaction jokes")
    let quietReview = engine.maybeSpeak(
        event: .codexReview,
        mood: .waiting,
        settings: DialogueSettings(mode: .importantOnly, dailyLimit: 10, globalCooldownSeconds: 0),
        history: &quietHistory
    )
    expect(quietReview?.id == "review", "quiet mode should allow important workflow status")

    var cappedHistory = DialogueHistory()
    let cappedSettings = DialogueSettings(mode: .all, dailyLimit: 1, globalCooldownSeconds: 0)
    let first = engine.maybeSpeak(event: .interactionClick, mood: .happy, settings: cappedSettings, history: &cappedHistory)
    expect(first?.id == "click", "first murmur should fit under daily cap")
    clock.advance(10 * 60)
    let second = engine.maybeSpeak(event: .mouseNear, mood: .curious, settings: cappedSettings, history: &cappedHistory)
    expect(second == nil, "daily cap should stop more low-priority bubbles after budget is used")
}

private func testDialogueImportantWorkflowBypassesLowPriorityDailyCap() {
    let clock = TestClock(1_700_000_000)
    var history = DialogueHistory()
    let settings = DialogueSettings(mode: .all, dailyLimit: 1, globalCooldownSeconds: 0, groupCooldownSeconds: 0)
    let engine = DialogueEngine(
        lines: [
            murmurLine("click", trigger: .interactionClick, text: "+1 к уюту.", group: "interaction_petted", mood: .happy, requiresInteraction: true),
            murmurLine("failed", trigger: .codexFailed, text: "что-то хрустнуло. но не мы.", group: "failed_soft", mood: .sad),
        ],
        now: { clock.now },
        random: { 0 }
    )

    let click = engine.maybeSpeak(event: .interactionClick, mood: .happy, settings: settings, history: &history)
    expect(click?.id == "click", "low-priority interaction should consume the normal daily cap")

    let failed = engine.maybeSpeak(event: .codexFailed, mood: .sad, settings: settings, history: &history)
    expect(failed?.id == "failed", "important workflow events should still speak after ambient budget is used")
}

private func testMuteForTodayUsesLocalCalendarBoundary() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 5 * 60 * 60 + 30 * 60)!
    let nowDate = calendar.date(from: DateComponents(year: 2026, month: 6, day: 9, hour: 22, minute: 15))!
    let expectedEnd = calendar.dateInterval(of: .day, for: nowDate)!.end.timeIntervalSince1970

    var history = DialogueHistory()
    history.muteForToday(now: nowDate.timeIntervalSince1970, calendar: calendar)

    expect(abs((history.mutedUntil ?? 0) - expectedEnd) < 0.01, "mute for today should end at local midnight")
}

private func testPetBrainUsesCuratedMurmursForWorkflowStatus() {
    let clock = TestClock(1_700_000_000)
    let brain = PetBrain(
        mode: .default,
        bubbleMode: .all,
        now: { clock.now },
        dialogueNow: { clock.now },
        dialogueEngine: DialogueEngine(
            lines: [
                murmurLine("success", trigger: .codexSuccess, text: "получилось.", group: "success_small_victory", mood: .happy),
                murmurLine("review", trigger: .codexReview, text: "готово к человеческому взгляду.", group: "review_ready", mood: .waiting, tones: ["coding"]),
            ],
            now: { clock.now },
            random: { 0 }
        )
    )

    let success = expectDecision(
        brain.handle(.codexEvent(type: "task.succeeded", label: "Tests passed", importance: .low)),
        "success should produce a decision"
    )
    expect(success.bubble == "получилось.", "success should use curated murmur instead of raw event label")

    let repeated = expectDecision(
        brain.handle(.codexEvent(type: "task.succeeded", label: "Tests passed", importance: .low)),
        "repeated success still animates"
    )
    expect(repeated.bubble == nil, "same workflow event should not repeat a murmur immediately")

    clock.advance(5 * 60)
    let review = expectDecision(brain.handle(.codexState("review")), "review transition")
    expect(review.bubble == "готово к человеческому взгляду.", "review state should use a curated coding murmur")
}

private func testPetBrainDismissedBubbleMutesMurmursForHours() {
    let clock = TestClock(1_700_000_000)
    let brain = PetBrain(
        mode: .default,
        bubbleMode: .all,
        now: { clock.now },
        dialogueNow: { clock.now },
        dialogueEngine: DialogueEngine(
            lines: [
                murmurLine("review", trigger: .codexReview, text: "пора посмотреть.", group: "review_ready", mood: .waiting, tones: ["coding"]),
                murmurLine("failed", trigger: .codexFailed, text: "что-то хрустнуло. но не мы.", group: "failed_soft", mood: .sad, tones: ["soft"]),
            ],
            now: { clock.now },
            random: { 0 }
        )
    )

    brain.muteMurmurs(for: 3 * 60 * 60)
    let muted = expectDecision(brain.handle(.codexState("review")), "review still changes animation while muted")
    expect(muted.bubble == nil, "manual dismissal should silence murmurs")

    clock.advance(4 * 60 * 60)
    let unmuted = expectDecision(brain.handle(.codexState("failed")), "failed after mute expires")
    expect(unmuted.bubble == "что-то хрустнуло. но не мы.", "murmurs should resume after mute expires")
}

private func testBubbleHitTestingDoesNotCaptureTransparentGap() {
    let view = PetOverlayView(frame: NSRect(x: 0, y: 0, width: 190, height: 235))
    let pet = PetPackage(
        slug: "test",
        displayName: "Test Pet",
        detail: "Test",
        kind: "pet",
        source: .app,
        directory: URL(fileURLWithPath: "/tmp"),
        spritesheet: URL(fileURLWithPath: "/tmp/missing-spritesheet.png"),
        frameWidth: 192,
        frameHeight: 208,
        states: PetAnimationState.defaults
    )
    view.setPet(pet, state: PetAnimationState.defaults[0], scale: 0.76, playback: .staticFrame(0))
    view.bubbleText = "пора посмотреть."
    view.bubbleActionHandler = {}

    let bubble = view.bubbleRect
    let sprite = view.spriteRect
    let bubblePoint = NSPoint(x: bubble.midX, y: bubble.midY)
    let spritePoint = NSPoint(x: sprite.midX, y: sprite.midY)
    let gapPoint = NSPoint(x: sprite.midX, y: (bubble.maxY + sprite.minY) / 2)

    expect(view.containsInteractivePoint(bubblePoint), "bubble should be clickable")
    expect(view.containsInteractivePoint(spritePoint), "sprite should stay clickable")
    expect(!view.containsInteractivePoint(gapPoint), "transparent gap between bubble and sprite should remain click-through")
}

let tests: [(String, () -> Void)] = [
    ("dialogue avoids repeats", testDialogueEngineAvoidsExactAndSemanticRepeats),
    ("dialogue modes and daily budget", testDialogueModesAndDailyBudget),
    ("important workflow bypasses low-priority daily cap", testDialogueImportantWorkflowBypassesLowPriorityDailyCap),
    ("mute for today uses local calendar", testMuteForTodayUsesLocalCalendarBoundary),
    ("pet brain curated workflow murmurs", testPetBrainUsesCuratedMurmursForWorkflowStatus),
    ("bubble dismissal mutes murmurs", testPetBrainDismissedBubbleMutesMurmursForHours),
    ("bubble hit testing keeps transparent gap click-through", testBubbleHitTestingDoesNotCaptureTransparentGap),
    ("mouse proximity dwell/cooldown", testMouseProximityRequiresDwellAndCooldown),
    ("focus + reduce motion", testFocusModeAndReduceMotionStayQuiet),
    ("Codex events", testCodexEventsMapToEmotionsAndBubbles),
    ("click spam annoyed", testClickSpamBecomesAnnoyed),
    ("idle attention budget", testIdleAttentionBudgetCapsMicroIdle),
    ("long-running settle", testLongRunningSettlesToWaitingPose),
    ("manual animated states", testManualAnimatedStatesPlayOnce),
    ("double-click cooldown override", testDoubleClickOverridesSingleClickCooldown),
    ("success during happy cooldown", testSuccessEventStillAppliesDuringHappyCooldown),
    ("reduce motion off resumes running", testReduceMotionOffResumesRunningPlayback),
    ("mouse leave resets dwell", testMouseLeavingRadiusResetsDwell),
]

for (name, test) in tests {
    test()
    print("✓ \(name)")
}
print("PetBrain tests passed")
