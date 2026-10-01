import AppKit
import SwiftUI
import XCTest
@testable import SaysoFace

/// The window never grows to its content (FloatingPanel), so content taller
/// than its shape is cut off on screen: square corners, a missing border.
/// Every snapshot state must fit.
@MainActor
final class FitTests: XCTestCase {
    func testEveryStateFitsItsWindow() {
        UserDefaults.standard.set(true, forKey: Model.noticeKey)
        var overflowing: [String] = []
        for (name, setup) in Snapshot.states() {
            let m = Model()
            Snapshot.base(m)
            setup(m)
            m.recompute()
            let size = m.shape.size
            let host = NSHostingView(rootView: ShapeContent().environmentObject(m).frame(width: size.width))
            let needed = host.fittingSize.height
            if needed > size.height + 0.5 {
                overflowing.append("\(name): needs \(Int(needed.rounded(.up))) pt, has \(Int(size.height))")
            }
        }
        XCTAssertTrue(overflowing.isEmpty, overflowing.joined(separator: "\n"))
    }
}
