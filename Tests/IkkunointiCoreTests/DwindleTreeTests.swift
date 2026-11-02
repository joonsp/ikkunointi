import CoreGraphics
import XCTest
@testable import IkkunointiCore

final class DwindleTreeTests: XCTestCase {
    let area = CGRect(x: 0, y: 0, width: 1000, height: 600)

    func testSingleWindowFillsArea() {
        let t = DwindleTree()
        t.insert(1, splitting: nil, fallbackArea: area)
        XCTAssertEqual(t.layout(in: area, gapsIn: 5)[1], area)
    }

    func testDwindleSplitsAlongLongerSide() {
        let t = DwindleTree()
        t.insert(1, splitting: nil, fallbackArea: area)
        _ = t.layout(in: area, gapsIn: 0)
        t.insert(2, splitting: 1, fallbackArea: area)       // wide area: side by side
        var f = t.layout(in: area, gapsIn: 0)
        XCTAssertEqual(f[1], CGRect(x: 0, y: 0, width: 500, height: 600))
        XCTAssertEqual(f[2], CGRect(x: 500, y: 0, width: 500, height: 600))

        t.insert(3, splitting: 2, fallbackArea: area)       // 500x600 tile is tall: stacked
        f = t.layout(in: area, gapsIn: 0)
        XCTAssertEqual(f[2], CGRect(x: 500, y: 0, width: 500, height: 300))
        XCTAssertEqual(f[3], CGRect(x: 500, y: 300, width: 500, height: 300))
        XCTAssertEqual(t.windows, [1, 2, 3])
    }

    func testInnerGapsOnlyBetweenWindows() {
        let t = DwindleTree()
        t.insert(1, splitting: nil, fallbackArea: area)
        _ = t.layout(in: area, gapsIn: 5)
        t.insert(2, splitting: 1, fallbackArea: area)
        let f = t.layout(in: area, gapsIn: 5)
        XCTAssertEqual(f[1], CGRect(x: 0, y: 0, width: 495, height: 600))
        XCTAssertEqual(f[2], CGRect(x: 505, y: 0, width: 495, height: 600))
    }

    func testRemoveGivesSpaceToSibling() {
        let t = DwindleTree()
        for i in 1...3 {
            _ = t.layout(in: area, gapsIn: 0)
            t.insert(WindowID(i), splitting: i == 1 ? nil : WindowID(i - 1), fallbackArea: area)
        }
        t.remove(2)
        let f = t.layout(in: area, gapsIn: 0)
        XCTAssertEqual(f[1], CGRect(x: 0, y: 0, width: 500, height: 600))
        XCTAssertEqual(f[3], CGRect(x: 500, y: 0, width: 500, height: 600))
        t.remove(1)
        t.remove(3)
        XCTAssertTrue(t.isEmpty)
        XCTAssertNil(t.root)
    }

    func testExcludedWindowsCollapse() {
        let t = DwindleTree()
        t.insert(1, splitting: nil, fallbackArea: area)
        _ = t.layout(in: area, gapsIn: 0)
        t.insert(2, splitting: 1, fallbackArea: area)
        let f = t.layout(in: area, gapsIn: 0, include: { $0 != 2 })
        XCTAssertEqual(f[1], area)
        XCTAssertNil(f[2])
    }

    func testToggleSplitAndSwap() {
        let t = DwindleTree()
        t.insert(1, splitting: nil, fallbackArea: area)
        _ = t.layout(in: area, gapsIn: 0)
        t.insert(2, splitting: 1, fallbackArea: area)
        t.toggleSplit(2)
        var f = t.layout(in: area, gapsIn: 0)
        XCTAssertEqual(f[1], CGRect(x: 0, y: 0, width: 1000, height: 300))
        t.swap(1, 2)
        f = t.layout(in: area, gapsIn: 0)
        XCTAssertEqual(f[2], CGRect(x: 0, y: 0, width: 1000, height: 300))
        XCTAssertEqual(f[1], CGRect(x: 0, y: 300, width: 1000, height: 300))
    }

    func testResizeMovesNearestDivider() {
        let t = DwindleTree()
        t.insert(1, splitting: nil, fallbackArea: area)
        _ = t.layout(in: area, gapsIn: 0)
        t.insert(2, splitting: 1, fallbackArea: area)
        _ = t.layout(in: area, gapsIn: 0)
        t.resize(1, dx: 100, dy: 0)                 // left window grows to the right
        var f = t.layout(in: area, gapsIn: 0)
        XCTAssertEqual(f[1]?.width, 600)
        t.resize(2, dx: 100, dy: 0)                 // right window grows to the left
        f = t.layout(in: area, gapsIn: 0)
        XCTAssertEqual(f[2]?.width, 500)
        XCTAssertEqual(f[2]?.minX, 500)
        t.resize(1, dx: 0, dy: 50)                  // no vertical split: no-op
        XCTAssertEqual(t.layout(in: area, gapsIn: 0)[1]?.height, 600)
    }

    func testMoveEdge() {
        let t = DwindleTree()
        t.insert(1, splitting: nil, fallbackArea: area)
        _ = t.layout(in: area, gapsIn: 0)
        t.insert(2, splitting: 1, fallbackArea: area)
        _ = t.layout(in: area, gapsIn: 0)
        XCTAssertTrue(t.moveEdge(of: 1, edge: .right, to: 300))
        XCTAssertFalse(t.moveEdge(of: 1, edge: .left, to: 100))   // monitor edge
        let f = t.layout(in: area, gapsIn: 0)
        XCTAssertEqual(f[1]?.width, 300)
        XCTAssertEqual(f[2]?.minX, 300)
    }

    func testRatioClamped() {
        let t = DwindleTree()
        t.insert(1, splitting: nil, fallbackArea: area)
        _ = t.layout(in: area, gapsIn: 0)
        t.insert(2, splitting: 1, fallbackArea: area)
        _ = t.layout(in: area, gapsIn: 0)
        t.resize(1, dx: 5000, dy: 0)
        XCTAssertEqual(t.layout(in: area, gapsIn: 0)[1]?.width, 900)
    }
}

final class DirectionTests: XCTestCase {
    func testPrefersOverlappingThenRecency() {
        // A | B
        //   | C
        let a = CGRect(x: 0, y: 0, width: 500, height: 600)
        let b = CGRect(x: 510, y: 0, width: 490, height: 295)
        let c = CGRect(x: 510, y: 305, width: 490, height: 295)
        let cands: [(id: WindowID, rect: CGRect)] = [(1, a), (2, b), (3, c)]
        XCTAssertEqual(findInDirection(from: c, direction: .left, candidates: cands), 1)
        XCTAssertEqual(findInDirection(from: c, direction: .up, candidates: cands), 2)
        XCTAssertNil(findInDirection(from: c, direction: .down, candidates: cands))
        XCTAssertEqual(findInDirection(from: a, direction: .right, candidates: cands, recency: [3: 0, 2: 1]), 3)
        XCTAssertEqual(findInDirection(from: a, direction: .right, candidates: cands, recency: [2: 0, 3: 1]), 2)
    }

    func testDirectionParsing() {
        XCTAssertEqual(Direction(hypr: "l"), .left)
        XCTAssertEqual(Direction(hypr: "Down"), .down)
        XCTAssertEqual(Direction(hypr: "t"), .up)
        XCTAssertNil(Direction(hypr: "x"))
    }
}
