import XCTest
@testable import LibGM

final class LibGMTests: XCTestCase {
    func testGaiaDeviceSwitcherRoundTrip() async {
        let client = await GMClient()

        await client.setGaiaDeviceSwitcher(7)
        let value = await client.getGaiaDeviceSwitcher()

        XCTAssertEqual(value, 7)
    }

    func testConnectBackgroundRequiresLogin() async {
        let client = await GMClient()

        do {
            try await client.connectBackground()
            XCTFail("Expected connectBackground to throw when not logged in")
        } catch let error as GMClientError {
            XCTAssertEqual(error, .notLoggedIn)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}
