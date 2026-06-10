import Cocoa
import Darwin
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

private func testDragUsesDirectionalRunningLoop() {
    let brain = PetBrain(mode: .default)

    let right = expectDecision(brain.handle(.dragged(direction: .right)), "dragging right")
    expect(right.mood == .happy, "dragging should stay an interaction")
    expect(right.stateID == "running-right", "dragging right should use right run animation")
    expect(right.playback == .loop, "dragging should actively loop until mouse-up")
    expect(right.duration == nil, "dragging should be ended by mouse-up instead of a fixed duration")

    let left = expectDecision(brain.handle(.dragged(direction: .left)), "dragging left")
    expect(left.stateID == "running-left", "dragging left should use left run animation")
    expect(left.playback == .loop, "dragging left should actively loop until mouse-up")
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

private func testOverlayHitTestingMakesWholePetBodyDraggable() {
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
    let spriteCornerPoint = NSPoint(x: sprite.minX + 1, y: sprite.minY + 1)
    let bodyEdgePoint = NSPoint(x: view.petBodyHitRect.minX + 1, y: sprite.midY)
    let gapPoint = NSPoint(x: sprite.midX, y: (bubble.maxY + sprite.minY) / 2)
    let lowerBodyPoint = NSPoint(x: view.bounds.midX, y: view.bounds.maxY - 2)

    expect(view.containsInteractivePoint(bubblePoint), "bubble should be clickable")
    expect(view.containsInteractivePoint(spritePoint), "sprite should stay clickable")
    expect(view.containsInteractivePoint(spriteCornerPoint), "whole sprite body should be draggable")
    expect(view.containsInteractivePoint(bodyEdgePoint), "pet body hitbox should be draggable")
    expect(view.containsInteractivePoint(gapPoint), "space around the pet should drag with the body")
    expect(view.containsInteractivePoint(lowerBodyPoint), "lower pet overlay should be draggable")
}

private func testPetdexManifestParserSupportsV1AndV2() {
    let v1 = Data("""
    {
      "pets": [
        {
          "slug": "boba",
          "displayName": "Boba",
          "description": "Round friend",
          "kind": "cat",
          "submittedBy": "petdex",
          "spritesheetUrl": "https://assets.petdex.dev/pets/boba/spritesheet.webp",
          "petJsonUrl": "https://assets.petdex.dev/pets/boba/pet.json",
          "tags": ["soft", "round"]
        }
      ]
    }
    """.utf8)
    let v1Entries = try! PetdexManifestParser.parse(v1)
    expect(v1Entries.count == 1, "v1 manifest should parse one pet")
    expect(v1Entries[0].slug == "boba", "v1 slug should be normalized")
    expect(v1Entries[0].displayName == "Boba", "v1 display name")
    expect(v1Entries[0].spritesheetURL.absoluteString == "https://assets.petdex.dev/pets/boba/spritesheet.webp", "v1 sprite url")
    expect(v1Entries[0].tags == ["soft", "round"], "v1 tags")

    let v2 = Data("""
    {
      "v": 2,
      "assetBase": "https://assets.petdex.dev",
      "pets": [["miso", "Miso", "fox", "ana", "/pets/miso/spritesheet.webp", "/pets/miso/pet.json", "/pets/miso/package.zip"]]
    }
    """.utf8)
    let v2Entries = try! PetdexManifestParser.parse(v2)
    expect(v2Entries.count == 1, "v2 manifest should parse one compact pet")
    expect(v2Entries[0].slug == "miso", "v2 slug")
    expect(v2Entries[0].spritesheetURL.absoluteString == "https://assets.petdex.dev/pets/miso/spritesheet.webp", "v2 relative sprite should become absolute")
    expect(v2Entries[0].petJSONURL?.absoluteString == "https://assets.petdex.dev/pets/miso/pet.json", "v2 relative pet json should become absolute")
    expect(v2Entries[0].zipURL?.absoluteString == "https://assets.petdex.dev/pets/miso/package.zip", "v2 relative zip should become absolute")
}

private func testDownloadedPetdexImportWritesPackageSafely() {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("codex-pets-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = PetStore(appSupport: root)
    let entry = PetdexCatalogEntry(
        slug: "../miso pet",
        displayName: "Miso Pet",
        detail: "Downloaded from Petdex.",
        kind: "fox",
        submittedBy: "ana",
        tags: ["soft"],
        spritesheetURL: URL(string: "https://assets.petdex.dev/pets/miso/spritesheet.webp")!,
        petJSONURL: URL(string: "https://assets.petdex.dev/pets/miso/pet.json")!,
        zipURL: nil,
        frameWidth: 192,
        frameHeight: 208
    )
    let petJSON = Data("""
    {"slug":"miso-pet","displayName":"Miso Pet","description":"Downloaded.","frameWidth":192,"frameHeight":208,"spritesheetPath":"../outside.png"}
    """.utf8)
    try! FileManager.default.createDirectory(at: store.importedPetsRoot, withIntermediateDirectories: true)
    let outside = store.importedPetsRoot.appendingPathComponent("outside.png")
    try! Data([0x89, 0x50, 0x4e, 0x47]).write(to: outside)
    let sprite = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00])

    let pet = try! store.importDownloadedPetdexPet(entry, petJSON: petJSON, spritesheet: sprite, spritesheetExtension: "webp")
    expect(pet.slug == "miso-pet", "import should load slug from written pet.json")
    expect(pet.displayName == "Miso Pet", "import should load display name")
    expect(pet.source == .app, "downloaded Petdex pets become imported local pets")
    expect(pet.directory.path.hasPrefix(store.importedPetsRoot.path), "download should stay under imported pets root")
    expect(FileManager.default.fileExists(atPath: pet.directory.appendingPathComponent("pet.json").path), "pet.json should be written")
    expect(FileManager.default.fileExists(atPath: pet.directory.appendingPathComponent("spritesheet.webp").path), "spritesheet should be written")
    expect(pet.spritesheet.path == pet.directory.appendingPathComponent("spritesheet.webp").path, "import should rewrite remote pet.json spritesheetPath to the downloaded local sprite")
}

private func petdexEntry(
    _ slug: String,
    displayName: String,
    detail: String = "",
    kind: String = "pet",
    submittedBy: String = "",
    tags: [String] = [],
    frameWidth: Int = 192,
    frameHeight: Int = 208
) -> PetdexCatalogEntry {
    PetdexCatalogEntry(
        slug: slug,
        displayName: displayName,
        detail: detail,
        kind: kind,
        submittedBy: submittedBy,
        tags: tags,
        spritesheetURL: URL(string: "https://assets.petdex.dev/pets/\(slug)/spritesheet.webp")!,
        petJSONURL: nil,
        zipURL: nil,
        frameWidth: frameWidth,
        frameHeight: frameHeight
    )
}

private func testPetdexCatalogSearchFindsTagsAndRanksNameMatches() {
    let detailOnly = petdexEntry("sleepy-fox", displayName: "Sleepy Fox", detail: "A small boba companion")
    let tagOnly = petdexEntry("miso", displayName: "Miso", tags: ["Boba Tea"])
    let nameMatch = petdexEntry("boba", displayName: "Boba Cat", detail: "Round friend")

    let results = PetdexCatalogSearch.filter([detailOnly, tagOnly, nameMatch], query: "boba")

    expect(results.map(\.slug) == ["boba", "miso", "sleepy-fox"], "search should find tags/detail and rank name matches first")
}

private func testPetdexPreviewCacheKeysIncludeFrameSize() {
    let cache = PetdexPreviewCache()
    let image = NSImage(size: NSSize(width: 12, height: 12))
    let small = petdexEntry("miso", displayName: "Miso", frameWidth: 96, frameHeight: 104)
    let large = petdexEntry("miso", displayName: "Miso", frameWidth: 192, frameHeight: 208)

    cache.store(image, for: small)

    expect(cache.image(for: small) === image, "cache should return an image for the same URL and frame size")
    expect(cache.image(for: large) == nil, "cache key should include frame size so previews do not reuse the wrong crop")
}

private func testDaemonSnapshotPresenterMapsAttentionPriority() {
    func snapshot(attention: String, status: String, approval: Bool = false) -> DaemonSnapshot {
        DaemonSnapshot(
            attention: attention,
            sessions: [
                DaemonSession(
                    id: "s1",
                    cwd: "/repo",
                    title: "Repo",
                    status: status,
                    safeSummary: "running tests",
                    tools: nil
                ),
            ],
            pendingApprovals: approval
                ? [
                    DaemonPendingApproval(
                        id: "a1",
                        sessionId: "s1",
                        toolCallId: "t1",
                        toolName: "bash",
                        commandSummary: "git push origin main",
                        risk: "medium",
                        state: "pending"
                    ),
                ]
                : [],
            selectedPetId: nil,
            installedPets: []
        )
    }

    expect(DaemonSnapshotPresenter.presentation(for: snapshot(attention: "approval_required", status: "running", approval: true)).stateID == "waiting", "approval_required should use waiting pose")
    expect(DaemonSnapshotPresenter.presentation(for: snapshot(attention: "failed", status: "failed")).stateID == "failed", "failed should use failed pose")
    expect(DaemonSnapshotPresenter.presentation(for: snapshot(attention: "done", status: "done")).stateID == "waving", "done should use done/waving pose")
    expect(DaemonSnapshotPresenter.presentation(for: snapshot(attention: "running", status: "running")).stateID == "running", "running should use running pose")
    expect(DaemonSnapshotPresenter.presentation(for: snapshot(attention: "thinking", status: "thinking")).stateID == "review", "thinking should use review pose")
    expect(DaemonSnapshotPresenter.presentation(for: snapshot(attention: "idle", status: "idle")).stateID == "idle", "idle should use idle pose")

    let approvalPresentation = DaemonSnapshotPresenter.presentation(for: snapshot(attention: "approval_required", status: "running", approval: true))
    expect(approvalPresentation.bubble == "Approval needed: git push origin main", "approval bubble should contain only safe command summary")
}

private func testStateServerRequiresExplicitDebugFlag() {
    unsetenv("CODEX_PETS_ENABLE_HTTP_STATE_API")
    expect(!StateServer.isDebugEnabled, "legacy HTTP state API should be disabled by default")

    setenv("CODEX_PETS_ENABLE_HTTP_STATE_API", "1", 1)
    expect(StateServer.isDebugEnabled, "legacy HTTP state API should accept explicit debug flag")

    setenv("CODEX_PETS_ENABLE_HTTP_STATE_API", "false", 1)
    expect(!StateServer.isDebugEnabled, "legacy HTTP state API should reject false-like flag")
    unsetenv("CODEX_PETS_ENABLE_HTTP_STATE_API")
}

private func testPetdexBrowserBridgeActionAllowlist() {
    let allowed = Set(PetdexBrowserBridgeAction.allCases.map(\.rawValue))
    expect(
        allowed == Set([
            "importPet",
            "listInstalledPets",
            "selectInstalledPet",
            "uninstallInstalledPet",
            "getDaemonSnapshot",
            "approvalDecision",
        ]),
        "native bridge should expose only the expected allowlisted actions"
    )
    expect(PetdexBrowserBridgeAction(rawValue: "openShell") == nil, "native bridge should reject unknown actions")
    expect(PetdexBrowserBridgeAction(rawValue: "eval") == nil, "native bridge should reject privileged-looking actions")
}

private func testPetdexBrowserBridgePetPayloadValidation() {
    let valid = PetdexBrowserWindowController.entry(from: [
        "slug": "../Miso Pet",
        "displayName": " Miso Pet ",
        "description": "Soft fox",
        "kind": "fox",
        "submittedBy": "Ana",
        "tags": ["soft", "round"],
        "spritesheetUrl": "https://assets.petdex.dev/pets/miso/spritesheet.webp",
        "petJsonUrl": "https://assets.petdex.dev/pets/miso/pet.json",
        "zipUrl": "https://assets.petdex.dev/pets/miso/package.zip",
        "frameWidth": "96",
        "frameHeight": 104,
    ])

    expect(valid?.slug == "miso-pet", "bridge import payload should slugify path-like slugs")
    expect(valid?.displayName == "Miso Pet", "bridge import payload should trim display name")
    expect(valid?.frameWidth == 96, "bridge import payload should parse positive frame width")
    expect(valid?.frameHeight == 104, "bridge import payload should parse positive frame height")
    expect(valid?.tags == ["soft", "round"], "bridge import payload should preserve string tags")

    let localSprite = PetdexBrowserWindowController.entry(from: [
        "slug": "local",
        "displayName": "Local",
        "spritesheetUrl": "file:///Users/me/secret.png",
    ])
    expect(localSprite == nil, "bridge import payload should reject local file spritesheet URLs")

    let localPetJSON = PetdexBrowserWindowController.entry(from: [
        "slug": "remote-sprite-local-json",
        "displayName": "Remote Sprite",
        "spritesheetUrl": "https://assets.petdex.dev/pets/x/spritesheet.webp",
        "petJsonUrl": "file:///Users/me/pet.json",
    ])
    expect(localPetJSON?.petJSONURL == nil, "bridge import payload should ignore local file pet.json URLs")
}

private func testInstalledPetPayloadIsDataOnly() {
    let pet = PetPackage(
        slug: "miso",
        displayName: "Miso",
        detail: "Imported pet",
        kind: "fox",
        source: .app,
        directory: URL(fileURLWithPath: "/tmp/codex-pets/miso"),
        spritesheet: URL(fileURLWithPath: "/tmp/codex-pets/miso/spritesheet.png"),
        frameWidth: 96,
        frameHeight: 104,
        states: PetAnimationState.defaults
    )

    let payload = PetdexBrowserWindowController.installedPetPayload(pet)
    expect(payload["source"] as? String == "installed", "installed pet payload should be marked as installed source")
    expect(payload["nativePetId"] as? String == pet.id, "installed pet payload should include opaque native pet id")
    expect(payload["spritesheetUrl"] as? String == pet.spritesheet.absoluteString, "installed pet payload should expose only file URL for spritesheet preview")
    expect(payload["canUninstall"] as? Bool == true, "app-imported installed pet should be uninstallable")
    expect(payload["frameWidth"] as? Int == 96, "installed pet payload should preserve frame width")
    expect(payload["frameHeight"] as? Int == 104, "installed pet payload should preserve frame height")

    let external = PetPackage(
        slug: "codex",
        displayName: "Codex Pet",
        detail: "Shared pet",
        kind: "pet",
        source: .codex,
        directory: URL(fileURLWithPath: "/Users/me/.codex/pets/codex"),
        spritesheet: URL(fileURLWithPath: "/Users/me/.codex/pets/codex/spritesheet.png"),
        frameWidth: 192,
        frameHeight: 208,
        states: PetAnimationState.defaults
    )
    let externalPayload = PetdexBrowserWindowController.installedPetPayload(external)
    expect(externalPayload["canUninstall"] as? Bool == false, "shared .codex installed pet should not be uninstallable from app storage")
}

private func testInAppDaemonServesPiProtocolOverUnixSocket() {
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("codex-pets-in-app-daemon-\(UUID().uuidString)", isDirectory: true)
    let socketPath = directory.appendingPathComponent("pi-pet.sock").path
    let daemon = InAppDaemon(socketPath: socketPath)
    daemon.start()
    defer {
        daemon.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    let running = daemonRequest(
        socketPath: socketPath,
        method: "session.upsert",
        payload: [
            "sessionId": "swift-test",
            "cwd": "/tmp",
            "title": "Swift Test",
            "status": "running",
            "safeSummary": "agent running",
        ]
    )
    let runningPayload = running["payload"] as? [String: Any]
    expect(runningPayload?["attention"] as? String == "running", "in-app daemon should derive running attention")
    expect((runningPayload?["sessions"] as? [[String: Any]])?.count == 1, "in-app daemon should return sessions as an array")
    expect((runningPayload?["pendingApprovals"] as? [[String: Any]])?.isEmpty == true, "in-app daemon should return approvals as an array")

    let toolUpdate = daemonRequest(
        socketPath: socketPath,
        method: "tool.update",
        payload: [
            "sessionId": "swift-test",
            "toolCallId": "tool-1",
            "toolName": "bash",
            "safeSummary": "bash running",
        ]
    )
    let toolPayload = toolUpdate["payload"] as? [String: Any]
    let sessions = toolPayload?["sessions"] as? [[String: Any]]
    let tools = sessions?.first?["tools"] as? [[String: Any]]
    expect(tools?.first?["state"] as? String == "running", "in-app daemon should track tool update state")
    expect(tools?.first?["safeSummary"] as? String == "bash running", "in-app daemon should track safe tool summaries")
}

private func daemonRequest(socketPath: String, method: String, payload: [String: Any]) -> [String: Any] {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    expect(fd >= 0, "test socket should open")
    defer { Darwin.close(fd) }

    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    expect(connectUnixForTest(fd, path: socketPath), "test socket should connect to in-app daemon")

    let message: [String: Any] = [
        "version": 1,
        "kind": "request",
        "id": "test-\(method)",
        "method": method,
        "payload": payload,
    ]
    guard JSONSerialization.isValidJSONObject(message),
          var data = try? JSONSerialization.data(withJSONObject: message, options: [])
    else {
        expect(false, "test daemon request should encode")
        return [:]
    }
    data.append(0x0a)
    let sent = data.withUnsafeBytes { rawBuffer in
        Darwin.write(fd, rawBuffer.baseAddress, data.count)
    }
    expect(sent == data.count, "test daemon request should write")

    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while response.firstIndex(of: 0x0a) == nil {
        let count = buffer.withUnsafeMutableBytes { rawBuffer in
            Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
        }
        expect(count > 0, "test daemon response should read")
        response.append(contentsOf: buffer.prefix(count))
    }
    let line = Data(response[..<(response.firstIndex(of: 0x0a) ?? response.endIndex)])
    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
        expect(false, "test daemon response should decode")
        return [:]
    }
    expect(object["error"] == nil, "test daemon response should not be an error: \(object)")
    return object
}

private func connectUnixForTest(_ fd: Int32, path: String) -> Bool {
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count <= maxPathLength else { return false }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { destination in
            for index in 0..<maxPathLength {
                destination[index] = 0
            }
            for index in 0..<bytes.count {
                destination[index] = bytes[index]
            }
        }
    }
    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            Darwin.connect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
        }
    }
}

let tests: [(String, () -> Void)] = [
    ("dialogue avoids repeats", testDialogueEngineAvoidsExactAndSemanticRepeats),
    ("dialogue modes and daily budget", testDialogueModesAndDailyBudget),
    ("important workflow bypasses low-priority daily cap", testDialogueImportantWorkflowBypassesLowPriorityDailyCap),
    ("mute for today uses local calendar", testMuteForTodayUsesLocalCalendarBoundary),
    ("pet brain curated workflow murmurs", testPetBrainUsesCuratedMurmursForWorkflowStatus),
    ("bubble dismissal mutes murmurs", testPetBrainDismissedBubbleMutesMurmursForHours),
    ("overlay hit testing makes whole pet body draggable", testOverlayHitTestingMakesWholePetBodyDraggable),
    ("Petdex manifest parser supports v1 and v2", testPetdexManifestParserSupportsV1AndV2),
    ("downloaded Petdex import writes local package", testDownloadedPetdexImportWritesPackageSafely),
    ("Petdex catalog search finds tags and ranks name matches", testPetdexCatalogSearchFindsTagsAndRanksNameMatches),
    ("Petdex preview cache keys include frame size", testPetdexPreviewCacheKeysIncludeFrameSize),
    ("daemon snapshot presenter maps attention", testDaemonSnapshotPresenterMapsAttentionPriority),
    ("debug state server is opt-in", testStateServerRequiresExplicitDebugFlag),
    ("Petdex browser bridge action allowlist", testPetdexBrowserBridgeActionAllowlist),
    ("Petdex browser bridge pet payload validation", testPetdexBrowserBridgePetPayloadValidation),
    ("installed pet payload is data-only", testInstalledPetPayloadIsDataOnly),
    ("in-app daemon Pi protocol socket", testInAppDaemonServesPiProtocolOverUnixSocket),
    ("mouse proximity dwell/cooldown", testMouseProximityRequiresDwellAndCooldown),
    ("focus + reduce motion", testFocusModeAndReduceMotionStayQuiet),
    ("Codex events", testCodexEventsMapToEmotionsAndBubbles),
    ("click spam annoyed", testClickSpamBecomesAnnoyed),
    ("idle attention budget", testIdleAttentionBudgetCapsMicroIdle),
    ("long-running settle", testLongRunningSettlesToWaitingPose),
    ("manual animated states", testManualAnimatedStatesPlayOnce),
    ("double-click cooldown override", testDoubleClickOverridesSingleClickCooldown),
    ("directional drag running loop", testDragUsesDirectionalRunningLoop),
    ("success during happy cooldown", testSuccessEventStillAppliesDuringHappyCooldown),
    ("reduce motion off resumes running", testReduceMotionOffResumesRunningPlayback),
    ("mouse leave resets dwell", testMouseLeavingRadiusResetsDwell),
]

for (name, test) in tests {
    test()
    print("✓ \(name)")
}
print("PetBrain tests passed")
