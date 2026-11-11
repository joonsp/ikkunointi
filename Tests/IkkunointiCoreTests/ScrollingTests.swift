import CoreGraphics
import XCTest
@testable import IkkunointiCore

final class ScrollStripTests: XCTestCase {
    let area = CGRect(x: 0, y: 0, width: 1000, height: 600)

    func testHalfColumnsFillTheScreenExactly() {
        let s = ScrollStrip()
        s.insert(1, after: nil)
        s.insert(2, after: 1)
        let f = s.layout(in: area, gapsIn: 5, focus: 2)
        XCTAssertEqual(f[1], CGRect(x: 0, y: 0, width: 495, height: 600))
        XCTAssertEqual(f[2], CGRect(x: 505, y: 0, width: 495, height: 600))
    }

    func testNewColumnGoesRightOfTargetAndViewScrolls() {
        let s = ScrollStrip()
        s.insert(1, after: nil)
        s.insert(2, after: 1)
        s.insert(3, after: 2)
        s.insert(4, after: 1)                                 // lands between 1 and 2
        XCTAssertEqual(s.windows, [1, 4, 2, 3])
        var f = s.layout(in: area, gapsIn: 0, focus: 3)
        XCTAssertEqual(f[3]?.maxX, 1000)                        // focused column fully visible at the right
        XCTAssertEqual(f[1]?.maxX, -500)                        // scrolled off to the left
        f = s.layout(in: area, gapsIn: 0, focus: 4)
        XCTAssertEqual(f[4]?.minX, 0)                           // scrolling back just far enough
        XCTAssertEqual(f[2]?.minX, 500)
    }

    func testOffsetClampsWhenColumnsDisappear() {
        let s = ScrollStrip()
        for i: WindowID in 1...4 { s.insert(i, after: i == 1 ? nil : i - 1) }
        _ = s.layout(in: area, gapsIn: 0, focus: 4)
        s.remove(3)
        s.remove(4)
        let f = s.layout(in: area, gapsIn: 0, focus: nil)
        XCTAssertEqual(f[1]?.minX, 0)
        XCTAssertEqual(f[2]?.maxX, 1000)
    }

    func testWidthAndNeighbors() {
        let s = ScrollStrip()
        for i: WindowID in 1...3 { s.insert(i, after: i == 1 ? nil : i - 1) }
        s.resize(2, by: 0.25)
        XCTAssertEqual(s.layout(in: area, gapsIn: 0, focus: 2)[2]?.width, 750)
        s.resize(2, by: 5)
        XCTAssertEqual(s.width(of: 2), 1.0)
        XCTAssertEqual(s.neighbor(of: 1, step: 1), 2)
        XCTAssertEqual(s.neighbor(of: 1, step: 1, include: { $0 != 2 }), 3)
        XCTAssertNil(s.neighbor(of: 1, step: -1))
    }
}

final class ScrollingStateTests: XCTestCase {
    let main = Monitor(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 600),
                       visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 600))

    func makeScrolling() -> WMState {
        let s = WMState(gapsIn: 0, gapsOut: 0)
        s.defaultLayout = .scrolling
        s.setMonitors([main])
        return s
    }

    func open(_ s: WMState, _ id: WindowID) {
        s.addWindow(id, pid: 1, floating: false)
        s.noteFocused(id)
    }

    func testThirdWindowPushesFirstOffScreen() {
        let s = makeScrolling()
        open(s, 1); open(s, 2)
        XCTAssertEqual(s.placements()[1], .frame(CGRect(x: 0, y: 0, width: 500, height: 600)))
        open(s, 3)
        XCTAssertEqual(s.placements()[1], .hidden(1))             // fully scrolled away → parked
        XCTAssertEqual(s.placements()[3], .frame(CGRect(x: 500, y: 0, width: 500, height: 600)))
    }

    func testFocusWalksColumnsIncludingHiddenOnes() {
        let s = makeScrolling()
        open(s, 1); open(s, 2); open(s, 3)
        XCTAssertEqual(s.neighbor(of: 3, .left), .window(2))
        s.noteFocused(2)
        XCTAssertEqual(s.neighbor(of: 2, .left), .window(1))      // 1 is parked but still reachable
        s.noteFocused(1)
        XCTAssertEqual(s.placements()[1], .frame(CGRect(x: 0, y: 0, width: 500, height: 600)))
        XCTAssertEqual(s.placements()[3], .hidden(1))
        XCTAssertNil(s.neighbor(of: 1, .left))
    }

    func testSwapMovesColumnsAndResizeChangesWidth() {
        let s = makeScrolling()
        open(s, 1); open(s, 2)
        XCTAssertTrue(s.swapInDirection(2, .left))
        XCTAssertEqual(s.workspace(1).strip.windows, [2, 1])
        s.resizeTiled(2, dx: 250, dy: 999)
        guard case .frame(let f)? = s.placements()[2] else { return XCTFail() }
        XCTAssertEqual(f.width, 750)
        XCTAssertEqual(f.height, 600)
    }

    func testToggleLayoutPerWorkspaceKeepsWindows() {
        let s = WMState(gapsIn: 0, gapsOut: 0)
        s.setMonitors([main])
        open(s, 1); open(s, 2); open(s, 3)
        XCTAssertEqual(s.layout(of: s.workspace(1)), .dwindle)
        s.toggleLayout(1)
        XCTAssertEqual(s.layout(of: s.workspace(1)), .scrolling)
        XCTAssertEqual(s.layout(of: s.workspace(2)), .dwindle)
        XCTAssertEqual(Set(s.workspace(1).strip.windows), [1, 2, 3])
        s.toggleLayout(1)
        guard case .frame(let f)? = s.placements()[1] else { return XCTFail() }
        XCTAssertEqual(f.width, 500)                               // back to the dwindle tile
    }

    func testToggleSplitIsIgnoredWhileScrolling() {
        let s = WMState(gapsIn: 0, gapsOut: 0)
        s.setMonitors([main])
        open(s, 1); open(s, 2)
        let before = s.placements()
        s.toggleLayout(1)
        s.toggleSplit(2)
        s.toggleLayout(1)
        XCTAssertEqual(s.placements(), before)
    }

    func testRemovingAndMovingKeepStripInSync() {
        let s = makeScrolling()
        open(s, 1); open(s, 2); open(s, 3)
        s.removeWindow(2)
        XCTAssertEqual(s.workspace(1).strip.windows, [1, 3])
        s.moveWindow(3, toWorkspace: 2, follow: false)
        XCTAssertEqual(s.workspace(1).strip.windows, [1])
        XCTAssertEqual(s.workspace(2).strip.windows, [3])
        s.toggleFloating(1, currentFrame: nil)
        XCTAssertTrue(s.workspace(1).strip.windows.isEmpty)
    }

    func testHoverFocusDoesNotScroll() {
        let s = makeScrolling()
        open(s, 1); open(s, 2)
        s.resizeTiled(2, dx: 250, dy: 0)          // 1 is now only partly visible on the left
        guard case .frame(let before)? = s.placements()[1] else { return XCTFail() }
        XCTAssertLessThan(before.minX, 0)
        s.noteFocused(1, scroll: false)            // hovered
        XCTAssertEqual(s.placements()[1], .frame(before))
        s.noteFocused(1)                           // clicked / keyboard
        guard case .frame(let after)? = s.placements()[1] else { return XCTFail() }
        XCTAssertEqual(after.minX, 0)
    }

    func testCursorOptions() {
        XCTAssertTrue(Config().followMouse)
        XCTAssertTrue(Config().warpCursor)
        let c = Config.parse("input:follow_mouse = 0\ncursor { \nno_warps = true\n}")
        XCTAssertEqual(c.errors, [])
        XCTAssertFalse(c.followMouse)
        XCTAssertFalse(c.warpCursor)
    }

    func testConfigLayoutOptions() {
        let c = Config.parse("general:layout = scrolling\nscrolling:column_width = 0.66\nbind = SUPER, L, togglelayout")
        XCTAssertEqual(c.errors, [])
        XCTAssertEqual(c.layout, .scrolling)
        XCTAssertEqual(c.columnWidth, 0.66)
        XCTAssertEqual(c.keyBindings.first?.action, .toggleLayout)
    }
}
