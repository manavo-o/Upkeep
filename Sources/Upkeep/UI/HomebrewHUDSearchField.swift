import AppKit

/// Configure the editor before AppKit makes it first responder. Editing notifications
/// arrive after activation, when text assistance services may already have connected.
@MainActor
final class HomebrewHUDSearchField: NSSearchField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = HomebrewHUDSearchFieldCell(textCell: "")
        isEditable = true
        isSelectable = true
        usesSingleLineMode = true
        cell?.isScrollable = true
        cell?.wraps = false
        contentType = nil
        isAutomaticTextCompletionEnabled = false
        if #available(macOS 15.2, *) {
            allowsWritingTools = false
        }
        if #available(macOS 15.4, *) {
            allowsWritingToolsAffordance = false
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private final class HomebrewHUDSearchFieldCell: NSSearchFieldCell {
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        guard let textView = editor as? NSTextView else { return editor }
        textView.contentType = nil
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.inlinePredictionType = .no
        textView.mathExpressionCompletionType = .no
        textView.writingToolsBehavior = .none
        return editor
    }
}
