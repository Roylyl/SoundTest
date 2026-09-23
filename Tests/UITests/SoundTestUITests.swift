import XCTest
import UIKit

final class SoundTestUITests: XCTestCase {
    @MainActor func testWatchLogsEntryOpensSeparateHistory() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["record"].waitForExistence(timeout: 45))
        app.tabBars.buttons["日志及模型信息"].tap()
        let entry = app.descendants(matching: .any).matching(identifier: "watchLogs").firstMatch
        for _ in 0..<12 where !entry.isHittable { app.swipeUp() }
        XCTAssertTrue(entry.isHittable, app.debugDescription)
        entry.tap()
        XCTAssertTrue(app.navigationBars["Apple Watch 日志"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "SoundTest-Apple-Watch-logs"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor func testCompactWidthKeepsActionsWithinScreen() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        guard app.frame.width < 900 else { throw XCTSkip("Only applies to compact-width devices") }
        let record = app.buttons["record"]
        XCTAssertTrue(record.waitForExistence(timeout: 45))
        XCTAssertTrue(app.buttons["modelSelector"].exists)
        XCTAssertTrue(app.buttons["importBatch"].exists)
        XCTAssertLessThanOrEqual(record.frame.maxX, app.frame.maxX)
        XCTAssertLessThanOrEqual(app.buttons["importBatch"].frame.maxX, app.frame.maxX)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "testResultsColumn").firstMatch.exists)
    }

    @MainActor func testIPadTestPageUsesSideBySideColumns() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launch()
        guard UIDevice.current.userInterfaceIdiom == .pad && app.frame.width >= 900 else {
            throw XCTSkip("Requires a wide iPad layout")
        }
        XCTAssertTrue(app.buttons["record"].waitForExistence(timeout: 45))
        let controls = app.descendants(matching: .any).matching(identifier: "testControlsColumn").firstMatch
        let results = app.descendants(matching: .any).matching(identifier: "testResultsColumn").firstMatch
        XCTAssertTrue(controls.waitForExistence(timeout: 5))
        XCTAssertTrue(results.waitForExistence(timeout: 5))
        XCTAssertLessThan(controls.frame.maxX, results.frame.minX)
        XCTAssertTrue(app.staticTexts["识别结果"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "SoundTest-iPad-landscape"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "日志及模型信息")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["日志及模型信息"].waitForExistence(timeout: 5))
        let history = XCTAttachment(screenshot: app.screenshot())
        history.name = "SoundTest-iPad-history"
        history.lifetime = .keepAlways
        add(history)
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "设置")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        let settings = XCTAttachment(screenshot: app.screenshot())
        settings.name = "SoundTest-iPad-settings"
        settings.lifetime = .keepAlways
        add(settings)
    }

    /// Seed the disposable simulator before running this test, as for deletion tests.
    @MainActor func testExportAllLogsPresentsZIPAndKeepsHistory() throws {
        let app = XCUIApplication()
        app.launch()
        let ready = app.buttons["record"]
        XCTAssertTrue(ready.waitForExistence(timeout: 45))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: ready)
        waitForExpectations(timeout: 60)
        app.tabBars.buttons["日志及模型信息"].tap()
        let group = app.descendants(matching: .any).matching(identifier: "batchGroup.11111111-1111-4111-8111-111111111100").firstMatch
        guard group.waitForExistence(timeout: 5) else { throw XCTSkip("Requires isolated UI fixtures") }
        let export = app.buttons["exportAllLogs"]
        for _ in 0..<8 where !export.isHittable { app.swipeUp() }
        XCTAssertTrue(export.isHittable)
        let entry = XCTAttachment(screenshot: app.screenshot()); entry.name = "Export-all-logs-entry"; entry.lifetime = .keepAlways; add(entry)
        export.tap()
        let sheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 30), app.debugDescription)
        let archive = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'SoundTest-all-logs-'")).firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 5), app.debugDescription)
        let archiveType = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'ZIP'")).firstMatch
        XCTAssertTrue(archiveType.exists, "The system share sheet must recognize a ZIP archive")
        let sharing = XCTAttachment(screenshot: app.screenshot()); sharing.name = "Export-all-logs-share-ZIP"; sharing.lifetime = .keepAlways; add(sharing)
        let close = app.buttons.matching(NSPredicate(format: "label == 'Close' OR label == '关闭' OR label == 'Cancel' OR label == '取消'")).firstMatch
        if close.exists { close.tap() } else { sheet.swipeDown() }
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: sheet)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.state, .runningForeground)
        for _ in 0..<8 { app.swipeDown() }
        XCTAssertTrue(group.exists)
        XCTAssertTrue(app.staticTexts["单条测试 · 2"].exists)
    }

    /// Run on an isolated simulator seeded by Scripts/prepare-log-ui-fixtures.py.
    @MainActor func testSwipeDeletionCancellationAndClearAll() throws {
        let app = XCUIApplication()
        app.launch()
        let ready = app.buttons["record"]
        XCTAssertTrue(ready.waitForExistence(timeout: 45))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: ready)
        waitForExpectations(timeout: 60)
        app.tabBars.buttons["日志及模型信息"].tap()
        let record = app.descendants(matching: .any).matching(identifier: "historyRecord.11111111-1111-4111-8111-111111111101").firstMatch
        guard record.waitForExistence(timeout: 5) else { throw XCTSkip("Requires isolated UI fixtures; never clear a developer's existing logs.") }
        let group = app.descendants(matching: .any).matching(identifier: "batchGroup.11111111-1111-4111-8111-111111111100").firstMatch
        XCTAssertTrue(group.exists)
        record.swipeRight()
        let request = app.buttons["requestLogDelete"].firstMatch
        XCTAssertTrue(request.waitForExistence(timeout: 3)); request.tap()
        XCTAssertTrue(app.buttons["确认删除这条日志"].waitForExistence(timeout: 3))
        app.buttons["取消"].tap()
        XCTAssertTrue(record.exists, "Cancelling must keep the row and its record")
        if !request.isHittable { record.swipeRight() }
        request.tap(); app.buttons["确认删除这条日志"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: record)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.state, .runningForeground)

        group.tap()
        XCTAssertTrue(app.navigationBars["批量日志组"].waitForExistence(timeout: 5))
        let detail = XCTAttachment(screenshot: app.screenshot()); detail.name = "Batch-log-detail"; detail.lifetime = .keepAlways; add(detail)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        group.swipeLeft(); request.tap()
        XCTAssertTrue(app.buttons["确认删除整组日志"].waitForExistence(timeout: 3))
        app.buttons["确认删除整组日志"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: group)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.state, .runningForeground)

        let clear = app.buttons["clearLogs"]
        for _ in 0..<8 where !clear.isHittable { app.swipeUp() }
        XCTAssertTrue(clear.isHittable); clear.tap()
        XCTAssertTrue(app.buttons["确认清空全部日志"].waitForExistence(timeout: 3))
        let confirmation = XCTAttachment(screenshot: app.screenshot()); confirmation.name = "Clear-logs-confirmation"; confirmation.lifetime = .keepAlways; add(confirmation)
        app.buttons["取消"].tap()
        clear.tap(); app.buttons["确认清空全部日志"].tap()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: clear)
        waitForExpectations(timeout: 5)
        for _ in 0..<8 { app.swipeDown() }
        XCTAssertTrue(app.staticTexts["单条测试 · 0"].exists)
        XCTAssertTrue(app.staticTexts["批量测试 · 0 组"].exists)
        let empty = XCTAttachment(screenshot: app.screenshot()); empty.name = "Logs-cleared"; empty.lifetime = .keepAlways; add(empty)
        app.terminate(); app.launch()
        app.tabBars.buttons["日志及模型信息"].tap()
        XCTAssertTrue(app.staticTexts["单条测试 · 0"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["批量测试 · 0 组"].exists)
    }

    @MainActor func testBatchImportEntryAndGroupedHistory() throws {
        let app = XCUIApplication()
        app.launch()
        let button = app.buttons["importBatch"]
        XCTAssertTrue(button.waitForExistence(timeout: 45))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: button)
        waitForExpectations(timeout: 60)
        for _ in 0..<3 where !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.isHittable)
        let home = XCTAttachment(screenshot: app.screenshot()); home.name = "Batch-WAV-entry"; home.lifetime = .keepAlways; add(home)
        button.tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label == 'Cancel' OR label == '取消'")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        let picker = XCTAttachment(screenshot: app.screenshot()); picker.name = "Batch-native-files-picker"; picker.lifetime = .keepAlways; add(picker)
        cancel.tap()
        app.tabBars.buttons["日志及模型信息"].tap()
        XCTAssertTrue(app.navigationBars["日志及模型信息"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '批量测试 · '")).firstMatch.exists)
        let history = XCTAttachment(screenshot: app.screenshot()); history.name = "Batch-grouped-history"; history.lifetime = .keepAlways; add(history)
    }

    @MainActor func testNativeTabsAndOfflineModelSwitches() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["record"].waitForExistence(timeout: 45))
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.buttons["测试"].exists)
        XCTAssertTrue(tabs.buttons["日志及模型信息"].exists)
        XCTAssertTrue(tabs.buttons["设置"].exists)
        app.segmentedControls["taskPicker"].buttons["声音事件"].tap()
        for id in ["cedTiny", "cedMini", "yamnet", "efficientAT", "zipformer"] {
            let ready = NSPredicate(format: "enabled == true")
            expectation(for: ready, evaluatedWith: app.buttons["modelSelector"])
            waitForExpectations(timeout: 60)
            app.buttons["modelSelector"].tap()
            XCTAssertTrue(app.buttons["model.\(id)"].waitForExistence(timeout: 5))
            app.buttons["model.\(id)"].tap()
        }
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["record"])
        waitForExpectations(timeout: 60)
        app.segmentedControls["taskPicker"].buttons["环境场景"].tap()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["record"])
        waitForExpectations(timeout: 60)
        XCTAssertTrue(app.staticTexts["CP-Mobile 通用场景模型"].exists)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["当前场景"].waitForExistence(timeout: 5))
        let scene = XCTAttachment(screenshot: app.screenshot()); scene.name = "SoundTest-ASC"; scene.lifetime = .keepAlways; add(scene)
        app.swipeDown()
        app.segmentedControls["taskPicker"].buttons["声音事件"].tap()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["record"])
        waitForExpectations(timeout: 60)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "SoundTest-home"; attachment.lifetime = .keepAlways; add(attachment)
        tabs.buttons["日志及模型信息"].tap()
        XCTAssertTrue(app.navigationBars["日志及模型信息"].waitForExistence(timeout: 5))
        tabs.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        let settings = XCTAttachment(screenshot: app.screenshot()); settings.name = "SoundTest-settings"; settings.lifetime = .keepAlways; add(settings)
        for _ in 0..<6 where !app.staticTexts["猫狗叫声"].exists { app.swipeUp() }
        for target in ["猫狗叫声", "咳嗽", "笑声", "鼓掌"] {
            XCTAssertTrue(app.staticTexts[target].waitForExistence(timeout: 3), "Missing configured business target: \(target)")
        }
        let targets = XCTAttachment(screenshot: app.screenshot()); targets.name = "SoundTest-target-thresholds"; targets.lifetime = .keepAlways; add(targets)
    }
}
