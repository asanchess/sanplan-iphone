import Foundation

/// A synced collection the live-sync driver can nudge (docs/ONE-APP-PLAN.md, «Sync contract» → Live sync).
@MainActor
public protocol VaultSyncable: AnyObject {
    /// The server's name of the collection, also its key in `GET /api/vault/stamps`.
    var syncName: String { get }
    /// Highest `seq` received so far.
    var syncCursor: Int { get }
    func syncNow()
    func advanceCursor(to stamp: Int)
}

extension VaultCollection: VaultSyncable {
    public var syncName: String { collection }
}

extension NotesStore: VaultSyncable {
    public var syncName: String { Self.collection }
}

/// Polls `GET /api/vault/stamps` every few seconds while the app is in the foreground. A collection whose counter is
/// ahead of what it has received syncs (`?since=<highest seq>`); when `plans` moves, plans are fetched again.
@MainActor
public final class VaultLiveSync {
    public var interval: Duration = .seconds(3.5)
    /// A counter that stays ahead of every received record this long belongs to a write that lost its conflict.
    public var staleAfter: TimeInterval = 10

    private var targets: [String: any VaultSyncable] = [:]
    private var behindSince: [String: Date] = [:]
    private var lastPlans: Int?
    private var task: Task<Void, Never>?
    private let stamps: () async throws -> [String: Int]
    private let canPoll: @MainActor () -> Bool
    private let onPlansMoved: @MainActor () -> Void
    private let now: () -> Date

    public init(stamps: @escaping () async throws -> [String: Int],
                canPoll: @escaping @MainActor () -> Bool,
                onPlansMoved: @escaping @MainActor () -> Void,
                now: @escaping () -> Date = { Date() }) {
        self.stamps = stamps
        self.canPoll = canPoll
        self.onPlansMoved = onPlansMoved
        self.now = now
    }

    public func register(_ target: any VaultSyncable) {
        targets[target.syncName] = target
    }

    /// Starts polling (idempotent); the first poll runs at once.
    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                let wait = self?.interval ?? .seconds(4)
                try? await Task.sleep(for: wait)
            }
        }
    }

    /// The app left the foreground. Counters are compared again on the next start.
    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Signed out: forget what was seen, so the next account starts from a clean baseline.
    public func reset() {
        stop()
        behindSince = [:]
        lastPlans = nil
    }

    public var isRunning: Bool { task != nil }

    public func pollOnce() async {
        guard canPoll() else { return }
        guard let latest = try? await stamps() else { return }
        evaluate(latest)
    }

    /// Compares one answer of `/api/vault/stamps` with what each collection has received.
    func evaluate(_ latest: [String: Int]) {
        if let plans = latest["plans"] {
            if let last = lastPlans, plans > last { onPlansMoved() }
            lastPlans = plans
        }
        for (name, target) in targets {
            guard let stamp = latest[name] else { continue }
            guard stamp > target.syncCursor else { behindSince[name] = nil; continue }
            let since = behindSince[name] ?? now()
            behindSince[name] = since
            if now().timeIntervalSince(since) > staleAfter {
                target.advanceCursor(to: stamp)
                behindSince[name] = nil
            } else {
                target.syncNow()
            }
        }
    }
}
