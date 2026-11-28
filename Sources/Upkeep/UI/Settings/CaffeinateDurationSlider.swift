import SwiftUI

struct CaffeinateDurationSlider: NSViewRepresentable {
    let minutes: Int
    let onCommit: (Int) -> Void

    func makeNSView(context: Context) -> CaffeinateDurationControl {
        CaffeinateDurationControl(showsDisclosure: false, currentMinutes: { 0 }, onCommit: onCommit)
    }

    func updateNSView(_ view: CaffeinateDurationControl, context: Context) {
        view.onCommit = onCommit
        view.setSettingsMinutes(minutes)
    }
}
