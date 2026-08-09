import Foundation

// Merged runner: Lineup 2.0's suite is the union of the 1.x Lineup suite and the standalone
// Cycler suite, with the hyper-key checks split into their own file. No check was dropped in
// the merge — the total below must stay >= the sum of the two original runners.
//
// Run: `swift run lineup-tests`

func runSuite(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
    } catch {
        check(false, "\(name): unexpected throw: \(error)")
    }
}

runSuite("ZonesSuite", runZonesTests)
runSuite("CyclerSuite", runCyclerTests)
runSuite("HyperkeySuite", runHyperkeyTests)

// ---- Report ----
if failures == 0 {
    print("ok — \(checks) checks passed")
    exit(0)
} else {
    FileHandle.standardError.write(Data("\(failures)/\(checks) checks FAILED\n".utf8))
    exit(1)
}
