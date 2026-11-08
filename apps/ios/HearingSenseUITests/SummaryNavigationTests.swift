import XCTest

/// UI acceptance uses an explicitly scripted Debug engine and synthetic captions. Model
/// performance and real speech recognition are verified by the separate device probes.
final class SummaryNavigationTests: XCTestCase {
    @MainActor private func startFixture(_ app: XCUIApplication) {
        app.terminate()
        app.launch()
        // This headless Simulator occasionally cold-launches without presenting the Debug
        // fixture. Retry setup once; functional assertions never receive retries.
        if !app.buttons["conversation.summarize"].waitForExistence(timeout: 10) {
            let setup = XCTAttachment(string: "Simulator Debug fixture was absent on cold launch; restarted setup once.")
            setup.name = "Fixture setup retry"
            setup.lifetime = .keepAlways
            add(setup)
            app.terminate()
            app.launch()
        }
        XCTAssertTrue(app.buttons["conversation.summarize"].waitForExistence(timeout: 10))
    }
    @MainActor private func launchFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--hs-w9-ui-fixture", "--hs-screen", "conversation", "--hs-synthetic-capture",
                               "--hs-test-mode", "locked", "--hs-test-allow", "model", "--hs-test-session-limit", "600"]
        startFixture(app)
        return app
    }
    @MainActor func testSummaryOpensProgressThenFullSummaryWithoutScrolling() {
        let app = launchFixture()
        app.buttons["conversation.summarize"].tap()
        XCTAssertTrue(app.staticTexts["summary.progress"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Summary"].exists)
        XCTAssertTrue(app.tabBars.buttons["History"].isSelected)
        let progress = XCTAttachment(screenshot: app.screenshot())
        progress.name = "Summary progress"
        progress.lifetime = .keepAlways
        add(progress)
        let body = app.staticTexts["summary.body"]
        let deadline = Date.now.addingTimeInterval(12)
        while !body.exists, Date.now < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertTrue(body.exists)
        XCTAssertTrue(body.isHittable)
        if let value = body.value as? String, let savedAt = Double(value) {
            let latency = Date.now.timeIntervalSince1970 - savedAt
            XCTAssertLessThan(latency, 1, "Full summary must be visible within one second of saving")
            let timing = XCTAttachment(string: "Synthetic save-to-visible latency: \(latency) seconds")
            timing.name = "Summary publication latency"
            timing.lifetime = .keepAlways
            add(timing)
        } else { XCTFail("Fixed-fixture save timestamp is missing") }
        let visible = body.label
        XCTAssertTrue(visible.contains("Friday"))
        XCTAssertFalse(app.staticTexts["Recent speech (temporary)"].exists)
        let ready = XCTAttachment(screenshot: app.screenshot())
        ready.name = "Summary ready"
        ready.lifetime = .keepAlways
        add(ready)
        app.navigationBars.buttons["History"].tap()
        app.cells.firstMatch.tap()
        XCTAssertEqual(app.staticTexts["summary.body"].label, visible)
    }
    @MainActor func testBackgroundDuringGenerationResumesOnSummaryPage() {
        let app = launchFixture()
        app.buttons["conversation.summarize"].tap()
        XCTAssertTrue(app.navigationBars["Summary"].waitForExistence(timeout: 3))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.staticTexts["summary.body"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["summary.body"].isHittable)
        XCTAssertTrue(app.tabBars.buttons["History"].isSelected)
    }

    @MainActor func testIslandSummaryOpensTheAppSummaryPage() {
        let app = launchFixture()
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)).press(forDuration: 1.2)
        let summary = springboard.buttons["Summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(summary.frame.height, 44)
        Thread.sleep(forTimeInterval: 1) // Capture the settled expansion, not its mask animation.
        let expanded = XCTAttachment(screenshot: springboard.screenshot())
        expanded.name = "Expanded island controls"
        expanded.lifetime = .keepAlways
        add(expanded)
        summary.tap()
        XCTAssertTrue(app.navigationBars["Summary"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["summary.body"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["summary.body"].isHittable)
    }

    @MainActor func testExpandedIslandLongSummaryAndButtonsFit() {
        let app = XCUIApplication()
        app.launchArguments = ["--hs-w9-ui-fixture", "--hs-screen", "conversation", "--hs-synthetic-capture",
                               "--hs-test-mode", "locked", "--hs-test-allow", "model", "--hs-test-session-limit", "600",
                               "--hs-island-conversation", "ready-long", "--hs-sample-history"]
        startFixture(app)
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)).press(forDuration: 1.2)
        let preview = springboard.staticTexts["island.summary-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertFalse(preview.label.isEmpty)
        XCTAssertLessThanOrEqual(preview.frame.height, 72)
        XCTAssertGreaterThanOrEqual(springboard.buttons["Summary"].frame.height, 44)
        XCTAssertGreaterThanOrEqual(springboard.buttons["Continue"].frame.height, 44)
        Thread.sleep(forTimeInterval: 1)
        let image = XCTAttachment(screenshot: springboard.screenshot())
        image.name = "Expanded island long summary"
        image.lifetime = .keepAlways
        add(image)
    }
}
