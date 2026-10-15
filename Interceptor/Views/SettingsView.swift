//
//  SettingsView.swift
//  Interceptor
//
//  Created by devonly on 2025/08/14.
//  Copyright © 2025 QuantumLeap. All rights reserved.
//

import LicenseList
import Mudmouth
import QuantumLeap
import SwiftUI
import SwiftUIIntrospect

struct SettingsView: View {
    @AppStorage(CaptureAuthorization.key, store: CaptureAuthorization.defaults) private var consentVersion = 0
    @State private var showSetup = false
    @State private var showGuide = false

    var body: some View {
        Form(content: {
            QuantumLeap.Support()
                .environment(\.isFirstLaunch, $showGuide)
            Section {
                Button("Capture Setup") { showSetup = true }
                    .disabled(consentVersion != CaptureAuthorization.version)
                    .foregroundStyle(.primary)
            }
            QuantumLeap.VPNSettingList()
            QuantumLeap.Tools()
            Section {
                NavigationLink("Data Use & Consent") { DataUseDetailsView(showsWithdrawal: true) }
                Link("Terms of Service", destination: URL(string: "https://qleap.jp/term/eula")!)
                    .foregroundStyle(.primary)
                Link("Privacy Policy", destination: URL(string: "https://qleap.jp/term/interceptor_privacy_policy")!)
                    .foregroundStyle(.primary)
                Link("Developers", destination: URL(string: "https://qleap.jp")!)
                    .foregroundStyle(.primary)
                NavigationLink("Licenses") {
                    LicenseListView().licenseViewStyle(InlineRepositoryLicenseViewStyle())
                        .navigationTitle("Licenses")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
            QuantumLeap.Version()
        })
        .sheet(isPresented: $showSetup) {
            FirstLaunchView(flow: .captureSetup)
                .presentationDetents([.large])
                .modifier(CaptureSetupSheetSizing())
        }
        .sheet(isPresented: $showGuide) {
            HowToUseView()
        }
        .navigationTitle(Text("TITLE_SETTINGS"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private final class SetupPresentationReference {
    weak var controller: UIPresentationController?
    var didResize = false
}

@available(iOS 18, *)
private struct CaptureSetupPresentationSizing: PresentationSizing {
    /// Size computed by Introspect from the current window; `nil` keeps the native form sizing.
    let requestedSize: CGSize?

    func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
        guard let requestedSize else {
            return FormPresentationSizing.form.proposedSize(for: root, context: context)
        }
        return ProposedViewSize(width: requestedSize.width, height: requestedSize.height)
    }
}

private struct CaptureSetupSheetSizing: ViewModifier {
    @State private var presentation = SetupPresentationReference()
    @State private var requestedSize: CGSize?

    func body(content: Content) -> some View {
        sizedPresentation(content)
            .background {
                GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.size) {
                        if let controller = presentation.controller {
                            resize(controller)
                        }
                    }
                }
            }
            .introspect(.sheet, on: .iOS(.v17, .v18, .v26, .v27)) { (controller: UIPresentationController) in
                if presentation.controller !== controller {
                    presentation.didResize = false
                }
                presentation.controller = controller
                resize(controller)
            }
    }

    @ViewBuilder
    private func sizedPresentation(_ content: Content) -> some View {
        if #available(iOS 18, *) {
            content.presentationSizing(CaptureSetupPresentationSizing(requestedSize: requestedSize))
        } else {
            content
        }
    }

    /// Queued on main so state never changes during the Introspect/layout pass; a closed or replaced sheet is ignored.
    private func request(_ size: CGSize?, for controller: UIPresentationController) {
        guard requestedSize != size else { return }
        DispatchQueue.main.async { [weak controller] in
            guard let controller, presentation.controller === controller else { return }
            let currentSize = targetSize(for: controller)
            guard requestedSize != currentSize else { return }
            requestedSize = currentSize
        }
    }

    private func targetSize(for controller: UIPresentationController) -> CGSize? {
        let window = controller.presentingViewController.view.window
        let sizeClass = window?.traitCollection.horizontalSizeClass ?? controller.traitCollection.horizontalSizeClass
        let bounds = window?.bounds ?? controller.containerView?.bounds ?? .zero
        guard sizeClass == .regular, bounds.width > 48, bounds.height > 80 else { return nil }
        return CGSize(width: min(620, bounds.width - 48), height: min(900, bounds.height - 80))
    }

    private func resize(_ controller: UIPresentationController) {
        let identifier = UISheetPresentationController.Detent.Identifier("captureSetup")
        let window = controller.presentingViewController.view.window
        // An iPad form sheet can itself be compact even in a regular-width window.
        let sizeClass = window?.traitCollection.horizontalSizeClass
            ?? controller.traitCollection.horizontalSizeClass
        guard sizeClass == .regular else {
            request(nil, for: controller)
            if #available(iOS 18, *) {
                return
            }
            if presentation.didResize {
                controller.presentedViewController.preferredContentSize = .zero
                if let sheet = controller as? UISheetPresentationController,
                   sheet.detents.map(\.identifier) == [identifier]
                {
                    sheet.detents = [.large()]
                }
                presentation.didResize = false
            }
            return
        }
        guard let size = targetSize(for: controller) else {
            request(nil, for: controller)
            return
        }
        request(size, for: controller)
        // SwiftUI owns the presentation size on modern iOS. UIKit writes here would
        // compete with its layout; Introspect still supplies the window-based target.
        if #available(iOS 18, *) {
            return
        }
        if controller.presentedViewController.preferredContentSize != size {
            controller.presentedViewController.preferredContentSize = size
        }
        presentation.didResize = true
        if let sheet = controller as? UISheetPresentationController,
           sheet.detents.map(\.identifier) != [identifier]
        {
            sheet.detents = [.custom(identifier: identifier) { context in
                min(900, context.maximumDetentValue)
            }]
        }
    }
}

#Preview {
    ContentView()
        .environmentIsFirstLaunch()
        .environmentObject(Tuberose.default)
}

private struct InlineRepositoryLicenseViewStyle: LicenseViewStyle {
    @MainActor
    func makeBody(configuration: Configuration) -> some View {
        WithRepositoryAnchorLinkLicenseViewStyle()
            .makeBody(configuration: configuration)
            .navigationBarTitleDisplayMode(.inline)
    }
}
