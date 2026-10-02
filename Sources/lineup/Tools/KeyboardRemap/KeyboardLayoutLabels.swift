import Carbon
import Combine
import Foundation
import KeyboardRemapCore

/// Carbon translates the selected layout for presentation; mappings remain HID usages.
@MainActor
final class KeyboardLayoutLabels: ObservableObject {
    struct Layout: Identifiable {
        let id: String
        let name: String
        let source: TISInputSource
    }

    @Published private(set) var layouts: [Layout] = []
    @Published private(set) var currentName = "Current input source"
    private var current: TISInputSource?

    init() { refresh() }

    func refresh() {
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout] as CFDictionary
        let sources = TISCreateInputSourceList(filter, false).takeRetainedValue() as! [TISInputSource]
        layouts = sources.compactMap { source in
            guard let id = stringProperty(source, kTISPropertyInputSourceID),
                  let name = stringProperty(source, kTISPropertyLocalizedName) else { return nil }
            return Layout(id: id, name: name, source: source)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        current = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        if let current { currentName = stringProperty(current, kTISPropertyLocalizedName) ?? "Current input source" }
    }

    func name(for id: String?) -> String {
        guard let id else { return currentName }
        return layouts.first { $0.id == id }?.name ?? "Unavailable layout"
    }

    func label(for usage: UInt64, inputSourceID: String?) -> String {
        guard let key = PhysicalKey.key(for: usage) else {
            return "Unknown key [0x\(String(usage, radix: 16).uppercased())]"
        }
        let physical = key.name.replacingOccurrences(of: " position", with: "")
        guard let symbols = translatedSymbols(for: usage, inputSourceID: inputSourceID) else { return physical }
        // Keep the physical name when a different layout changes what is printed at this position.
        if symbols.plain.localizedCaseInsensitiveCompare(physical) == .orderedSame { return symbols.label }
        return "\(symbols.label) · \(physical)"
    }

    func symbols(for usage: UInt64, inputSourceID: String?) -> String? {
        translatedSymbols(for: usage, inputSourceID: inputSourceID)?.label
    }

    private func translatedSymbols(for usage: UInt64, inputSourceID: String?) -> (plain: String, label: String)? {
        guard let key = PhysicalKey.key(for: usage) else { return nil }
        let source = inputSourceID.flatMap { id in layouts.first { $0.id == id }?.source } ?? (inputSourceID == nil ? current : nil)
        guard let source, let virtualKey = key.virtualKeyCode,
              let plain = symbol(source: source, keyCode: virtualKey, shifted: false) else { return nil }
        let shifted = symbol(source: source, keyCode: virtualKey, shifted: true)
        return (plain, shifted.flatMap { $0 != plain ? "\(plain) / \($0)" : nil } ?? plain)
    }

    private func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private func symbol(source: TISInputSource, keyCode: UInt16, shifted: Bool) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKey: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay),
                                    shifted ? UInt32(shiftKey >> 8) : 0, UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKey,
                                    characters.count, &length, &characters)
        guard status == noErr, length > 0 else { return nil }
        let result = String(utf16CodeUnits: characters, count: length)
        guard !result.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return result == " " ? "Space" : result
    }
}
