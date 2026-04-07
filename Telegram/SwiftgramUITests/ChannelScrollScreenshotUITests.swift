import XCTest

/// Opens a chat from the main list by **row index** (default: 4th cell), scrolls history, attaches screenshots.
///
/// **Prerequisites**
/// - Simulator with Swiftgram logged in on the main chats tab.
///
/// **Which row to open**
/// - Default: **4th** visible `UITableView` cell (`1` = first row).
/// - Override: `SG_UI_TEST_CHAT_LIST_INDEX` (positive integer), e.g. `3` for the third cell.
///
/// **Note:** The index counts **all** cells from the top of the table (including non-chat rows if any).
///
/// **Logs**
/// - Pair console logs with screenshots manually (XCTest attachments are images only).
final class ChannelScrollScreenshotUITests: XCTestCase {

    /// 1-based index: 1 = first cell, default 4 = fourth cell.
    private var chatListRowIndex: Int {
        let raw = ProcessInfo.processInfo.environment["SG_UI_TEST_CHAT_LIST_INDEX"] ?? "4"
        let n = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 4
        return max(1, n)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testChannelScrollAndScreenshots() {
        let app = XCUIApplication()
        app.launch()

        let chatList = app.tables.firstMatch
        XCTAssertTrue(
            chatList.waitForExistence(timeout: 45),
            "Chat list table not found — is the app logged in and on the main chats tab?"
        )

        openChatAtListIndex(in: chatList, oneBasedIndex: chatListRowIndex)

        let historyTable = app.tables.firstMatch
        XCTAssertTrue(
            historyTable.waitForExistence(timeout: 20),
            "Expected chat history UITableView after opening a chat."
        )

        attachScreenshot(name: "01_chat_open")

        XCTContext.runActivity(named: "Scroll up (toward older messages)") { _ in
            for i in 0..<5 {
                historyTable.swipeUp(velocity: .fast)
                sleepMs(400)
                attachScreenshot(name: String(format: "02_scroll_up_%02d", i))
            }
        }

        XCTContext.runActivity(named: "Scroll down (toward newer messages)") { _ in
            for i in 0..<5 {
                historyTable.swipeDown(velocity: .fast)
                sleepMs(400)
                attachScreenshot(name: String(format: "03_scroll_down_%02d", i))
            }
        }

        attachScreenshot(name: "04_done")
    }

    private func openChatAtListIndex(in list: XCUIElement, oneBasedIndex: Int) {
        let zeroBased = oneBasedIndex - 1
        let cell = list.cells.element(boundBy: zeroBased)
        XCTAssertTrue(
            cell.waitForExistence(timeout: 45),
            "Expected at least \(oneBasedIndex) cell(s) in the chat list (row index \(oneBasedIndex) missing)."
        )

        // Large navigation / folder header often covers top rows: cell exists in hierarchy but `isHittable` is false.
        print("[SwiftgramUITests] cell #\(oneBasedIndex) exists hittable=\(cell.isHittable) frame=\(cell.frame.debugDescription)")
        for attempt in 0..<10 {
            if cell.isHittable {
                print("[SwiftgramUITests] cell became hittable after scroll nudges, attempt=\(attempt)")
                cell.tap()
                return
            }
            // Collapse large title / move list so rows sit in the tappable band.
            if attempt < 3 {
                list.swipeDown(velocity: .default)
            } else {
                list.swipeUp(velocity: .slow)
            }
            sleepMs(350)
        }

        print("[SwiftgramUITests] falling back to normalized coordinate tap on cell #\(oneBasedIndex)")
        attachScreenshot(name: "00_before_chat_row_tap")
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func attachScreenshot(name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func sleepMs(_ ms: Int64) {
        usleep(useconds_t(ms * 1000))
    }
}
