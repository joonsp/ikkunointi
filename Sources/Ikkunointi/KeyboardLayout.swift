import Carbon
import Foundation
import IkkunointiCore

/// Resolves characters to key codes through the active keyboard layout (so `W` means the
/// key that types "w" on Dvorak too) and renders key codes back into labels.
final class KeyboardLayout {
    static let shared = KeyboardLayout()

    private var charToCode: [Character: UInt16] = [:]
    private var codeToLabel: [UInt16: String] = [:]

    init() { reload() }

    /// Call on the main thread (Text Input Sources requirement).
    func reload() {
        charToCode.removeAll()
        codeToLabel.removeAll()
        guard let data = Self.layoutData() else { return }
        for code in UInt16(0)..<128 {
            guard let s = Self.translate(code, data), !s.isEmpty else { continue }
            codeToLabel[code] = s
            if s.count == 1, let c = s.lowercased().first, charToCode[c] == nil { charToCode[c] = code }
        }
    }

    func keyCode(for character: Character) -> UInt16? {
        let c = Character(String(character).lowercased())
        return charToCode[c] ?? KeyNames.ansi[c]
    }

    func resolve(_ spec: KeySpec) -> UInt16? {
        switch spec {
        case .code(let c): return c
        case .character(let ch): return keyCode(for: ch)
        }
    }

    /// What the key shows on this layout: "W", "↩", "+" (Finnish key right of 0), ...
    func label(for code: UInt16) -> String {
        if let s = KeyNames.symbols[code] { return s }
        if let s = codeToLabel[code], let first = s.first, !first.isWhitespace, first.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) {
            return s.uppercased()
        }
        return "code:\(code)"
    }

    private static func layoutData() -> Data? {
        let sources = [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()]
        for case let source? in sources {
            let s = source.takeRetainedValue()
            guard let ptr = TISGetInputSourceProperty(s, kTISPropertyUnicodeKeyLayoutData) else { continue }
            return Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        }
        return nil
    }

    private static func translate(_ code: UInt16, _ data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}

extension Modifiers {
    func symbols(superKey: SuperKey) -> String {
        var s = ""
        if contains(.superKey) { s += superKey.symbol }
        if contains(.ctrl) { s += "⌃" }
        if contains(.alt) { s += "⌥" }
        if contains(.cmd) { s += "⌘" }
        if contains(.shift) { s += "⇧" }
        return s
    }
}
