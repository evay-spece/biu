import Foundation
import SwiftUI

final class TextRowSelectionInput {
    private var keyboardPointer: CGPoint?
    func useKeyboard(at pointer: CGPoint) { keyboardPointer = pointer }
    func usePointer() { keyboardPointer = nil }
    func acceptsPointer(at pointer: CGPoint) -> Bool {
        if let anchor = keyboardPointer,
           hypot(pointer.x - anchor.x, pointer.y - anchor.y) <= 1 { return false }
        keyboardPointer = nil
        return true
    }
}

struct TextRowSelectionHighlight: ViewModifier {
    let selected: Bool
    func body(content: Content) -> some View {
        content
            .background(selected ? Color.blue.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(selected ? Color.blue : .clear, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
    }
}
