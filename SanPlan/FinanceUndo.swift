import Foundation

extension FinanceStore {
    /// Saves the new state and offers «Отменить» for 5 seconds. Undo puts back the state from before,
    /// but only if nothing else changed the money in between, so a sync from another device is never thrown away.
    func replaceStateUndoable(with newState: FinanceState, today: String, message: String) throws {
        let before = state
        try replaceState(with: newState, today: today)
        let after = state
        guard after != before else { return }
        UndoCenter.shared.show(message) { [weak self] in
            guard let self, self.state == after else { return }
            try? self.replaceState(with: before, today: today)
        }
    }
}
