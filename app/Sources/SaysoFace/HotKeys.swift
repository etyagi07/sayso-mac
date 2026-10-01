import Carbon
import Foundation

/// Global hotkeys via Carbon: no Accessibility permission needed. A key is
/// only captured while it is registered, so `y`, `p` and `esc` reach every
/// other app except while a confirm card is open.
enum HotKey: UInt32, CaseIterable {
    case talk = 1, send, price, cancel, pick1, pick2, pick3

    static let picks: [HotKey] = [.pick1, .pick2, .pick3]

    var keyCode: UInt32 {
        switch self {
        case .talk:   return UInt32(kVK_Space)
        case .send:   return UInt32(kVK_ANSI_Y)
        case .price:  return UInt32(kVK_ANSI_P)
        case .cancel: return UInt32(kVK_Escape)
        case .pick1:  return UInt32(kVK_ANSI_1)
        case .pick2:  return UInt32(kVK_ANSI_2)
        case .pick3:  return UInt32(kVK_ANSI_3)
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .talk: return TalkKey.current.modifiers           // ⌃⌥Space unless changed
        default:    return 0
        }
    }
}

final class HotKeys {
    static let shared = HotKeys()

    private var refs: [HotKey: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var installed = false

    private func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let key = id.id
            DispatchQueue.main.async { HotKeys.shared.actions[key]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// False if the chord couldn't be registered (another app holds it).
    @discardableResult
    func register(_ key: HotKey, action: @escaping () -> Void) -> Bool {
        install()
        actions[key.rawValue] = action
        guard refs[key] == nil else { return true }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x5341_5953), id: key.rawValue)   // 'SAYS'
        if RegisterEventHotKey(key.keyCode, key.modifiers, id,
                               GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs[key] = ref
            return true
        }
        return false
    }

    func unregister(_ key: HotKey) {
        if let ref = refs.removeValue(forKey: key) { UnregisterEventHotKey(ref) }
        actions[key.rawValue] = nil
    }
}

/// The push-to-talk chord. ⌃⌥Space by default; macOS can claim it for
/// switching input sources, so two others are offered.
enum TalkKey: Int, CaseIterable {
    case controlOptionSpace, controlShiftSpace, controlOptionCommandSpace

    static let defaultsKey = "sayso.talkKey"

    static var current: TalkKey {
        get { TalkKey(rawValue: UserDefaults.standard.integer(forKey: defaultsKey)) ?? .controlOptionSpace }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var label: String {
        switch self {
        case .controlOptionSpace: return "⌃⌥Space"
        case .controlShiftSpace: return "⌃⇧Space"
        case .controlOptionCommandSpace: return "⌃⌥⌘Space"
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .controlOptionSpace: return UInt32(controlKey | optionKey)
        case .controlShiftSpace: return UInt32(controlKey | shiftKey)
        case .controlOptionCommandSpace: return UInt32(controlKey | optionKey | cmdKey)
        }
    }
}
