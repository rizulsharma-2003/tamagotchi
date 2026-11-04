import Foundation
import Testing
@testable import TamagotchiCore

private let gregorian: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
    return calendar
}()

private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
    gregorian.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

private func event(_ date: Date, settings: SeasonalSettings = SeasonalSettings(), adopted: Date? = nil) -> SeasonalEvent? {
    SeasonCalendar.event(on: date, settings: settings, mochiBirthday: adopted, calendar: gregorian)
}

@Suite("Season calendar")
struct SeasonCalendarTests {
    @Test func halloweenRunsFromTheTwentyFourthToAllSaints() {
        #expect(event(day(2026, 10, 23)) == nil)
        #expect(event(day(2026, 10, 24, hour: 0)) == .halloween)
        #expect(event(day(2026, 10, 28)) == .halloween)
        #expect(event(day(2026, 11, 1, hour: 23)) == .halloween)
        #expect(event(day(2026, 11, 2, hour: 0)) == nil)
    }

    @Test func diwaliWindowIsThreeDaysBeforeToTwoAfter() {
        #expect(event(day(2026, 11, 4)) == nil)
        for date in 5...10 { #expect(event(day(2026, 11, date)) == .diwali) }
        #expect(event(day(2026, 11, 11)) == nil)
        #expect(event(day(2025, 10, 20)) == .diwali)
        #expect(event(day(2029, 11, 5)) == .diwali)
        // Years without a known date simply have no Diwali.
        #expect(event(day(2040, 11, 8)) == nil)
    }

    @Test func diwaliWinsOverHalloweenWhenTheyOverlap() {
        #expect(event(day(2027, 10, 29)) == .diwali)
        #expect(event(day(2027, 11, 1)) == .halloween)
        #expect(event(day(2030, 10, 28)) == .diwali)
        #expect(SeasonCalendar.activeEvents(on: day(2027, 10, 29), settings: SeasonalSettings(), mochiBirthday: nil, calendar: gregorian)
                == [.diwali, .halloween])
    }

    @Test func winterAndSpringWindows() {
        #expect(event(day(2026, 12, 17)) == nil)
        #expect(event(day(2026, 12, 18)) == .christmas)
        #expect(event(day(2026, 12, 26)) == .christmas)
        #expect(event(day(2026, 12, 27)) == nil)
        #expect(event(day(2026, 12, 31)) == .newYear)
        #expect(event(day(2027, 1, 1)) == .newYear)
        #expect(event(day(2027, 1, 2)) == nil)
        #expect(event(day(2027, 2, 12)) == nil)
        #expect(event(day(2027, 2, 13)) == .valentines)
        #expect(event(day(2027, 2, 14)) == .valentines)
        #expect(event(day(2027, 2, 15)) == nil)
    }

    @Test func birthdaysComeFirst() {
        var settings = SeasonalSettings()
        settings.birthdayMonth = 10
        settings.birthdayDay = 30
        let adopted = day(2025, 11, 7)
        #expect(event(day(2026, 10, 30), settings: settings, adopted: adopted) == .userBirthday)
        #expect(event(day(2026, 10, 29), settings: settings, adopted: adopted) == .halloween)
        // The pet's birthday beats Diwali, and only counts from the first anniversary on.
        #expect(event(day(2026, 11, 7), settings: settings, adopted: adopted) == .mochiBirthday)
        #expect(event(day(2025, 11, 7), settings: settings, adopted: adopted) == nil)
        // The user's birthday beats the pet's.
        settings.birthdayMonth = 11
        settings.birthdayDay = 7
        #expect(event(day(2026, 11, 7), settings: settings, adopted: adopted) == .userBirthday)
        // A half-set birthday is ignored.
        settings.birthdayDay = nil
        #expect(event(day(2026, 11, 7), settings: settings, adopted: adopted) == .mochiBirthday)
    }

    @Test func leapDayBirthdaysMoveToTheTwentyEighth() {
        var settings = SeasonalSettings()
        settings.birthdayMonth = 2
        settings.birthdayDay = 29
        #expect(event(day(2027, 2, 28), settings: settings) == .userBirthday)
        #expect(event(day(2028, 2, 28), settings: settings) == nil)
        #expect(event(day(2028, 2, 29), settings: settings) == .userBirthday)
    }

    @Test func disabledMeansNoEvents() {
        var settings = SeasonalSettings()
        settings.enabled = false
        settings.birthdayMonth = 10
        settings.birthdayDay = 28
        #expect(event(day(2026, 10, 28), settings: settings) == nil)
        #expect(SeasonCalendar.nextEvent(after: day(2026, 10, 28), settings: settings, mochiBirthday: nil, calendar: gregorian) == nil)
    }

    @Test func nextEventAndLastDay() throws {
        let settings = SeasonalSettings()
        let next = try #require(SeasonCalendar.nextEvent(after: day(2026, 10, 28), settings: settings, mochiBirthday: nil, calendar: gregorian))
        #expect(next.event == .diwali)
        #expect(gregorian.dateComponents([.month, .day], from: next.starts) == DateComponents(month: 11, day: 5))
        let afterDiwali = try #require(SeasonCalendar.nextEvent(after: day(2026, 11, 9), settings: settings, mochiBirthday: nil, calendar: gregorian))
        #expect(afterDiwali.event == .christmas)
        let last = try #require(SeasonCalendar.lastDay(of: .halloween, from: day(2026, 10, 28), settings: settings, mochiBirthday: nil,
                                                       calendar: gregorian))
        #expect(gregorian.dateComponents([.month, .day], from: last) == DateComponents(month: 11, day: 1))
        #expect(SeasonCalendar.lastDay(of: .christmas, from: day(2026, 10, 28), settings: settings, mochiBirthday: nil, calendar: gregorian) == nil)
    }

    @Test func occasionKeysGreetOncePerOccurrence() {
        #expect(SeasonCalendar.occasionKey(.halloween, on: day(2026, 10, 28), calendar: gregorian) == "halloween-2026")
        #expect(SeasonCalendar.occasionKey(.newYear, on: day(2026, 12, 31), calendar: gregorian) == "newYear-2027")
        #expect(SeasonCalendar.occasionKey(.newYear, on: day(2027, 1, 1), calendar: gregorian) == "newYear-2027")
        #expect(SeasonCalendar.newYear(on: day(2026, 12, 31), calendar: gregorian) == 2027)
        #expect(SeasonCalendar.newYear(on: day(2026, 10, 28), calendar: gregorian) == 2027)
        #expect(SeasonCalendar.newYear(on: day(2027, 1, 1), calendar: gregorian) == 2027)
        #expect(SeasonCalendar.yearsSince(day(2025, 11, 7), on: day(2027, 11, 7), calendar: gregorian) == 2)
    }

    @Test func prioritiesAreDistinct() {
        #expect(Set(SeasonalEvent.allCases.map(\.priority)).count == SeasonalEvent.allCases.count)
        #expect(SeasonalEvent.userBirthday.priority > SeasonalEvent.mochiBirthday.priority)
        #expect(SeasonalEvent.diwali.priority > SeasonalEvent.halloween.priority)
        #expect(SeasonalEvent.newYear.priority > SeasonalEvent.valentines.priority)
    }
}

@Suite("Room makeover")
struct RoomMakeoverTests {
    @Test func catalogIsCosyAndWellFormed() {
        let all = FurnitureCatalog.all
        #expect((10...12).contains(all.count))
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(all.contains { $0.placement == .wall })
        #expect(all.contains { $0.placement == .floor })
        for kind in all {
            #expect(kind.width > 0 && kind.width < FurnitureCatalog.roomWidth / 2)
            #expect(kind.height > 0 && kind.height < FurnitureCatalog.roomHeight * 0.6)
            #expect((0...1).contains(kind.defaultX))
            #expect(FurnitureCatalog.kind(kind.id) == kind)
            #expect(!kind.unlockHint.isEmpty)
        }
        #expect(FurnitureCatalog.kind("piano") == nil)
    }

    @Test func unlocksFollowFriendshipAndAchievements() {
        var progress = ProgressState()
        let starters = FurnitureCatalog.unlocked(progress)
        #expect(starters.count >= 3)
        #expect(starters.allSatisfy { $0.unlock == .always })

        let lamp = FurnitureCatalog.kind("lamp")!
        #expect(lamp.unlock == .friendshipLevel(1))
        #expect(!lamp.isUnlocked(progress))
        progress.affectionPoints = ProgressState.levelThresholds[1]
        #expect(lamp.isUnlocked(progress))

        let clock = FurnitureCatalog.kind("clock")!
        #expect(!clock.isUnlocked(progress))
        progress.unlocked[AchievementID.firstSession.rawValue] = Date()
        #expect(clock.isUnlocked(progress))
        #expect(clock.unlockHint.contains(AchievementID.firstSession.title))

        progress.affectionPoints = 10_000
        for id in AchievementID.allCases { progress.unlocked[id.rawValue] = Date() }
        #expect(FurnitureCatalog.unlocked(progress).count == FurnitureCatalog.all.count)
    }

    @Test func piecesSnapIntoTheirBand() {
        let poster = FurnitureCatalog.kind("poster")!
        let plant = FurnitureCatalog.kind("plant")!
        let rug = FurnitureCatalog.kind("rug")!
        let onWall = RoomLayout.snapped(poster, x: 0.5, y: 0.95)
        #expect(onWall.y == RoomLayout.wallBand.upperBound)
        #expect(RoomLayout.snapped(poster, x: 0.5, y: 0).y == RoomLayout.wallBand.lowerBound)
        let onFloor = RoomLayout.snapped(plant, x: 0.5, y: 0.2)
        #expect(onFloor.y == RoomLayout.floorBand.lowerBound)
        #expect(RoomLayout.snapped(rug, x: 0.5, y: 1).y == RoomLayout.rugBand.upperBound)
        // Nothing hangs over the edges.
        let left = RoomLayout.snapped(plant, x: -3, y: 0.9)
        #expect(left.x * FurnitureCatalog.roomWidth >= plant.width / 2 - 0.001)
        let right = RoomLayout.snapped(plant, x: 4, y: 0.9)
        #expect((1 - right.x) * FurnitureCatalog.roomWidth >= plant.width / 2 - 0.001)
        let garbage = RoomLayout.snapped(plant, x: .nan, y: .infinity)
        #expect(garbage.x.isFinite && garbage.y.isFinite)
    }

    @Test func roomHoldsAtMostEightPieces() {
        var room = RoomLayout()
        let cushion = FurnitureCatalog.kind("cushion")!
        for _ in 0..<RoomLayout.maxItems { #expect(room.add(cushion) != nil) }
        #expect(room.isFull)
        #expect(room.add(cushion) == nil)
        #expect(room.items.count == RoomLayout.maxItems)
    }

    @Test func addingWithoutAPositionFindsAFreeSpot() throws {
        var room = RoomLayout()
        let plant = FurnitureCatalog.kind("plant")!
        let added = (room.add(plant), room.add(plant))
        let first = try #require(added.0)
        let second = try #require(added.1)
        #expect(first.x != second.x)
        #expect(first.y == RoomLayout.floorBand.lowerBound)
        let added2 = room.add(plant, x: 0.5, y: 0.1)
        let placed = try #require(added2)
        #expect(placed.y == RoomLayout.floorBand.lowerBound)
        #expect(placed.x == 0.5)
    }

    @Test func moveFlipAndRemove() throws {
        var room = RoomLayout()
        let clock = FurnitureCatalog.kind("clock")!
        let added = room.add(clock)
        let item = try #require(added)
        room.move(item.id, x: 0.7, y: 0.99)
        #expect(room.items[0].x == 0.7)
        #expect(room.items[0].y == RoomLayout.wallBand.upperBound)
        room.toggleFlip(item.id)
        #expect(room.items[0].flipped)
        room.remove(item.id)
        #expect(room.items.isEmpty)
        room.move(item.id, x: 0.1, y: 0.1) // unknown ids are ignored
        #expect(room.items.isEmpty)
    }

    @Test func sanitizingDropsUnknownPiecesAndRepairsPositions() {
        var room = RoomLayout()
        room.items.append(PlacedFurniture(kind: "spaceship", x: 0.5, y: 0.5))
        room.items.append(PlacedFurniture(kind: "lamp", x: 2, y: 0.1))
        for _ in 0..<10 { room.items.append(PlacedFurniture(kind: "cushion", x: 0.5, y: 0.9)) }
        let clean = room.sanitized()
        #expect(clean.items.count == RoomLayout.maxItems)
        #expect(!clean.items.contains { $0.kind == "spaceship" })
        #expect(clean.items[0].kind == "lamp")
        #expect(clean.items[0].x < 1)
        #expect(RoomLayout.floorBand.contains(clean.items[0].y))
    }

    @Test func drawingOrderPutsRugsFirstAndTheFrontLast() {
        var room = RoomLayout()
        room.items = [
            PlacedFurniture(kind: "plant", x: 0.1, y: 0.92),
            PlacedFurniture(kind: "poster", x: 0.5, y: 0.4),
            PlacedFurniture(kind: "lamp", x: 0.9, y: 0.87),
            PlacedFurniture(kind: "rug", x: 0.5, y: 0.93),
        ]
        #expect(room.drawingOrder.map(\.kind) == ["rug", "poster", "lamp", "plant"])
    }

    @Test func roomSurvivesTolerantSettingsDecoding() throws {
        var settings = AppSettings()
        settings.room.add(FurnitureCatalog.kind("bookshelf")!)
        settings.seasonal.birthdayMonth = 3
        settings.seasonal.birthdayDay = 14
        let data = try JSONEncoder().encode(settings)
        let decoded = AppSettings.decodeTolerantly(data)
        #expect(decoded.room == settings.room)
        #expect(decoded.seasonal == settings.seasonal)
    }
}
