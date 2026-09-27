import XCTest

@testable import LifeJustHappening

final class CameraPriorityTests: XCTestCase {
    private let builtIn = DiscoveredCamera(id: "builtin", name: "MacBook Pro Camera", kind: .builtIn)
    private let brio = DiscoveredCamera(id: "brio", name: "Logitech BRIO", kind: .external)
    private let lm1e = DiscoveredCamera(id: "lm1e", name: "PC-LM1E Camera", kind: .external)
    private let phone = DiscoveredCamera(id: "phone", name: "iPhone Camera", kind: .continuity)

    func testFirstRunSeedsExternalAboveBuiltIn() {
        let merged = CameraPriority.merge(known: [], discovered: [builtIn, lm1e])
        XCTAssertEqual(merged.map(\.id), ["lm1e", "builtin"])
    }

    func testNewCamerasAlwaysLandAtTheBottom() {
        let first = CameraPriority.merge(known: [], discovered: [builtIn])
        let merged = CameraPriority.merge(known: first, discovered: [builtIn, lm1e])
        XCTAssertEqual(merged.map(\.id), ["builtin", "lm1e"], "a new webcam doesn't jump the queue")
        let again = CameraPriority.merge(known: merged, discovered: [brio])
        XCTAssertEqual(again.map(\.id), ["builtin", "lm1e", "brio"])
        XCTAssertTrue(again.last!.isEnabled)
    }

    func testUserOrderIsPreservedAndDisconnectedCamerasAreRemembered() {
        let userOrder = [
            KnownCamera(id: "builtin", name: "Old name", kind: .builtIn, isEnabled: true),
            KnownCamera(id: "brio", name: "Logitech BRIO", kind: .external, isEnabled: true),
        ]
        let merged = CameraPriority.merge(known: userOrder, discovered: [builtIn])
        XCTAssertEqual(merged.map(\.id), ["builtin", "brio"])
        XCTAssertEqual(merged[0].name, "MacBook Pro Camera", "names refresh from the system")
    }

    func testContinuityCameraStartsDisabled() {
        let merged = CameraPriority.merge(known: [], discovered: [phone, builtIn])
        XCTAssertEqual(merged.first { $0.id == "phone" }?.isEnabled, false)
    }

    func testPluggedInWebcamWins() {
        let known = CameraPriority.merge(known: [], discovered: [builtIn, lm1e])
        let candidates = CameraPriority.candidates(known: known, connectedIDs: ["builtin", "lm1e"], isLidClosed: false)
        XCTAssertEqual(candidates.map(\.id), ["lm1e", "builtin"])
    }

    func testFallsBackToBuiltInWhenWebcamUnplugged() {
        let known = CameraPriority.merge(known: [], discovered: [builtIn, lm1e])
        let candidates = CameraPriority.candidates(known: known, connectedIDs: ["builtin"], isLidClosed: false)
        XCTAssertEqual(candidates.map(\.id), ["builtin"])
    }

    func testClamshellSkipsBuiltInEvenThoughMacOSStillListsIt() {
        let known = CameraPriority.merge(known: [], discovered: [builtIn, lm1e])
        let candidates = CameraPriority.candidates(known: known, connectedIDs: ["builtin", "lm1e"], isLidClosed: true)
        XCTAssertEqual(candidates.map(\.id), ["lm1e"])
        XCTAssertEqual(
            CameraPriority.unavailability(of: known[1], connectedIDs: ["builtin", "lm1e"], isLidClosed: true),
            .lidClosed
        )
    }

    func testNothingAvailableMeansSkip() {
        let known = CameraPriority.merge(known: [], discovered: [builtIn, lm1e])
        XCTAssertTrue(CameraPriority.candidates(known: known, connectedIDs: ["builtin"], isLidClosed: true).isEmpty)
        XCTAssertTrue(CameraPriority.candidates(known: known, connectedIDs: [], isLidClosed: false).isEmpty)
    }

    func testDisabledCamerasAreSkipped() {
        var known = CameraPriority.merge(known: [], discovered: [builtIn, lm1e])
        known[0].isEnabled = false
        let candidates = CameraPriority.candidates(known: known, connectedIDs: ["builtin", "lm1e"], isLidClosed: false)
        XCTAssertEqual(candidates.map(\.id), ["builtin"])
    }
}
