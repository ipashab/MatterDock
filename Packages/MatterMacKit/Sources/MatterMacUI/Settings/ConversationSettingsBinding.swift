import AppKit
import Observation

/// Applies the local text size, send behavior, bubble style and color scheme, window
/// theme, and the account’s server clock preference, to a conversation pane's AppKit
/// controllers, and re-applies them whenever one of those observable values changes.
/// One re-armed observation per pane.
extension ConversationController {
    func bindDisplaySettings() {
        withObservationTracking {
            applyDisplaySettings()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.bindDisplaySettings() }
        }
    }

    func applyDisplaySettings() {
        let settings = environment.settings
        if timeline.fontScale != settings.fontScale { timeline.fontScale = settings.fontScale }
        if timeline.usesBubbleStyle != settings.bubbleTimeline { timeline.usesBubbleStyle = settings.bubbleTimeline }
        if timeline.bubbleScheme != settings.bubbleScheme { timeline.bubbleScheme = settings.bubbleScheme }
        let clock = model?.accountSettings?.display.militaryTime
        if timeline.uses24HourClock != clock { timeline.uses24HourClock = clock }
        let behavior: ComposerSendBehavior = settings.sendBehavior == .returnSends ? .returnSends : .commandReturnSends
        if composer.sendBehavior != behavior { composer.sendBehavior = behavior }
        timeline.drawsThemedBackground = !settings.theme.isSystem
    }
}
