import Foundation
import Testing
@testable import TamagotchiCore

@Suite("Focus buddy")
struct FocusTimerTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func timer(cycles: Int = 4) -> FocusTimer {
        FocusTimer(durations: .init(focus: 25 * 60, shortBreak: 5 * 60, longBreak: 15 * 60, cyclesBeforeLongBreak: cycles))
    }

    @Test func startsWithAFocusBlockMochiNapsThrough() {
        var timer = timer()
        #expect(timer.start(at: start) == [.started(.focus, cycle: 1)])
        let status = timer.status(naps: true)
        #expect(status?.phase == .focus)
        #expect(status?.cycle == 1)
        #expect(status?.petNaps == true)
        #expect(status?.remaining(at: start.addingTimeInterval(60)) == TimeInterval(24 * 60))
        #expect(timer.status(naps: false)?.petNaps == false)
    }

    @Test func aFinishedBlockIsLoggedAndABreakBegins() {
        var timer = timer()
        timer.start(at: start)
        #expect(timer.advance(to: start.addingTimeInterval(24 * 60)).isEmpty)
        let end = start.addingTimeInterval(25 * 60)
        let transitions = timer.advance(to: end.addingTimeInterval(0.6))
        #expect(transitions == [.focusCompleted(FocusBlock(endedAt: end, minutes: 25)), .started(.shortBreak, cycle: 1)])
        // Noticed on time: the break starts exactly when the block ended, so nothing drifts.
        #expect(timer.running?.startedAt == end)
        #expect(timer.status(naps: true)?.petNaps == false)
        #expect(timer.completedBlocks == 1)
    }

    @Test func aLongBreakFollowsTheLastCycleAndEndsTheSet() {
        var timer = timer(cycles: 2)
        timer.start(at: start)
        var now = start
        var all: [FocusTimer.Transition] = []
        for _ in 0..<10 where timer.isRunning {
            now = timer.running!.endsAt
            all += timer.advance(to: now)
        }
        let started = all.compactMap { transition -> String? in
            if case .started(let phase, let cycle) = transition { return "\(phase.rawValue)\(cycle)" }
            return nil
        }
        #expect(started == ["shortBreak1", "focus2", "longBreak2"])
        #expect(all.last == .finished(blocks: 2))
        #expect(!timer.isRunning)
        #expect(timer.status(naps: true) == nil)
        #expect(now == start.addingTimeInterval((25 + 5 + 25 + 15) * 60))
    }

    @Test func skippingFocusDoesNotCountTheBlock() {
        var timer = timer()
        timer.start(at: start)
        let now = start.addingTimeInterval(10 * 60)
        #expect(timer.skip(at: now) == [.started(.shortBreak, cycle: 1)])
        #expect(timer.completedBlocks == 0)
        #expect(timer.running?.startedAt == now)
        #expect(timer.skip(at: now.addingTimeInterval(30)) == [.started(.focus, cycle: 2)])
    }

    @Test func stoppingEndsTheSession() {
        var timer = timer()
        timer.start(at: start)
        #expect(timer.stop(at: start.addingTimeInterval(5)) == [.stopped])
        #expect(!timer.isRunning)
        #expect(timer.stop(at: start.addingTimeInterval(6)).isEmpty)
        #expect(timer.advance(to: start.addingTimeInterval(3_600)).isEmpty)
    }

    @Test func aBlockSleptThroughIsNotCounted() {
        var timer = timer()
        timer.start(at: start)
        let transitions = timer.advance(to: start.addingTimeInterval(25 * 60 + FocusTimer.staleAfter + 1))
        #expect(transitions == [.expired])
        #expect(!timer.isRunning)
        #expect(timer.completedBlocks == 0)
    }

    @Test func aLateTickStartsTheNextPhaseFromNow() {
        var timer = timer()
        timer.start(at: start)
        let late = start.addingTimeInterval(25 * 60 + 40)
        timer.advance(to: late)
        #expect(timer.running?.startedAt == late)
        #expect(timer.running?.phase == .shortBreak)
    }

    @Test func durationsComeFromSettingsWithinBounds() {
        var settings = FocusSettings()
        settings.workMinutes = 50
        settings.breakMinutes = 0
        settings.longBreakMinutes = 500
        settings.cyclesBeforeLongBreak = 0
        let durations = FocusTimer.Durations(settings)
        #expect(durations.focus == 50 * 60)
        #expect(durations.shortBreak == 60)
        #expect(durations.longBreak == 90 * 60)
        #expect(durations.cyclesBeforeLongBreak == 1)
    }

    @Test func focusKeepsOnlyUrgentSounds() {
        var settings = AppSettings()
        settings.soundEnabled = true
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let focusing = NotificationContext(now: now, focusing: true)
        #expect(NotificationPolicy.decide(.needsAttention, settings: settings, context: focusing).sound)
        #expect(!NotificationPolicy.decide(.turnCompleted, settings: settings, context: focusing).sound)
        #expect(NotificationPolicy.decide(.turnCompleted, settings: settings, context: focusing).animate)
        #expect(NotificationPolicy.decide(.turnCompleted, settings: settings, context: NotificationContext(now: now)).sound)
    }

    @Test func remainingTimeReadsLikeAClock() {
        #expect(FocusStatus.clock(18 * 60 + 41.2) == "18:42")
        #expect(FocusStatus.clock(59) == "0:59")
        #expect(FocusStatus.clock(3_900) == "1:05:00")
        #expect(FocusStatus.clock(-3) == "0:00")
    }

    @Test @MainActor func theLogKeepsCompletedBlocksAndFollowsRetention() throws {
        let directory = TestSupport.temporaryDirectory()
        let url = directory.appendingPathComponent("focus-log.json")
        let now = start
        let log = FocusLog(fileURL: url, retentionDays: 7)
        log.append(FocusBlock(endedAt: now.addingTimeInterval(-8 * 86_400), minutes: 25), now: now)
        log.append(FocusBlock(endedAt: now.addingTimeInterval(-60), minutes: 25), now: now)
        log.append(FocusBlock(endedAt: now, minutes: 0), now: now)
        #expect(log.blocks.count == 1)
        let reloaded = FocusLog(fileURL: url, retentionDays: 7)
        reloaded.load(now: now)
        #expect(reloaded.blocks == log.blocks)
        let memoryOnly = FocusLog(fileURL: url, retentionDays: 0)
        memoryOnly.append(FocusBlock(endedAt: now, minutes: 25), now: now)
        #expect(memoryOnly.blocks.count == 1)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
