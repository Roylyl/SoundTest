import XCTest

final class SoundTestUITests: XCTestCase {
    @MainActor func testNativeTabsAndOfflineModelSwitches() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["record"].waitForExistence(timeout: 45))
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.buttons["测试"].exists)
        XCTAssertTrue(tabs.buttons["日志及模型信息"].exists)
        XCTAssertTrue(tabs.buttons["设置"].exists)
        for id in ["cedTiny", "cedMini", "yamnet", "zipformer"] {
            let ready = NSPredicate(format: "enabled == true")
            expectation(for: ready, evaluatedWith: app.buttons["modelSelector"])
            waitForExpectations(timeout: 60)
            app.buttons["modelSelector"].tap()
            XCTAssertTrue(app.buttons["model.\(id)"].waitForExistence(timeout: 5))
            app.buttons["model.\(id)"].tap()
        }
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["record"])
        waitForExpectations(timeout: 60)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "SoundTest-home"; attachment.lifetime = .keepAlways; add(attachment)
        tabs.buttons["日志及模型信息"].tap()
        XCTAssertTrue(app.navigationBars["日志及模型信息"].waitForExistence(timeout: 5))
        tabs.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        let settings = XCTAttachment(screenshot: app.screenshot()); settings.name = "SoundTest-settings"; settings.lifetime = .keepAlways; add(settings)
    }
}
