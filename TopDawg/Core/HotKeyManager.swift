import Carbon.HIToolbox
import Foundation

/// Global keyboard hotkey via Carbon's RegisterEventHotKey.
/// Works in sandboxed apps — no Input Monitoring permission required.
final class HotKeyManager {

    private var hotKeyRef:     EventHotKeyRef?
    private var eventHandler:  EventHandlerRef?
    private var contextPtr:    UnsafeMutableRawPointer?

    /// - Parameters:
    ///   - keyCode: Carbon virtual key code (e.g. kVK_ANSI_C = 8, kVK_Space = 49)
    ///   - modifiers: Carbon modifiers (controlKey=4096, optionKey=2048, cmdKey=256, shiftKey=512)
    ///   - onPress: Called on the main thread when the hotkey fires
    init(keyCode: UInt32, modifiers: UInt32, onPress: @escaping () -> Void) {
        // Wrap callback in a heap object so C code can reference it via raw pointer
        let ctx = HotKeyContext(onPress)
        let ptr = Unmanaged.passRetained(ctx).toOpaque()
        contextPtr = ptr

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x434E4F54)  // 'CNOT'
        hotKeyID.id = UInt32(1)

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind:  OSType(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, _, userData) -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                // takeUnretainedValue: doesn't consume the retained count (contextPtr holds it)
                let ctx = Unmanaged<HotKeyContext>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { ctx.onPress() }
                return noErr
            },
            1, &spec, ptr, &eventHandler
        )

        RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let r = hotKeyRef   { UnregisterEventHotKey(r) }
        if let h = eventHandler { RemoveEventHandler(h) }
        if let p = contextPtr  { Unmanaged<HotKeyContext>.fromOpaque(p).release() }
    }
}

private final class HotKeyContext {
    let onPress: () -> Void
    init(_ onPress: @escaping () -> Void) { self.onPress = onPress }
}
