import CoreGraphics
import XCTest
@testable import IkkunointiCore

final class StateTests: XCTestCase {
    let main = Monitor(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 600),
                       visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 600))
    let side = Monitor(id: 2, frame: CGRect(x: 1000, y: 0, width: 800, height: 600),
                       visibleFrame: CGRect(x: 1000, y: 0, width: 800, height: 600))

    func makeState(_ monitors: [Monitor]? = nil) -> WMState {
        let s = WMState(gapsIn: 0, gapsOut: 0)
        s.setMonitors(monitors ?? [main])
        return s
    }

    func frame(_ s: WMState, _ id: WindowID) -> CGRect? {
        if case .frame(let r)? = s.placements()[id] { return r }
        return nil
    }

    func testMonitorsGetWorkspacesInOrder() {
        let s = makeState([side, main])
        XCTAssertEqual(s.activeWorkspace[1], 1)
        XCTAssertEqual(s.activeWorkspace[2], 2)
        XCTAssertEqual(s.focusedMonitor, 1)
    }

    func testNewWindowsTileIntoFocusedWorkspace() {
        let s = makeState()
        s.addWindow(10, pid: 1, floating: false)
        s.noteFocused(10)
        s.addWindow(11, pid: 1, floating: false)
        XCTAssertEqual(frame(s, 10), CGRect(x: 0, y: 0, width: 500, height: 600))
        XCTAssertEqual(frame(s, 11), CGRect(x: 500, y: 0, width: 500, height: 600))
    }

    func testSwitchWorkspaceHidesAndRestores() {
        let s = makeState()
        s.addWindow(10, pid: 1, floating: false)
        s.noteFocused(10)
        XCTAssertEqual(s.switchToWorkspace(2), .emptyMonitor(1))
        XCTAssertEqual(s.placements()[10], .hidden(1))
        XCTAssertNil(s.focusedWindow)
        s.addWindow(20, pid: 1, floating: false)
        XCTAssertEqual(s.windows[20]?.workspace, 2)
        XCTAssertEqual(frame(s, 20), main.visibleFrame)
        XCTAssertEqual(s.switchToWorkspace(1), .window(10))
        XCTAssertEqual(s.placements()[20], .hidden(1))
        XCTAssertEqual(frame(s, 10), main.visibleFrame)
        XCTAssertEqual(s.resolve(.previous), 2)
        XCTAssertNil(s.switchToWorkspace(1))   // already there, no back-and-forth
    }

    func testBackAndForth() {
        let s = makeState()
        s.workspaceBackAndForth = true
        _ = s.switchToWorkspace(3)
        XCTAssertEqual(s.switchToWorkspace(3), .emptyMonitor(1))
        XCTAssertEqual(s.focusedWorkspace, 1)
    }

    func testMoveToWorkspaceFollowAndSilent() {
        let s = makeState()
        s.addWindow(10, pid: 1, floating: false)
        s.noteFocused(10)
        s.addWindow(11, pid: 1, floating: false)
        s.noteFocused(11)
        XCTAssertEqual(s.moveWindow(11, toWorkspace: 3, follow: false), .window(10))
        XCTAssertEqual(s.focusedWindow, 10)
        XCTAssertEqual(s.placements()[11], .hidden(1))
        XCTAssertEqual(frame(s, 10), main.visibleFrame)

        XCTAssertEqual(s.moveWindow(10, toWorkspace: 3, follow: true), .window(10))
        XCTAssertEqual(s.focusedWorkspace, 3)
        XCTAssertEqual(s.focusedWindow, 10)
        XCTAssertNotNil(frame(s, 10))
        XCTAssertNotNil(frame(s, 11))
        XCTAssertTrue(s.workspace(1).isEmpty)
    }

    func testExistingRelativeCyclesNonEmptyWorkspaces() {
        let s = makeState()
        s.addWindow(10, pid: 1, floating: false, workspace: 2)
        s.addWindow(11, pid: 1, floating: false, workspace: 5)
        XCTAssertEqual(s.resolve(.existingRelative(1)), 2)
        _ = s.switchToWorkspace(5)
        XCTAssertEqual(s.resolve(.existingRelative(1)), 2)   // wraps (ws1 is empty and not current)
        XCTAssertEqual(s.resolve(.existingRelative(-1)), 2)
        XCTAssertEqual(s.resolve(.relative(-1)), 4)
    }

    func testRemoveFocusedSuggestsMostRecent() {
        let s = makeState()
        for id: WindowID in [10, 11, 12] {
            s.addWindow(id, pid: 1, floating: false)
        }
        s.noteFocused(10)
        s.noteFocused(12)
        s.noteFocused(11)
        XCTAssertEqual(s.removeWindow(11), .window(12))
        XCTAssertNil(s.removeWindow(10))       // not focused → no suggestion
    }

    func testDirectionalFocusAcrossMonitors() {
        let s = makeState([main, side])
        s.addWindow(10, pid: 1, floating: false, workspace: 1)
        s.addWindow(20, pid: 1, floating: false, workspace: 2)
        s.noteFocused(10)
        XCTAssertEqual(s.neighbor(of: 10, .right), .window(20))
        XCTAssertNil(s.neighbor(of: 10, .left))
        s.removeWindow(20)
        XCTAssertEqual(s.neighbor(of: 10, .right), .emptyMonitor(2))
    }

    func testSwapAcrossMonitorsMovesWorkspaces() {
        let s = makeState([main, side])
        s.addWindow(10, pid: 1, floating: false, workspace: 1)
        s.addWindow(20, pid: 1, floating: false, workspace: 2)
        s.noteFocused(10)
        XCTAssertTrue(s.swapInDirection(10, .right))
        XCTAssertEqual(s.windows[10]?.workspace, 2)
        XCTAssertEqual(s.windows[20]?.workspace, 1)
        XCTAssertEqual(frame(s, 10), side.visibleFrame)
        XCTAssertEqual(s.focusedMonitor, 2)
    }

    func testSwapIntoEmptyMonitorMovesWindow() {
        let s = makeState([main, side])
        s.addWindow(10, pid: 1, floating: false, workspace: 1)
        s.noteFocused(10)
        XCTAssertTrue(s.swapInDirection(10, .right))
        XCTAssertEqual(s.windows[10]?.workspace, 2)
        XCTAssertEqual(frame(s, 10), side.visibleFrame)
    }

    func testToggleFloatingAndFullscreen() {
        let s = makeState()
        s.addWindow(10, pid: 1, floating: false)
        s.noteFocused(10)
        s.addWindow(11, pid: 1, floating: false)
        s.toggleFloating(11, currentFrame: nil)
        XCTAssertEqual(frame(s, 10), main.visibleFrame)
        guard case .floating(let f)? = s.placements()[11], let ff = f else { return XCTFail("not floating") }
        XCTAssertEqual(ff.center, main.visibleFrame.center)

        s.toggleFloating(11, currentFrame: ff)
        XCTAssertEqual(frame(s, 11)?.width, 500)

        s.toggleFullscreen(10, mode: 0)
        XCTAssertEqual(frame(s, 10), main.visibleFrame)
        s.noteFocused(11)                        // focusing another tile leaves fullscreen
        XCTAssertEqual(frame(s, 10)?.width, 500)
    }

    func testExcludedWindowsKeepTheirSlot() {
        let s = makeState()
        s.addWindow(10, pid: 1, floating: false)
        s.noteFocused(10)
        s.addWindow(11, pid: 1, floating: false)
        s.noteFocused(11)
        XCTAssertEqual(s.setExcluded(11, true), .window(10))
        XCTAssertEqual(frame(s, 10), main.visibleFrame)
        XCTAssertEqual(s.placements()[11], .excluded)
        s.setExcluded(11, false)
        XCTAssertEqual(frame(s, 11), CGRect(x: 500, y: 0, width: 500, height: 600))
    }

    func testFloatingFrameFollowsAcrossMonitors() {
        let s = makeState([main, side])
        s.addWindow(10, pid: 1, floating: true, workspace: 1, frame: CGRect(x: 100, y: 100, width: 200, height: 100))
        s.noteFocused(10)
        s.moveWindow(10, toWorkspace: 2, follow: false)
        guard case .floating(let f)? = s.placements()[10], let ff = f else { return XCTFail("not floating") }
        XCTAssertTrue(side.frame.contains(ff))
    }

    func testMonitorUnplugKeepsWindowsHidden() {
        let s = makeState([main, side])
        s.addWindow(20, pid: 1, floating: false, workspace: 2)
        s.setMonitors([main])
        XCTAssertEqual(s.placements()[20], .hidden(1))
        s.setMonitors([main, side])
        XCTAssertEqual(s.activeWorkspace[2], 2)
        XCTAssertEqual(frame(s, 20), side.visibleFrame)
    }

    func testCycle() {
        let s = makeState()
        for id: WindowID in [10, 11, 12] { s.addWindow(id, pid: 1, floating: false) }
        s.noteFocused(12)
        XCTAssertEqual(s.cycle(previous: false), s.workspace(1).windowIDs.first)
    }
}
