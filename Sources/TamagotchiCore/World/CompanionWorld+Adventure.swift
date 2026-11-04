import Foundation

extension CompanionWorld {
    /// Mochi left the menu bar to explore (true) or is back home (false).
    public func setAdventureActive(_ active: Bool) {
        setAdventureActive(active, returningAt: nil)
    }

    /// Mochi leaves the menu bar to explore (hopping down out of it, or `instantly` when the pointer
    /// lifts it off), or is back: it pops up through the bar at `x` (the roaming zone's own points;
    /// where it left when nil) and carries on from there. The bed stays empty meanwhile.
    public func setAdventureActive(_ active: Bool, returningAt x: Double? = nil, instantly: Bool = false) {
        guard adventureActive != active else { return }
        adventureActive = active
        if roamer.isActive {
            var copy = roamer
            if active {
                copy.leaveForAdventure(now: now, context: roamContext, instantly: instantly)
            } else {
                copy.returnFromAdventure(at: x, now: now, context: roamContext)
            }
            if copy != roamer { roamer = copy }
        }
        syncRoamer()
    }
}
