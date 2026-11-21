import XCTest

final class FlowUITests: XCTestCase {
    private enum StoreLanguage: String, CaseIterable {
        case simplified = "zh-Hans"
        case english = "en"
        case traditional = "zh-Hant"

        var locale: String {
            switch self {
            case .simplified: return "zh_CN"
            case .english: return "en_US"
            case .traditional: return "zh_TW"
            }
        }
    }

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ args: [String] = [], language: StoreLanguage = .simplified, reset: Bool = true,
                        presetCode: String? = nil) {
        app.launchArguments = ["-ui-testing", "-AppleLanguages", "(\(language.rawValue))",
                               "-AppleLocale", language.locale] + (reset ? ["-reset"] : []) + args
        if let presetCode { app.launchEnvironment["BA_PRESET_TEXT"] = presetCode }
        app.launch()
    }

    private func tap(_ id: String, scroll: Bool = false) {
        let button = app.buttons[id].firstMatch
        if scroll {
            for _ in 0..<4 where !button.isHittable { app.swipeUp() }
        }
        XCTAssertTrue(button.waitForExistence(timeout: 10), id)
        XCTAssertTrue(button.isHittable, id)
        button.tap()
    }

    private func fixture(_ names: [String]) {
        for name in names { tap("fixture." + name) }
        tap("fixture.confirm")
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                               object: app.buttons["fixture.confirm"])
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 8), .completed)
        XCTAssertTrue(app.staticTexts["editor.dimensions"].waitForExistence(timeout: 10))
    }

    private func startPair(_ names: [String] = ["entry-before", "entry-after"]) {
        tap("home.pick")
        fixture(names)
    }

    private func expectDimensions(_ width: Int, _ height: Int) {
        let label = app.staticTexts["editor.dimensions"]
        XCTAssertTrue(label.waitForExistence(timeout: 8))
        XCTAssertEqual(label.label.filter(\.isNumber), "\(width)\(height)")
    }

    private func capture(_ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["SHOTS_DIR"] ?? environment["TEST_RUNNER_SHOTS_DIR"] {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
        }
    }

    func testTwoPhotosAutoLayoutSwitchAndSave() {
        launch()
        startPair(["wide-before", "wide-after"])
        expectDimensions(1365, 2048)
        tap("editor.side")
        expectDimensions(2048, 1365)
        tap("editor.save")
        XCTAssertTrue(app.staticTexts["editor.saved"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["editor.save"].exists)
        XCTAssertTrue(app.buttons["editor.makeCard"].isHittable)
    }

    func testPartialImportReplacementAndRelaunch() {
        launch()
        tap("home.pick")
        fixture(["entry-before"])
        XCTAssertFalse(app.buttons["editor.save"].isEnabled)
        tap("editor.slot.after")
        fixture(["invalid-photo"])
        XCTAssertTrue(app.staticTexts["status.message"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["editor.save"].isEnabled)
        tap("editor.slot.after")
        fixture(["entry-after"])
        tap("editor.stack")
        tap("editor.swap", scroll: true)
        tap("editor.labels", scroll: true)
        tap("editor.align", scroll: true)
        let before = app.buttons["editor.slot.before"]
        XCTAssertTrue(before.isSelected)
        before.pinch(withScale: 1.5, velocity: 1)
        tap("editor.back")
        app.terminate()
        launch(reset: false)
        tap("home.recent")
        expectDimensions(1365, 2048)
        XCTAssertFalse(app.buttons["editor.labels"].isSelected)
        XCTAssertTrue(app.buttons["editor.save"].isEnabled)
    }

    func testPhotosDenialKeepsExportAndProvidesFileFallback() {
        launch(["-deny-photos"])
        startPair()
        tap("editor.save")
        XCTAssertTrue(app.buttons["editor.saveFiles"].waitForExistence(timeout: 10))
        tap("editor.saveFiles")
        let pickerButton = NSPredicate(format: "label IN %@", argumentArray: [["Save", "存储", "存储到文件", "取消", "Cancel"]])
        XCTAssertTrue(app.buttons.matching(pickerButton).firstMatch.waitForExistence(timeout: 10))
    }

    func testPastePresetUsesItsLayoutAndAdvancedPresetOffersBasicCopy() {
        let basicCode = makeCode(size: "basic")
        launch(presetCode: basicCode)
        tap("home.importPreset")
        tap("preset.paste")
        fixture(["entry-before", "entry-after"])
        expectDimensions(1365, 2048)
        XCTAssertFalse(app.buttons["editor.labels"].isSelected)
        app.terminate()

        launch(["-expired"], presetCode: makeCode(size: "high"))
        tap("home.importPreset")
        tap("preset.paste")
        tap("preset.basic")
        fixture(["entry-before", "entry-after"])
        expectDimensions(1365, 2048)
        tap("editor.back")
        tap("home.importPreset")
        XCTAssertTrue(app.buttons["preset.retained"].waitForExistence(timeout: 8))
    }

    func testExpiredKeepsOriginalExportAndCanMakeBasicCopy() {
        launch()
        startPair()
        tap("editor.size", scroll: true)
        tap("size.high")
        expectDimensions(4096, 2731)
        tap("editor.save")
        XCTAssertTrue(app.staticTexts["editor.saved"].waitForExistence(timeout: 12))
        app.terminate()
        launch(["-expired"], reset: false)
        tap("home.recent")
        expectDimensions(4096, 2731)
        tap("editor.exports", scroll: true)
        XCTAssertTrue(app.buttons["exports.share.0"].waitForExistence(timeout: 8))
        let exportLabel = app.buttons["exports.preview.0"].label
        XCTAssertTrue(exportLabel.filter(\.isNumber).contains("4096"), exportLabel)
        tap("panel.done")
        tap("editor.basicCopy", scroll: true)
        expectDimensions(2048, 1365)
        tap("editor.back")
        tap("home.history")
        XCTAssertTrue(app.buttons["history.project.1"].waitForExistence(timeout: 8))
    }

    func testCustomDimensionsShowBeforeApplying() {
        launch()
        startPair()
        tap("editor.size")
        let width = app.textFields["size.width"]
        XCTAssertTrue(width.waitForExistence(timeout: 8))
        width.tap()
        width.typeText("2400")
        let height = app.textFields["size.height"]
        height.tap()
        height.typeText("3000")
        let preview = app.staticTexts["size.customPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 8))
        XCTAssertEqual(preview.label.filter(\.isNumber), "24003000")
        tap("size.apply", scroll: true)
        expectDimensions(2400, 3000)
    }

    func testShareCardQRAndStyleCode() {
        launch()
        startPair()
        tap("editor.share")
        XCTAssertTrue(app.buttons["editor.shareClean"].waitForExistence(timeout: 5))
        tap("editor.shareCard")
        XCTAssertTrue(app.images["card.preview"].waitForExistence(timeout: 10))
        let qr = app.switches["card.qr"]
        XCTAssertTrue(qr.exists)
        qr.tap()
        XCTAssertEqual(qr.value as? String, "0")
        tap("card.copyTopic", scroll: true)
        tap("card.sharePreset", scroll: true)
        tap("card.copyPreset")
        XCTAssertTrue(app.staticTexts["status.message"].waitForExistence(timeout: 8))
    }

    func testMilestoneRequiresThreeSeparateProjects() {
        launch()
        for i in 1...3 {
            startPair()
            tap("editor.save")
            XCTAssertTrue(app.staticTexts["editor.saved"].waitForExistence(timeout: 12))
            tap("editor.back")
            if i < 3 { XCTAssertFalse(app.buttons["home.milestone"].exists) }
        }
        tap("home.milestone", scroll: true)
        XCTAssertTrue(app.images["card.preview"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["card.milestonePhotos"].exists)
    }

    func testStoreScreenshots() {
        for language in StoreLanguage.allCases {
            launch(["-store-shots"], language: language)
            XCTAssertTrue(app.buttons["home.pick"].waitForExistence(timeout: 12))
            let prefix = "store-" + language.rawValue
            capture("\(prefix)-01-home")
            startPair(["entry-before", "wide-after"])
            tap("editor.stack")
            expectDimensions(1365, 2048)
            capture("\(prefix)-02-layout")
            tap("editor.side")
            tap("editor.align")
            capture("\(prefix)-03-align")
            tap("editor.save")
            XCTAssertTrue(app.staticTexts["editor.saved"].waitForExistence(timeout: 12))
            capture("\(prefix)-04-save")
            tap("editor.makeCard")
            XCTAssertTrue(app.images["card.preview"].waitForExistence(timeout: 10))
            capture("\(prefix)-05-share-card")
            app.terminate()
        }
    }

    func testPaidScreenshotAndRestoreEntry() {
        launch(["-paid-mode", "-paywall"])
        let status = app.staticTexts["pay.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.contains("30"))
        XCTAssertTrue(app.buttons["pay.claim"].exists)
        capture("paid-01-paywall")
        tap("pay.restore", scroll: true)
        XCTAssertTrue(app.staticTexts["status.message"].waitForExistence(timeout: 8))
        app.terminate()

        launch(["-expired", "-paywall"])
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.contains("结束"))
    }

    private func makeCode(size: String) -> String {
        let json = """
        {"version":1,"layout":"stacked","spacing":6,"labels":false,"size":"\(size)"}
        """
        return "BA1-" + Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
