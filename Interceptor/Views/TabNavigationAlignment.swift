import SwiftUI
import UIKit

/// Removes the extra top inset applied to a tab's split navigation on iPadOS 27.
/// The tab controller keeps ownership of the floating tabs and their position.
@MainActor
final class TabNavigationAlignment: ObservableObject {
    @MainActor
    private final class Insets {
        weak var controller: UIViewController?
        var originalTop: CGFloat
        var lastWritten: CGFloat?

        init(_ controller: UIViewController) {
            self.controller = controller
            originalTop = controller.additionalSafeAreaInsets.top
        }
    }

    private weak var tabView: UITabBarController?
    private var insets: [ObjectIdentifier: Insets] = [:]
    private final class Observation {
        weak var view: AlignmentObservationView?
        init(_ view: AlignmentObservationView) { self.view = view }
    }

    private var observations: [Observation] = []
    private var updating = false
    private var waitingForTransition = false

    func configure(_ controller: UITabBarController) {
        if tabView !== controller {
            restore()
            tabView = controller
        }
        update()
    }

    func observe(_ view: AlignmentObservationView) {
        observations.removeAll { $0.view == nil }
        observations.append(Observation(view))
        update(from: view)
    }

    func update() {
        for observation in observations {
            if let view = observation.view { update(from: view) }
        }
    }

    func update(from observer: AlignmentObservationView) {
        guard #available(iOS 27, *) else { return }
        guard !updating else { observer.setNeedsLayout(); return }
        guard let tabView, let window = tabView.viewIfLoaded?.window else { return }
        updating = true
        defer { updating = false }

        let tolerance = 0.5 / window.screen.scale
        insets = insets.filter { $0.value.controller != nil }
        guard tabView.traitCollection.userInterfaceIdiom == .pad,
              tabView.traitCollection.horizontalSizeClass == .regular,
              !tabView.isTabBarHidden
        else {
            restore(tolerance: tolerance)
            return
        }

        if let transition = tabView.transitionCoordinator, transition.isAnimated {
            if !waitingForTransition {
                waitingForTransition = true
                transition.animate(alongsideTransition: nil) { [weak self] _ in
                    self?.waitingForTransition = false
                    self?.update()
                }
            }
            return
        }

        guard let child = tabView.selectedViewController ?? tabView.selectedTab?.viewController,
              let view = child.viewIfLoaded, view.window === window,
              !view.bounds.isEmpty, observer.window === window,
              observer.isDescendant(of: view)
        else { return }
        observer.boundController = child

        // Detached tabs can report a zero safe area. Never calculate from them.
        for state in insets.values where state.controller !== child {
            restore(state, tolerance: tolerance)
        }
        let key = ObjectIdentifier(child)
        let state = insets[key] ?? Insets(child)
        insets[key] = state
        let current = child.additionalSafeAreaInsets.top
        if state.lastWritten == nil {
            state.originalTop = current
        } else if let written = state.lastWritten, abs(current - written) > tolerance {
            // Respect another owner changing this inset, including UIKit resets.
            state.originalTop = current
            state.lastWritten = nil
        }

        let inheritedTop = view.safeAreaInsets.top - current
        let extraTop = max(0, inheritedTop - window.safeAreaInsets.top)
        let top = state.originalTop - extraTop
        guard abs(current - top) > tolerance else { return }
        state.lastWritten = top
        var adjusted = child.additionalSafeAreaInsets
        adjusted.top = top
        child.additionalSafeAreaInsets = adjusted
    }

    func restore() {
        restore(tolerance: 0)
    }

    func detach(_ view: AlignmentObservationView) {
        if let child = view.boundController, let state = insets[ObjectIdentifier(child)] {
            restore(state, tolerance: 0)
        }
        view.boundController = nil
    }

    private func restore(tolerance: CGFloat) {
        for state in insets.values { restore(state, tolerance: tolerance) }
    }

    private func restore(_ state: Insets, tolerance: CGFloat) {
        guard let child = state.controller, let written = state.lastWritten else { return }
        if abs(child.additionalSafeAreaInsets.top - written) <= tolerance {
            var restored = child.additionalSafeAreaInsets
            restored.top = state.originalTop
            state.lastWritten = nil
            child.additionalSafeAreaInsets = restored
        } else {
            state.originalTop = child.additionalSafeAreaInsets.top
            state.lastWritten = nil
        }
    }
}

struct TabNavigationAlignmentObserver: UIViewRepresentable {
    let alignment: TabNavigationAlignment

    func makeCoordinator() -> TabNavigationAlignment { alignment }

    func makeUIView(context: Context) -> AlignmentObservationView {
        let view = AlignmentObservationView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.onUpdate = { [weak alignment, weak view] in
            if let view { alignment?.update(from: view) }
        }
        view.onDetach = { [weak alignment, weak view] in
            if let view { alignment?.detach(view) }
        }
        view.registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitUserInterfaceIdiom.self]) {
            (view: AlignmentObservationView, _: UITraitCollection) in view.onUpdate?()
        }
        alignment.observe(view)
        return view
    }

    func updateUIView(_ view: AlignmentObservationView, context: Context) {
        alignment.update(from: view)
    }

    static func dismantleUIView(_ view: AlignmentObservationView, coordinator: TabNavigationAlignment) {
        view.onUpdate = nil
        view.onDetach = nil
        coordinator.detach(view)
    }
}

final class AlignmentObservationView: UIView {
    weak var boundController: UIViewController?
    var onUpdate: (() -> Void)?
    var onDetach: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { onDetach?() } else { onUpdate?() }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        onUpdate?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onUpdate?()
    }
}
