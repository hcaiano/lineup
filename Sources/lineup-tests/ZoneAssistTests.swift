import CoreGraphics
import Foundation
import ZonesCore

func runZoneAssistTests() throws {
    let a = CGRect(x: 0, y: 0, width: 500, height: 900)
    let b = CGRect(x: 500, y: 0, width: 500, height: 900)
    let c = CGRect(x: 1000, y: 0, width: 500, height: 900)
    check(ZoneVacancy.destination(zones: [a, b, c], filled: a, visibleFrames: [a]) == b,
          "confirmed drag offers only closest free leaf")
    let untracked = CGRect(x: 700, y: 200, width: 100, height: 100)
    check(ZoneVacancy.destination(zones: [a, b, c], filled: a, visibleFrames: [a, untracked]) == c,
          "untracked or unresolved visible intersection blocks nominal vacancy")
    check(!ZoneVacancy.isFree(b, visibleFrames: [untracked]) && ZoneVacancy.isFree(b, visibleFrames: [c]),
          "vacancy uses actual visible frames rather than snap ledger")
    check(ThumbnailSize.fit(CGSize(width: 1000, height: 500), maximum: CGSize(width: 480, height: 270)) == CGSize(width: 480, height: 240)
        && ThumbnailSize.fit(CGSize(width: 500, height: 1000), maximum: CGSize(width: 480, height: 270)) == CGSize(width: 135, height: 270),
          "wide and tall thumbnail dimensions preserve aspect ratio")
    check(WindowIdentityGeometry.matches(surface: CGRect(x: 34, y: 104, width: 472, height: 384),
                                         accessibility: CGRect(x: 30, y: 100, width: 480, height: 392))
        && !WindowIdentityGeometry.matches(surface: CGRect(x: 34, y: 104, width: 472, height: 384),
                                           accessibility: CGRect(x: 20, y: 100, width: 480, height: 392)),
          "compositor inset matches AX frame without accepting displaced neighboring window")
    let observedAX = CGRect(x: 0, y: 0, width: 2560, height: 1410)
    check(WindowIdentityGeometry.matches(surface: CGRect(x: 0, y: 0, width: 2560, height: 1410), accessibility: observedAX),
          "ordinary-shadow fixture bounds observed without an outset match the literal AX rectangle")
    check(WindowIdentityGeometry.matches(surface: CGRect(x: -1, y: -1, width: 2562, height: 1412), accessibility: observedAX)
            && WindowIdentityGeometry.matches(surface: CGRect(x: 8, y: 8, width: 2544, height: 1394), accessibility: observedAX),
          "existing one-point outward compatibility and eight-point insets remain supported")
    check(!WindowIdentityGeometry.matches(surface: CGRect(x: -2, y: -1, width: 2564, height: 1412), accessibility: observedAX)
            && !WindowIdentityGeometry.matches(surface: CGRect(x: -3, y: -1, width: 2566, height: 1412), accessibility: observedAX)
            && !WindowIdentityGeometry.matches(surface: CGRect(x: 3, y: 0, width: 2560, height: 1410), accessibility: observedAX),
          "unreproduced historic two-point outset, larger surfaces and shifted rectangles stay conservatively unresolved")
    let data = Data("{\"schemaVersion\":3,\"screens\":{},\"defaultLayout\":{\"type\":\"leaf\"},\"dragSnapModifiers\":4352,\"dragSnapKeyCode\":40}".utf8)
    var config = try JSONDecoder().decode(LineupConfig.self, from: data)
    check(config.fillAssistEnabled != true && config.dragSnapKeyCode == 40 && config.dragSnapModifiers == 4352,
          "older config keeps assist off and customized bind intact")
    config.fillAssistEnabled = true
    let roundTrip = try JSONDecoder().decode(LineupConfig.self, from: JSONEncoder().encode(config))
    check(roundTrip.fillAssistEnabled == true && roundTrip.dragSnapKeyCode == 40 && roundTrip.defaultLayout == .leaf,
          "assist preference round-trip preserves existing settings")

    check(ThumbnailSize.fit(CGSize(width: 480, height: 392), maximum: CGSize(width: 960, height: 540)) == CGSize(width: 480, height: 392),
          "a small source is never upscaled into a padded thumbnail")

    let wide = CGRect(x: 0, y: 0, width: 5100, height: 1400)
    let first = CGRect(x: 0, y: 0, width: 1700, height: 1400)
    let second = CGRect(x: 1700, y: 0, width: 1700, height: 1400)
    check(ZoneFillLayout.columns(panelWidth: 560) == 3, "a full-width chooser has three columns")
    check(ZoneFillLayout.columns(panelWidth: 532) == 3 && ZoneFillLayout.columns(panelWidth: 531) == 2,
          "three columns fit exactly with twenty-point margins")
    let oneRow = ZoneFillLayout.chooserFrame(free: second, filled: first, visible: wide, rows: 1)
    let full = ZoneFillLayout.chooserFrame(free: second, filled: first, visible: wide, rows: 11)
    check(oneRow == CGRect(x: 1712, y: 585, width: 532, height: 230) && full == CGRect(x: 1712, y: 480, width: 532, height: 440),
          "on an ultrawide the chooser sits inside the free zone beside the drop, at most 532 by 440")
    let compactDisplay = CGRect(x: 0, y: 0, width: 220, height: 260)
    let compactChooser = ZoneFillLayout.chooserFrame(free: compactDisplay, filled: CGRect(x: -220, y: 0, width: 220, height: 260),
                                                   visible: compactDisplay, rows: 5)
    check(compactChooser == CGRect(x: 12, y: 12, width: 196, height: 236)
            && ZoneFillLayout.columns(panelWidth: compactChooser.width) == 1,
          "narrow chooser chrome clamps to the display with one card column")
    let shortDisplay = CGRect(x: -320, y: 100, width: 320, height: 70)
    check(ZoneFillLayout.chooserFrame(free: shortDisplay, filled: CGRect(x: -640, y: 100, width: 320, height: 70),
                                     visible: shortDisplay, rows: 1)
            == CGRect(x: -308, y: 112, width: 196, height: 46),
          "short negative-origin displays bound chooser chrome to one whole card column")

    let small = CGRect(x: 0, y: 0, width: 1280, height: 800)
    let narrow = CGRect(x: 880, y: 0, width: 400, height: 800)
    let narrowChooser = ZoneFillLayout.chooserFrame(free: narrow, filled: CGRect(x: 0, y: 0, width: 880, height: 800),
                                                    visible: small, rows: 1)
    check(narrowChooser == CGRect(x: 892, y: 285, width: 364, height: 230)
            && ZoneFillLayout.columns(panelWidth: narrowChooser.width) == 2,
          "a free zone narrower than the chooser gets a whole two-column chooser inside it, off the placed window")
    check(ZoneFillLayout.chooserFrame(free: CGRect(x: 1700, y: 0, width: 550, height: 1400), filled: first, visible: wide, rows: 1).width == 364
            && ZoneFillLayout.chooserFrame(free: CGRect(x: 1700, y: 0, width: 556, height: 1400), filled: first, visible: wide, rows: 1).width == 532,
          "a chooser narrowed to its free zone snaps to whole card columns")
    let placed = CGRect(x: 0, y: 0, width: 640, height: 800)
    check(ZoneFillLayout.chooserFrame(free: CGRect(x: 640, y: 0, width: 200, height: 800), filled: placed, visible: small, rows: 1)
            == CGRect(x: 652, y: 285, width: 532, height: 230),
          "a zone too small for one column moves the chooser 12 points past the placed window, still over its zone")
    let tiny = CGRect(x: 0, y: 0, width: 600, height: 400)
    check(ZoneFillLayout.chooserFrame(free: CGRect(x: 300, y: 0, width: 300, height: 400),
                                     filled: CGRect(x: 0, y: 0, width: 300, height: 400), visible: tiny, rows: 1)
            == CGRect(x: 312, y: 85, width: 196, height: 230),
          "a 300-point free zone gets a one-column chooser inside it instead of covering the placed window")
    let square = CGRect(x: 0, y: 0, width: 400, height: 400)
    check(ZoneFillLayout.chooserFrame(free: CGRect(x: 200, y: 0, width: 200, height: 400),
                                     filled: CGRect(x: 0, y: 0, width: 200, height: 400), visible: square, rows: 1)
            == CGRect(x: 24, y: 85, width: 364, height: 230),
          "without room for one column or beside the placed window the chooser stays centered on its zone within the display")

    let air = CGRect(x: 0, y: 0, width: 1470, height: 920)
    func airColumn(_ index: Int, of count: Int) -> CGRect {
        CGRect(x: CGFloat(index) * 1470 / CGFloat(count), y: 0, width: 1470 / CGFloat(count), height: 920)
    }
    check(ZoneFillLayout.chooserFrame(free: airColumn(0, of: 4), filled: airColumn(1, of: 4), visible: air, rows: 1)
            == CGRect(x: 159.5, y: 345, width: 196, height: 230),
          "a free column left of the drop on a 1470-point display keeps a one-column chooser inside it, not over columns 3 and 4")
    check(ZoneFillLayout.chooserFrame(free: airColumn(3, of: 4), filled: airColumn(2, of: 4), visible: air, rows: 1)
            == CGRect(x: 1114.5, y: 345, width: 196, height: 230),
          "a free column right of the drop keeps a one-column chooser inside it on the drop side")
    check(ZoneFillLayout.chooserFrame(free: airColumn(0, of: 7), filled: airColumn(1, of: 7), visible: air, rows: 1)
            == CGRect(x: 12, y: 345, width: 532, height: 230)
            && ZoneFillLayout.chooserFrame(free: airColumn(6, of: 7), filled: airColumn(5, of: 7), visible: air, rows: 1)
            == CGRect(x: 926, y: 345, width: 532, height: 230),
          "a 210-point free column at either display edge keeps the chooser over it, overlapping the placed window rather than detaching")

    let secondary = CGRect(x: -1440, y: -300, width: 1440, height: 875)
    let secondaryFree = CGRect(x: -720, y: -300, width: 720, height: 875)
    check(ZoneFillLayout.chooserFrame(free: secondaryFree, filled: CGRect(x: -1440, y: -300, width: 720, height: 875),
                                     visible: secondary, rows: 1)
            == CGRect(x: -708, y: 22.5, width: 532, height: 230),
          "the chooser stays inside the free zone on a negative-origin display")
    check(ZoneFillLayout.chooserFrame(free: CGRect(x: -1440, y: -300, width: 360, height: 875),
                                     filled: CGRect(x: -1080, y: -300, width: 360, height: 875), visible: secondary, rows: 1)
            == CGRect(x: -1288, y: 22.5, width: 196, height: 230),
          "a 360-point free column on a negative-origin display keeps a one-column chooser inside it beside the drop")

    check(ZoneNotice.frame(size: CGSize(width: 300, height: 64), anchor: CGPoint(x: -641, y: 137.5), visible: secondary)
            == CGRect(x: -791, y: 49.5, width: 300, height: 64),
          "the notice sits under its anchor on a negative-origin display")
    check(ZoneNotice.frame(size: CGSize(width: 300, height: 64), anchor: CGPoint(x: 100, y: 30), visible: small)
            == CGRect(x: 12, y: 54, width: 300, height: 64),
          "the notice moves above an anchor near the bottom and stays on the display")

    typealias Outcome = ExactCommit.Outcome<Int>
    func text(_ outcome: Outcome, _ context: ZoneNotice.Context, _ app: String? = nil) -> [String]? {
        ZoneNotice.text(for: outcome, context: context, appName: app).map { [$0.title, $0.detail] }
    }
    check(text(.committed, .divider) == nil, "success shows no notice")
    check(text(.rolledBack(.refused(1)), .divider, "Fixture") == ["Fixture didn’t fit", "Windows were put back. The layout wasn’t saved."]
            && text(.rolledBack(.refused(1)), .share) == ["A window didn’t fit", "Windows were put back."]
            && text(.rolledBack(.refused(1)), .fill, "Notes") == ["Notes didn’t fit", "The window was put back."],
          "a refusal names the app and says the windows were put back")
    check(text(.rejected, .share) == ["Couldn’t apply this change", "Windows or the layout changed. Nothing moved."]
            && text(.rolledBack(.changed), .divider) == ["Couldn’t apply this change", "Windows changed while moving. They were put back."]
            && text(.rolledBack(.notSaved), .divider) == ["Couldn’t save the layout", "Windows were put back."],
          "stale state, a mid-move change and a failed save each have their own wording")
    let incomplete = text(.recovery([FrameEffect(window: 1, before: first, after: second)]), .divider)
    check(incomplete == ["Window restoration incomplete", "Use Retry Restore in the Lineup menu or Zones settings."]
            && incomplete?.joined().contains("put back") == false,
          "incomplete restoration points to Retry Restore and never claims the windows were put back")
}
