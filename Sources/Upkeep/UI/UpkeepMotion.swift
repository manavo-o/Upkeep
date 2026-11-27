import AppKit
import QuartzCore
import SwiftUI

@MainActor
enum UpkeepMotion {
    static let entranceDuration = 0.14
    static let resizeDuration = 0.20
    static let paneEntrance = Animation.easeOut(duration: entranceDuration)
    static let disclosure = Animation.smooth(duration: resizeDuration, extraBounce: 0)

    static func animateAppKit(duration: TimeInterval, timing: CAMediaTimingFunctionName = .easeInEaseOut, changes: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: timing)
            changes()
        }
    }
}
