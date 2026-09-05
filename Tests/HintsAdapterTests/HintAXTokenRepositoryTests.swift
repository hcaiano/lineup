import ApplicationServices
import XCTest
@testable import lineup
import HintsCore

/// Deterministic repository semantics (Gate 3 evidence B). Inert AXUIElement identities
/// only (see HintsStubSeams): entries are keyed by FULL `HintSessionKey`, and no release
/// path may reach across to another live full key.
final class HintAXTokenRepositoryTests: XCTestCase {

    private let factory = SequentialTokenFactory()

    /// Deterministic inert-element identity space, unique per test instance (XCTest
    /// creates a fresh instance per test method, so counters never collide in-process;
    /// the StubAXBackend mint space starts at 1_000_001 and never overlaps this one).
    private var nextInertPid: Int32 = 1_500_001

    /// Mints a fresh inert element identity from a strictly increasing pid (no real AX
    /// query/mutation ever uses it).
    private func inertElement() -> AXUIElement {
        defer { nextInertPid += 1 }
        return AXUIElementCreateApplication(nextInertPid)
    }

    private func insert(_ repository: HintAXTokenRepository, key: HintSessionKey) -> HintTargetToken {
        repository.insert(
            element: inertElement(), key: key,
            rootID: HintAXRootID(factory.mint()), ancestorTokens: [], factory: factory
        )
    }

    func testFullKeyIsolation() {
        let repository = HintAXTokenRepository()
        let key0 = HintSessionKey(id: 7, generation: 0)
        let key1 = key0.nextGeneration
        let foreign = HintSessionKey(id: 8, generation: 0)

        let token0 = insert(repository, key: key0)
        let token1 = insert(repository, key: key1)
        _ = insert(repository, key: foreign)

        // A token resolves ONLY under its own exact FULL key: never under another
        // generation of the same session, never across sessions.
        XCTAssertNotNil(repository.element(for: token0, in: key0))
        XCTAssertNil(repository.element(for: token0, in: key1), "generation must not leak upward")
        XCTAssertNil(repository.element(for: token0, in: foreign))
        XCTAssertNotNil(repository.element(for: token1, in: key1))
        XCTAssertNil(repository.element(for: token1, in: key0))
        // Unknown tokens resolve nowhere.
        XCTAssertNil(repository.element(for: HintTargetToken("missing"), in: key1))

        XCTAssertEqual(repository.tokens(in: key0).count, 1)
        XCTAssertEqual(repository.tokens(in: key1).count, 1)
        XCTAssertEqual(repository.tokens(in: foreign).count, 1)
        XCTAssertTrue(repository.hasGeneration(key1))
        XCTAssertFalse(repository.hasGeneration(HintSessionKey(id: 7, generation: 5)))
    }

    func testProvenanceIsFullKeyBound() {
        let repository = HintAXTokenRepository()
        let key0 = HintSessionKey(id: 3, generation: 0)
        let token = repository.insert(
            element: inertElement(), key: key0,
            rootID: HintAXRootID(factory.mint()),
            ancestorTokens: [HintTargetToken(factory.mint())], factory: factory
        )
        guard let provenance = repository.provenance(for: token, in: key0) else {
            return XCTFail("provenance must resolve under the minting key")
        }
        XCTAssertEqual(provenance.ancestors.count, 1)
        XCTAssertNil(repository.provenance(for: token, in: key0.nextGeneration))
    }

    func testRetainPrunesOnlyTheExactKeyAndKeepsOtherLiveKeys() {
        let repository = HintAXTokenRepository()
        let key0 = HintSessionKey(id: 7, generation: 0)
        let key1 = key0.nextGeneration

        let first0 = insert(repository, key: key0)
        _ = insert(repository, key: key0)
        _ = insert(repository, key: key0)
        let first1 = insert(repository, key: key1)

        // Keep only one token of key0: the other two prune; key1 is untouched.
        let released = repository.retain(tokens: [first0.raw], fullKey: key0)
        XCTAssertEqual(released, 2)
        XCTAssertNotNil(repository.element(for: first0, in: key0))
        XCTAssertNotNil(repository.element(for: first1, in: key1))
        XCTAssertEqual(repository.tokens(in: key0).count, 1)
        XCTAssertEqual(repository.tokens(in: key1).count, 1)
        XCTAssertEqual(repository.count, 2)

        // Retaining with an empty set prunes every entry of the exact key only.
        let allPruned = repository.retain(tokens: [], fullKey: key0)
        XCTAssertEqual(allPruned, 1)
        XCTAssertEqual(repository.tokens(in: key0).count, 0)
        XCTAssertNotNil(repository.element(for: first1, in: key1))
    }

    func testStaleKeyCleanupDoesNotAffectAnotherLiveFullKey() {
        let repository = HintAXTokenRepository()
        let key0 = HintSessionKey(id: 7, generation: 0)
        let key1 = key0.nextGeneration
        let key2 = key1.nextGeneration

        let token0 = insert(repository, key: key0)
        let token1 = insert(repository, key: key1)
        let token2 = insert(repository, key: key2)

        // Stale-generation cleanup (simulating the service's stale release path): removes
        // exactly key0's records; both live full keys survive.
        XCTAssertEqual(repository.release(fullKey: key0), 1)
        XCTAssertNil(repository.element(for: token0, in: key0))
        XCTAssertNotNil(repository.element(for: token1, in: key1))
        XCTAssertNotNil(repository.element(for: token2, in: key2))
        XCTAssertFalse(repository.hasGeneration(key0))
        XCTAssertTrue(repository.hasGeneration(key1))

        // Session-scoped release removes ALL generations of the owner id and nothing else.
        XCTAssertEqual(repository.release(sessionId: 7), 2)
        XCTAssertNil(repository.element(for: token1, in: key1))
        XCTAssertNil(repository.element(for: token2, in: key2))

        let foreignToken = insert(repository, key: HintSessionKey(id: 8, generation: 0))
        XCTAssertEqual(repository.release(sessionId: 7), 0, "idempotent")
        XCTAssertNotNil(repository.element(for: foreignToken, in: HintSessionKey(id: 8, generation: 0)))
    }

    func testResetDropsEverything() {
        let repository = HintAXTokenRepository()
        _ = insert(repository, key: HintSessionKey(id: 7, generation: 0))
        _ = insert(repository, key: HintSessionKey(id: 8, generation: 0))
        repository.reset()
        XCTAssertEqual(repository.count, 0)
        XCTAssertEqual(repository.tokens(in: HintSessionKey(id: 7, generation: 0)).count, 0)
    }
}
