import Foundation
import Testing
@testable import TamagotchiCore
import TamagotchiWire

@Suite("Daily recap")
struct DailyRecapTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2027-01-15 00:00 UTC.
    let day = Date(timeIntervalSince1970: 1_799_971_200)

    func at(_ hour: Double, dayOffset: Int = 0) -> Date {
        day.addingTimeInterval(Double(dayOffset) * 86_400 + hour * 3_600)
    }

    func event(_ name: String, _ hour: Double, session: String = "s1", tool: String? = nil, dayOffset: Int = 0,
               configure: (inout WireEvent) -> Void = { _ in }) -> CompanionEvent {
        TestSupport.event(name, session: session, tool: tool, at: at(hour, dayOffset: dayOffset), configure: configure)
    }

    func recap(_ events: [CompanionEvent], focus: [FocusBlock] = [], historyStart: Date? = nil) -> DailyRecap {
        DailyRecap.compute(day: at(12), events: events, focus: focus, historyStart: historyStart ?? at(0, dayOffset: -7),
                           calendar: Self.calendar)
    }

    var busyDay: [CompanionEvent] {
        var events = [
            event("SessionStart", 9.0),
            event("UserPromptSubmit", 9.1),
            event("PreToolUse", 9.2, tool: "Read"),
            event("PostToolUse", 9.25, tool: "Read"),
            event("PreToolUse", 9.3, tool: "Read"),
            event("PostToolUse", 9.35, tool: "Read"),
            event("PreToolUse", 9.4, tool: "Grep"),
            event("PostToolUse", 9.45, tool: "Grep"),
            event("PreToolUse", 9.5, tool: "Bash"),
            event("PostToolUseFailure", 9.55, tool: "Bash") { $0.exitCode = 1 },
            event("PreToolUse", 9.6, tool: "Read"),
            event("PostToolUse", 9.65, tool: "Read"),
            event("Stop", 9.8),
            event("UserPromptSubmit", 14.0, session: "s2"),
            event("PreToolUse", 14.1, session: "s2", tool: "Bash"),
            event("PostToolUse", 14.2, session: "s2", tool: "Bash") {
                $0.commandKind = "test"
                $0.commandReliable = true
                $0.exitCode = 0
            },
            event("Stop", 14.5, session: "s2"),
            event("Stop", 9.0, dayOffset: -1),
        ]
        var simulated = event("Stop", 16, session: "sim")
        simulated.origin = .simulator
        events.append(simulated)
        return events
    }

    @Test func countsOnlyRealEventsOfThatDay() {
        let recap = recap(busyDay)
        #expect(recap.sessions == 2)
        #expect(recap.turnsFinished == 2)
        #expect(recap.toolCalls == 6)
        #expect(recap.topToolCategory == .read)
        #expect(recap.testsPassed == 1)
        #expect(recap.buildsPassed == 0)
        #expect(recap.errorsBouncedBack == 1)
        #expect(recap.firstActivity == at(9))
        #expect(recap.lastActivity == at(14.5))
        #expect(recap.activeSpan == 5.5 * 3_600)
        #expect(recap.coverage == .full)
        #expect(recap.hasActivity && !recap.isQuiet)
    }

    @Test func tilesLeaveOutWhatDidNotHappen() {
        let tiles = recap(busyDay).tiles
        #expect(tiles == [
            .turns(2), .sessions(2), .toolCalls(6, top: .read), .buildsAndTests(builds: 0, tests: 1), .bouncedBack(1),
            .activeSpan(from: at(9), to: at(14.5)),
        ])
        #expect(!tiles.contains { if case .focus = $0 { return true } else { return false } })
    }

    @Test func aQuietDayHasNoTilesAndSaysSo() {
        let recap = recap([event("Stop", 9, dayOffset: -1)])
        #expect(recap.isQuiet)
        #expect(recap.tiles.isEmpty)
        #expect(recap.streak == 0)
        #expect(recap.summary(petName: "Mochi", companionName: "Patch").hasPrefix("A quiet day"))
    }

    @Test func focusTimeComesFromTheLog() {
        let blocks = [FocusBlock(endedAt: at(10), minutes: 25), FocusBlock(endedAt: at(11), minutes: 25),
                      FocusBlock(endedAt: at(23.9, dayOffset: -1), minutes: 25)]
        let recap = recap([], focus: blocks)
        #expect(recap.focusBlocks == 2)
        #expect(recap.focusMinutes == 50)
        #expect(!recap.isQuiet && !recap.hasActivity)
        #expect(recap.tiles == [.focus(minutes: 50, blocks: 2)])
        #expect(recap.summary(petName: "Mochi", companionName: "Patch").contains("50 minutes"))
    }

    @Test func bouncingBackNeedsAFinishedTurnInTheSameSession() {
        let events = [
            event("PostToolUseFailure", 9, tool: "Bash"),
            event("PostToolUseFailure", 9.1, tool: "Bash") { $0.isInterrupt = true },
            event("StopFailure", 9.2, session: "s2"),
            event("Stop", 9.5, session: "s2"),
            event("PostToolUseFailure", 10, session: "s3", tool: "Bash"),
            event("Stop", 9.9, session: "s3"),
        ]
        // s1's error never got a finished turn, the interrupt isn't an error, s2's API error did, s3's came after its turn.
        #expect(recap(events).errorsBouncedBack == 1)
    }

    @Test func streakCountsConsecutiveActiveDays() {
        let events = [event("Stop", 10), event("Stop", 10, dayOffset: -1), event("Stop", 22, dayOffset: -2),
                      event("Stop", 10, dayOffset: -4)]
        let exact = recap(events)
        #expect(exact.streak == 3)
        #expect(!exact.streakIsLowerBound)
        // History only starts mid-way through the third day: it may go back further.
        let limited = recap(events, historyStart: at(12, dayOffset: -2))
        #expect(limited.streak == 3)
        #expect(limited.streakIsLowerBound)
    }

    @Test func coverageSaysWhenHistoryStartsLate() {
        #expect(recap(busyDay, historyStart: at(8)).coverage == .partial(since: at(8)))
        #expect(recap(busyDay, historyStart: at(0, dayOffset: 2)).coverage == .none)
    }

    @Test func summariesUseOnlyRealNumbers() {
        let text = recap(busyDay).summary(petName: "Mochi", companionName: "Patch")
        #expect(text == "Bounced back from 1 error and still finished 2 turns. Resilient!")
        var recap = DailyRecap(day: day, coverage: .full)
        recap.firstActivity = at(9)
        recap.lastActivity = at(9)
        recap.sessions = 1
        #expect(recap.summary(petName: "Mochi", companionName: "Patch") == "Patch dropped by for 1 session today.")
        let banner = self.recap(busyDay).readyBanner(petName: "Mochi", companionName: "Patch")
        #expect(banner.body.contains("2 turns finished"))
    }

    @Test func theEveningAnnouncementHappensOncePerActiveDay() {
        var settings = RecapSettings()
        let calendar = Self.calendar
        #expect(!settings.isAnnouncementDue(at: at(17.9), hasActivity: true, calendar: calendar))
        #expect(settings.isAnnouncementDue(at: at(18), hasActivity: true, calendar: calendar))
        #expect(!settings.isAnnouncementDue(at: at(19), hasActivity: false, calendar: calendar))
        settings.lastAnnouncedDay = DailyRecap.dayKey(at(18), calendar: calendar)
        #expect(settings.lastAnnouncedDay == "2027-01-15")
        #expect(!settings.isAnnouncementDue(at: at(21), hasActivity: true, calendar: calendar))
        #expect(settings.isAnnouncementDue(at: at(18, dayOffset: 1), hasActivity: true, calendar: calendar))
        settings.announce = false
        #expect(!settings.isAnnouncementDue(at: at(18, dayOffset: 1), hasActivity: true, calendar: calendar))
    }

    @Test func dayNamesAreFriendly() {
        let now = at(15)
        #expect(DailyRecap.dayName(at(1), now: now, calendar: Self.calendar) == "Today")
        #expect(DailyRecap.dayName(at(1, dayOffset: -1), now: now, calendar: Self.calendar) == "Yesterday")
        #expect(DailyRecap.dayName(at(1, dayOffset: -2), now: now, calendar: Self.calendar) == "Wednesday")
    }
}
