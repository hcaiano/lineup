import XCTest
@testable import lineup
import HintsCore

/// Deterministic registry semantics (Gate 3 evidence A). No AX and no threading: the
/// registry holds no element values and its marks are synchronous.
final class HintAXCancellationRegistryTests: XCTestCase {

    func testExactGenerationReleaseAdvancesOnlyOnExactKey() {
        let registry = HintAXCancellationRegistry()
        let key0 = HintSessionKey(id: 7, generation: 0)
        let key1 = key0.nextGeneration

        XCTAssertTrue(registry.bindActiveKey(key0))
        // Conflicting binding (different generation, same owner id) is refused; the
        // first exact binding stays authoritative.
        XCTAssertFalse(registry.bindActiveKey(key1))
        XCTAssertEqual(registry.activeKey(for: 7), Optional(key0))
        // Idempotent retry of the SAME exact key is allowed.
        XCTAssertTrue(registry.bindActiveKey(key0))
        XCTAssertEqual(registry.activeKey(for: 7), Optional(key0))

        // Exact-key release: the only path that marks cancellation AND advances.
        XCTAssertEqual(registry.authorizeGenerationRelease(key0), Optional(key1))
        XCTAssertEqual(registry.activeKey(for: 7), Optional(key1))
        XCTAssertTrue(registry.isCancelled(key0))
        XCTAssertFalse(registry.isCancelled(key1), "the advanced key must stay live")
    }

    func testStaleGenerationReleaseNeitherCancelsNorAdvances() {
        let registry = HintAXCancellationRegistry()
        let key0 = HintSessionKey(id: 7, generation: 0)
        let key1 = key0.nextGeneration
        XCTAssertTrue(registry.bindActiveKey(key0))
        _ = registry.authorizeGenerationRelease(key0) // advance to key1

        // Stale exact key: no mark, no advance, no poison of the live key.
        XCTAssertNil(registry.authorizeGenerationRelease(key0))
        XCTAssertFalse(registry.isCancelled(key1))
        XCTAssertEqual(registry.activeKey(for: 7), Optional(key1))

        // Future generation: never cancelled or marked.
        let future = HintSessionKey(id: 7, generation: 9)
        XCTAssertNil(registry.authorizeGenerationRelease(future))
        XCTAssertFalse(registry.isCancelled(future))
        XCTAssertEqual(registry.activeKey(for: 7), Optional(key1))

        // Foreign owner id: nothing marked on the foreign session either.
        let foreign = HintSessionKey(id: 8, generation: 0)
        XCTAssertNil(registry.authorizeGenerationRelease(foreign))
        XCTAssertFalse(registry.isSessionCancelled(id: 8))
        XCTAssertFalse(registry.isCancelled(foreign))
        XCTAssertEqual(registry.activeKey(for: 7), Optional(key1))
    }

    func testSessionReleaseExactVersusStale() {
        let registry = HintAXCancellationRegistry()
        let key0 = HintSessionKey(id: 7, generation: 0)
        XCTAssertTrue(registry.bindActiveKey(key0))

        // Stale session release (not the exact active key): nothing is cancelled or
        // removed; the active owner binding survives untouched.
        let stale = key0.nextGeneration
        XCTAssertFalse(registry.authorizeSessionRelease(stale))
        XCTAssertEqual(registry.activeKey(for: 7), Optional(key0))
        XCTAssertFalse(registry.isSessionCancelled(id: 7))

        // Exact session release: marks the owner id cancelled and removes the binding.
        XCTAssertTrue(registry.authorizeSessionRelease(key0))
        XCTAssertNil(registry.activeKey(for: 7))
        XCTAssertTrue(registry.isSessionCancelled(id: 7))
        XCTAssertTrue(registry.isCancelled(key0))
        // Every later authorization is refused (the binding is gone).
        XCTAssertNil(registry.authorizeGenerationRelease(key0))
        XCTAssertFalse(registry.authorizeSessionRelease(key0))
    }

    func testStoppedOrCancelledRegistryRejectsBindings() {
        let registry = HintAXCancellationRegistry()
        let key = HintSessionKey(id: 7, generation: 0)

        registry.markStopped()
        XCTAssertFalse(registry.bindActiveKey(key), "a stopped registry never binds")
        XCTAssertNil(registry.activeKey(for: 7))
        XCTAssertNil(registry.authorizeGenerationRelease(key))
        XCTAssertFalse(registry.authorizeSessionRelease(key))
    }

    func testCancelledOwnerOrGenerationRefusesBinding() {
        let registry = HintAXCancellationRegistry()
        let key = HintSessionKey(id: 7, generation: 0)
        let other = HintSessionKey(id: 9, generation: 0)

        // Cancelled session owner id refuses binding.
        registry.markSessionCancelled(id: key.id)
        XCTAssertFalse(registry.bindActiveKey(key))

        // Cancelled exact generation refuses binding for that key.
        registry.markGenerationCancelled(other)
        XCTAssertFalse(registry.bindActiveKey(other))

        // Binding other ids is unaffected.
        let live = HintSessionKey(id: 11, generation: 0)
        XCTAssertTrue(registry.bindActiveKey(live))
        XCTAssertEqual(registry.activeKey(for: 11), Optional(live))
    }
}
