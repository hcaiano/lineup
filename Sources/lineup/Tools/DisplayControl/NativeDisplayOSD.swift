import AppKit
import DisplayControlCore
import ObjectiveC
import Darwin

/// The system owns the OSD window, its appearance and its fade. There is no public macOS OSD
/// API; keep the runtime interface isolated so an unavailable service can use the native HUD.
@objc private protocol LineupOSDHelper {
    @objc(showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:)
    func showImage(_ image: Int64, onDisplayID: UInt32, priority: UInt32,
                   msecUntilFade: UInt32, filledChiclets: UInt32,
                   totalChiclets: UInt32, locked: Bool)
}

@MainActor
final class NativeDisplayOSD {
    private var connection: NSXPCConnection?
    private var framework: UnsafeMutableRawPointer?
    private var triedFramework = false

    /// True means submitted to the system, whose interface does not provide a display receipt.
    func show(control: DisplayControl, level: DisplayControlLevel, displayID: CGDirectDisplayID,
              onFailure: @escaping () -> Void) -> Bool {
        let image: Int64 = control == .brightness ? 1 : level.current == 0 ? 4 : 3
        let filled = UInt32((level.normalized * 100).rounded())
        return submit(image: image, filled: filled, displayID: displayID, onFailure: onFailure)
    }

    /// This zero describes the owned black image, not an invented hardware brightness reading.
    func showBlackScreen(displayID: CGDirectDisplayID, onFailure: @escaping () -> Void) -> Bool {
        submit(image: 1, filled: 0, displayID: displayID, onFailure: onFailure)
    }

    private func submit(image: Int64, filled: UInt32, displayID: CGDirectDisplayID,
                        onFailure: @escaping () -> Void) -> Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        // Tahoe and its successor retain the classic OSD helper but changed OSDManager routing.
        if version == 26 || version == 27 {
            guard let helper = helper(onFailure: onFailure) else { return false }
            helper.showImage(image, onDisplayID: displayID, priority: 500, msecUntilFade: 1000,
                             filledChiclets: filled, totalChiclets: 100, locked: false)
            return true
        }
        return showUsingManager(image: image, filled: filled, displayID: displayID)
    }

    func invalidate() {
        guard let connection else { return }
        reset(connection)
    }

    private func helper(onFailure: @escaping () -> Void) -> LineupOSDHelper? {
        let connection: NSXPCConnection
        if let existing = self.connection {
            connection = existing
        } else {
            connection = NSXPCConnection(machServiceName: "com.apple.OSDUIHelper", options: [])
            connection.remoteObjectInterface = NSXPCInterface(with: LineupOSDHelper.self)
            connection.interruptionHandler = { [weak self, weak connection] in
                DispatchQueue.main.async {
                    guard let self, let connection else { return }
                    self.reset(connection)
                }
            }
            connection.invalidationHandler = { [weak self, weak connection] in
                DispatchQueue.main.async {
                    guard let self, let connection, self.connection === connection else { return }
                    self.connection = nil
                }
            }
            self.connection = connection
            connection.resume()
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self, weak connection] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if let connection { self.reset(connection) }
                onFailure()
            }
        }
        guard let helper = proxy as? LineupOSDHelper else {
            reset(connection)
            return nil
        }
        return helper
    }

    private func reset(_ connection: NSXPCConnection) {
        guard self.connection === connection else { return }
        self.connection = nil
        connection.interruptionHandler = nil
        connection.invalidationHandler = nil
        connection.invalidate()
    }

    private func showUsingManager(image: Int64, filled: UInt32,
                                  displayID: CGDirectDisplayID) -> Bool {
        if !triedFramework {
            triedFramework = true
            framework = dlopen("/System/Library/PrivateFrameworks/OSD.framework/OSD", RTLD_LAZY | RTLD_LOCAL)
        }
        guard framework != nil, let managerClass = NSClassFromString("OSDManager"),
              let shared = class_getClassMethod(managerClass, NSSelectorFromString("sharedManager")),
              method_getNumberOfArguments(shared) == 2,
              returns(shared, type: "@") else { return false }
        typealias Shared = @convention(c) (AnyClass, Selector) -> AnyObject?
        let getShared = unsafeBitCast(method_getImplementation(shared), to: Shared.self)
        guard let manager = getShared(managerClass, NSSelectorFromString("sharedManager")) else { return false }
        let selector = NSSelectorFromString("showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:")
        guard let method = class_getInstanceMethod(managerClass, selector),
              method_getNumberOfArguments(method) == 9,
              returns(method, type: "v") else { return false }
        // Do not call an IMP whose argument ABI has changed on a future macOS release.
        let expected = ["q", "I", "I", "I", "I", "I", "B"]
        for (index, type) in expected.enumerated() {
            guard let argument = method_copyArgumentType(method, UInt32(index + 2)) else { return false }
            let actual = String(cString: argument)
            free(argument)
            guard actual == type || (type == "B" && actual == "c") else { return false }
        }
        typealias Show = @convention(c) (AnyObject, Selector, Int64, UInt32, UInt32, UInt32, UInt32, UInt32, Bool) -> Void
        let show = unsafeBitCast(method_getImplementation(method), to: Show.self)
        show(manager, selector, image, displayID, 500, 1000, filled, 100, false)
        return true
    }

    private func returns(_ method: Method, type: String) -> Bool {
        let result = method_copyReturnType(method)
        defer { free(result) }
        return String(cString: result) == type
    }
}
