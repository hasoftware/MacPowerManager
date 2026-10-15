import AppKit
import SwiftUI

/// Báo cửa sổ chứa view này có đang thực sự hiển thị không: không bị che hoàn toàn, không thu nhỏ, đang ở Space
/// hiện tại (`NSWindow.occlusionState`). Dùng để dừng đo khi không ai nhìn.
struct WindowVisibilityReporter: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ReporterView {
        let view = ReporterView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReporterView, context: Context) {
        view.onChange = onChange
    }

    final class ReporterView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var lastReported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else {
                report(false)
                return
            }
            let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification,
                                              NSWindow.didMiniaturizeNotification,
                                              NSWindow.didDeminiaturizeNotification,
                                              NSWindow.willCloseNotification]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] note in
                    MainActor.assumeIsolated {
                        self?.evaluate(closing: note.name == NSWindow.willCloseNotification)
                    }
                })
            }
            evaluate(closing: false)
        }

        private func evaluate(closing: Bool) {
            guard let window, !closing else { return report(false) }
            report(window.occlusionState.contains(.visible) && !window.isMiniaturized)
        }

        private func report(_ visible: Bool) {
            guard visible != lastReported else { return }
            lastReported = visible
            onChange?(visible)
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
