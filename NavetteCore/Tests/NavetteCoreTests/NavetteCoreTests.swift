import XCTest
@testable import NavetteCore

final class NavetteCoreTests: XCTestCase {
    func testModuleLinks() {
        XCTAssertEqual(String(describing: NavetteCore.self), "NavetteCore")
    }
}
