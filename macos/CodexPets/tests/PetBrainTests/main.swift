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

private func testMouseProximityRequiresDwellAndCooldown() {
    let clock = TestClock()
    let brain = PetBrain(mode: .default, now: { clock.now })

    expect(brain.handle(.mouseNear(distance: 110)) == nil, "near cursor should dwell before curious")
    clock.advance(0.45)
    let curious = expectDecision(brain.handle(.mouseNear(distance: 100)), "near cursor after dwell")
    expect(curious.mood == .curious, "near cursor after dwell should be curious")
    expect(curious.stateID == "waiting", "curious should use waiting pose")
    expect(curious.bubble == nil, "curious proximity should not show bubbles")

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
    let clock = TestClock()
    let brain = PetBrain(mode: .default, now: { clock.now })

    let success = expectDecision(
        brain.handle(.codexEvent(type: "task.succeeded", label: "Tests passed", importance: .low)),
        "task success"
    )
    expect(success.mood == .happy, "task.succeeded should be happy")
    expect(success.stateID == "waving", "task.succeeded should wave")
    expect(success.bubble == nil, "low-importance success should not bubble in default mode")
    expect(success.duration == 1.6, "success should be short")

    clock.advance(20)
    let needsUser = expectDecision(
        brain.handle(.codexEvent(type: "task.needs_user", label: "Review changes?", importance: .medium)),
        "needs user"
    )
    expect(needsUser.mood == .waiting, "task.needs_user should be waiting")
    expect(needsUser.stateID == "review", "task.needs_user should use review pose")
    expect(needsUser.bubble == "Review changes?", "medium needs-user event should bubble once")
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
    expect(annoyed.bubble == nil, "annoyed should not guilt-trip with text")
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

let tests: [(String, () -> Void)] = [
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
