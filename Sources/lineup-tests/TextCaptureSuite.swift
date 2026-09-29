import AppCore
import CoreGraphics
import Foundation
import TextCaptureCore

func runTextCaptureTests() throws {
    // Independent expected rectangles catch origin inversion and use of the primary scale.
    let cases: [(String, CGRect, CGRect, CGFloat, CGRect, Int, Int)] = [
        ("Retina", CGRect(x: 100, y: 600, width: 300, height: 100),
         CGRect(x: 0, y: 0, width: 1440, height: 900), 2,
         CGRect(x: 100, y: 200, width: 300, height: 100), 600, 200),
        ("left display", CGRect(x: -1800, y: 200, width: 400, height: 200),
         CGRect(x: -1920, y: -180, width: 1920, height: 1080), 1,
         CGRect(x: 120, y: 500, width: 400, height: 200), 400, 200),
        ("above display", CGRect(x: 200, y: 1500, width: 400, height: 100),
         CGRect(x: 100, y: 900, width: 1920, height: 1080), 2,
         CGRect(x: 100, y: 380, width: 400, height: 100), 800, 200),
        ("below display", CGRect(x: 300, y: -500, width: 200, height: 100),
         CGRect(x: 200, y: -1080, width: 1920, height: 1080), 1,
         CGRect(x: 100, y: 400, width: 200, height: 100), 200, 100),
        ("cross-display drag clips to starting display", CGRect(x: -50, y: 100, width: 200, height: 80),
         CGRect(x: 0, y: 0, width: 1440, height: 900), 2,
         CGRect(x: 0, y: 720, width: 150, height: 80), 300, 160),
        ("scaled fractional bounds", CGRect(x: 10.2, y: 20.2, width: 30.1, height: 40.1),
         CGRect(x: 0, y: 0, width: 100, height: 100), 2,
         CGRect(x: 10, y: 39.5, width: 30.5, height: 40.5), 61, 81),
        ("reverse drag", CGRect(x: 400, y: 700, width: -300, height: -100),
         CGRect(x: 0, y: 0, width: 1440, height: 900), 2,
         CGRect(x: 100, y: 200, width: 300, height: 100), 600, 200),
    ]
    for (name, selection, display, scale, expected, width, height) in cases {
        let region = CaptureRegion(selection: selection, displayFrame: display, scale: scale)
        check(region?.sourceRect == expected, "capture \(name): source uses display-local top-left points")
        check(region?.pixelWidth == width && region?.pixelHeight == height,
              "capture \(name): output retains the selected display's resolution")
    }
    let screen = CGRect(x: 0, y: 0, width: 100, height: 100)
    for selection in [CGRect.zero, CGRect(x: 200, y: 200, width: 20, height: 20),
                      CGRect(x: 1, y: 1, width: 1, height: 40),
                      CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 10)] {
        check(CaptureRegion(selection: selection, displayFrame: screen, scale: 2) == nil,
              "empty, tiny, nonfinite and off-display selections never become captures")
    }
    check(CaptureRegion(selection: screen, displayFrame: screen, scale: 0) == nil,
          "a missing display scale refuses capture")

    // Only .copy authorizes the app-side clipboard write. All unsuccessful paths must yield
    // another outcome, and obsolete completions must not consume the next invocation.
    var session = CaptureSession()
    let first = session.begin()!
    check(session.begin() == nil, "an active session rejects another invocation")
    check(session.finish(first, text: "  Olá mundo\nHello world\n") == .copy("Olá mundo\nHello world"),
          "successful recognition authorizes plain text with accents and line breaks")
    check(session.finish(first, text: "duplicate") == .ignored, "a completed request cannot copy twice")
    for text: String? in ["", " \n\t", nil] {
        let token = session.begin()!
        check(session.finish(token, text: text) == (text == nil ? .failed : .empty),
              "empty and failed recognition never authorize a clipboard write")
        check(!session.isActive, "empty and failed recognition allow retry")
    }
    let cancelled = session.begin()!
    session.cancel()
    check(session.finish(cancelled, text: "late result") == .ignored,
          "cancelling a session invalidates its pending completion")
    let next = session.begin()!
    check(session.finish(cancelled, text: nil) == .ignored && session.token == next,
          "a late failure cannot dismiss a newer capture")
    check(session.finish(cancelled, text: "old") == .ignored && session.token == next,
          "a late success cannot overwrite or finish a newer capture")
    check(session.finish(next, text: "new") == .copy("new"), "capture recovers after cancellation")
    session.cancel()
    session.cancel()
    check(session.begin() != nil, "teardown is idempotent")

    let lines = [
        RecognizedLine(text: "segunda linha", bounds: CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.1)),
        RecognizedLine(text: "world", bounds: CGRect(x: 0.4, y: 0.803, width: 0.2, height: 0.1)),
        RecognizedLine(text: " Hello ", bounds: CGRect(x: 0.1, y: 0.8, width: 0.25, height: 0.1)),
        RecognizedLine(text: "  ", bounds: CGRect(x: 0.1, y: 0.95, width: 0.1, height: 0.03)),
    ]
    check(CaptureText.readingOrder(lines) == "Hello world\nsegunda linha",
          "OCR fragments join left-to-right on a row and top-to-bottom across rows")
    check(CaptureText.readingOrder(Array(lines.reversed())) == "Hello world\nsegunda linha",
          "reading order does not depend on Vision observation enumeration")
    let languages = CaptureText.languages(available: ["fr-FR", "en-US", "pt-BR"])
    check(languages.selected == ["pt-BR", "en-US"] && languages.missing.isEmpty,
          "recognition selects locally supported Portuguese and English variants")
    check(CaptureText.languages(available: ["en-GB"]).missing == ["Portuguese"],
          "unavailable Portuguese support is explicit")
    check(CaptureText.languages(available: []).missing == ["Portuguese", "English"],
          "an unavailable recognition engine does not silently choose another language")

    // Exercise the real config owner on temporary files. Existing store tests own generic
    // atomic-write and rejected-file behavior; this case owns the new tool's integration.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lineup-text-capture-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.json")
    let store = LineupAppConfigStore(url: url)
    _ = store.load()
    try store.setEnabled(true, for: .zones)
    try store.setEnabled(false, for: .textCapture)
    let settings = TextCaptureSettings(shortcut: .init(keyCode: 17, modifiers: 256 | 512),
                                       extra: ["futurePreference": .string("preserve")])
    try store.setSettings(settings, for: .textCapture)
    let reread = LineupAppConfigStore(url: url)
    check(reread.load() == .loaded, "Text Capture preferences load through the shared store")
    check(try reread.config.settings(TextCaptureSettings.self, for: .textCapture) == settings,
          "the recorded shortcut and unknown settings survive reload")
    check(reread.config.isEnabled(.textCapture) == false && reread.config.isEnabled(.zones) == true,
          "editing a disabled Text Capture does not enable it or change sibling enablement")
    for json in [#"{"shortcut":{"keyCode":17,"modifiers":0}}"#,
                 #"{"shortcut":{"keyCode":999,"modifiers":256}}"#,
                 #"{"shortcut":"damaged"}"#] {
        var rejected = false
        do { _ = try JSONDecoder().decode(TextCaptureSettings.self, from: Data(json.utf8)) }
        catch { rejected = true }
        check(rejected, "invalid Text Capture shortcuts fail loading instead of becoming active defaults")
    }
}
