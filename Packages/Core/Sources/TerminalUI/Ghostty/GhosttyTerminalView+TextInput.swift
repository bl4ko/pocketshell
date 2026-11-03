#if os(iOS)
    import UIKit

    final class DocumentPosition: UITextPosition {
        let offset: Int

        init(_ offset: Int) {
            self.offset = offset
        }
    }

    final class DocumentRange: UITextRange {
        let range: Range<Int>

        init(_ range: Range<Int>) {
            self.range = range
        }

        override var start: UITextPosition { DocumentPosition(range.lowerBound) }
        override var end: UITextPosition { DocumentPosition(range.upperBound) }
        override var isEmpty: Bool { range.isEmpty }
    }

    extension GhosttyTerminalView: UITextInput {
        var autocorrectionType: UITextAutocorrectionType {
            get { .no }
            set {}
        }
        var autocapitalizationType: UITextAutocapitalizationType {
            get { .none }
            set {}
        }
        var spellCheckingType: UITextSpellCheckingType {
            get { .no }
            set {}
        }
        var smartQuotesType: UITextSmartQuotesType {
            get { .no }
            set {}
        }
        var smartDashesType: UITextSmartDashesType {
            get { .no }
            set {}
        }
        var smartInsertDeleteType: UITextSmartInsertDeleteType {
            get { .no }
            set {}
        }
        var keyboardType: UIKeyboardType {
            get { .asciiCapable }
            set {}
        }
        var keyboardAppearance: UIKeyboardAppearance {
            get { .default }
            set {}
        }
        var returnKeyType: UIReturnKeyType {
            get { .default }
            set {}
        }
        @available(iOS 17.0, *)
        var inlinePredictionType: UITextInlinePredictionType {
            get { .no }
            set {}
        }

        var hasText: Bool { true }

        func insertText(_ text: String) {
            let wasMarked = document.markedRange != nil
            emit(edit { $0.insert(text) }, newlines: true)
            if wasMarked { notifyMarked() }
        }

        func deleteBackward() {
            let wasMarked = document.markedRange != nil
            emit(edit { $0.deleteBackward() }, newlines: false)
            if wasMarked { notifyMarked() }
        }

        private func edit(_ change: (inout TextInputDocument) -> [TextInputDocument.Output])
            -> [TextInputDocument.Output]
        {
            textInputDelegate?.selectionWillChange(self)
            textInputDelegate?.textWillChange(self)
            let output = change(&document)
            textInputDelegate?.textDidChange(self)
            textInputDelegate?.selectionDidChange(self)
            return output
        }

        private func emit(_ output: [TextInputDocument.Output], newlines: Bool) {
            for item in output {
                switch item {
                case .backspaces(let count):
                    send(Data(repeating: 0x7f, count: count))
                case .text(let text):
                    let normalized = newlines ? text.replacingOccurrences(of: "\n", with: "\r") : text
                    send(Data(normalized.utf8))
                }
            }
        }

        private func notifyMarked() {
            guard let marked = document.markedRange, let text = document.markedText, !text.isEmpty else {
                markedTextObserver?("", NSRange(location: 0, length: 0))
                return
            }
            let start = max(0, document.selected.lowerBound - marked.lowerBound)
            let length = max(0, min(document.selected.upperBound, marked.upperBound) - document.selected.lowerBound)
            markedTextObserver?(text, NSRange(location: start, length: length))
        }

        func text(in range: UITextRange) -> String? {
            guard let range = range as? DocumentRange else { return nil }
            return document.substring(range.range)
        }

        func replace(_ range: UITextRange, withText text: String) {
            guard let range = range as? DocumentRange, document.markedRange == nil else { return }
            emit(edit { $0.replace(range.range, with: text) }, newlines: true)
        }

        var selectedTextRange: UITextRange? {
            get { DocumentRange(document.selected) }
            set {
                guard let range = newValue as? DocumentRange else { return }
                document.select(range.range)
            }
        }

        var markedTextRange: UITextRange? {
            document.markedRange.map(DocumentRange.init)
        }

        var markedTextStyle: [NSAttributedString.Key: Any]? {
            get { nil }
            set {}
        }

        func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
            _ = edit {
                $0.setMarked(markedText ?? "", selectedRange: selectedRange)
                return []
            }
            notifyMarked()
        }

        func unmarkText() {
            emit(edit { $0.unmark() }, newlines: true)
            notifyMarked()
        }

        var beginningOfDocument: UITextPosition { DocumentPosition(0) }
        var endOfDocument: UITextPosition { DocumentPosition(document.length) }

        var inputDelegate: UITextInputDelegate? {
            get { textInputDelegate }
            set { textInputDelegate = newValue }
        }

        var tokenizer: UITextInputTokenizer { UITextInputStringTokenizer(textInput: self) }

        func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
            guard let from = fromPosition as? DocumentPosition, let to = toPosition as? DocumentPosition else {
                return nil
            }
            return DocumentRange(min(from.offset, to.offset)..<max(from.offset, to.offset))
        }

        func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
            guard let position = position as? DocumentPosition else { return nil }
            let target = position.offset + offset
            guard target >= 0, target <= document.length else { return nil }
            return DocumentPosition(target)
        }

        func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int)
            -> UITextPosition?
        {
            switch direction {
            case .left, .up: self.position(from: position, offset: -offset)
            default: self.position(from: position, offset: offset)
            }
        }

        func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
            let lhs = (position as? DocumentPosition)?.offset ?? 0
            let rhs = (other as? DocumentPosition)?.offset ?? 0
            return lhs < rhs ? .orderedAscending : lhs > rhs ? .orderedDescending : .orderedSame
        }

        func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
            ((toPosition as? DocumentPosition)?.offset ?? 0) - ((from as? DocumentPosition)?.offset ?? 0)
        }

        func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
            switch direction {
            case .left, .up: range.start
            default: range.end
            }
        }

        func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection)
            -> UITextRange?
        {
            guard let position = position as? DocumentPosition else { return nil }
            switch direction {
            case .left, .up: return DocumentRange(0..<position.offset)
            default: return DocumentRange(position.offset..<document.length)
            }
        }

        func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection)
            -> NSWritingDirection
        {
            .leftToRight
        }

        func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

        func firstRect(for range: UITextRange) -> CGRect { caretFrame }

        func caretRect(for position: UITextPosition) -> CGRect { caretFrame }

        func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }

        func closestPosition(to point: CGPoint) -> UITextPosition? { DocumentPosition(document.length) }

        func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { range.end }

        func characterRange(at point: CGPoint) -> UITextRange? { nil }
    }
#endif
