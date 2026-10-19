//
//  PacketTunnelProvider.swift
//  packet-tunnel
//
//  Created by devonly on 2025/08/11.
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import AutomationCore
import Mudmouth
import MudmouthHTTPHooks
import NetworkExtension
import SwiftyLogger

class PacketTunnelProvider: NEPacketTunnelProvider {
    private var consentMonitor: Timer?
    private var authorizationMonitor: TunnelAuthorizationMonitor?

    /// どういうときに呼ばれるの、これ
    /// NOTE: startVPNTunnelが実行されたときのオプションがここで渡される
    /// - Parameter options: <#options description#>
    override func startTunnel(options: [String: NSObject]? = nil) async throws {
        try CaptureAuthorization.requireConsent()
        // Fail closed before routing anything if the target list is missing or invalid.
        let hosts = try CaptureHostList.decodeTargets(from: options).map(\.host)
        guard let activationURL = AutomationSharedConfiguration.activationURL() else { throw AutomationError.corruptStore }
        let activationStore = PluginActivationStore(fileURL: activationURL)
        // A corrupt grant file disables plugin processing. It is preserved for user recovery.
        let activation = try? await activationStore.snapshot()
        let processor = activation.flatMap { $0.revisions.isEmpty ? nil : HTTPPluginProcessor(store: activationStore, snapshot: $0) }
        try await MITM.startTunnel(options: options, pluginProcessor: processor)
        do {
            try CaptureAuthorization.requireConsent()
            try await setTunnelNetworkSettings(CaptureHostList.tunnelSettings(hosts: hosts))
            try CaptureAuthorization.requireConsent()
        } catch {
            await MITM.stopTunnel()
            try? await setTunnelNetworkSettings(nil)
            throw error
        }
        let monitorID = UUID()
        await MainActor.run {
            consentMonitor?.invalidate()
            authorizationMonitor = TunnelAuthorizationMonitor(admitted: activation, id: monitorID)
            consentMonitor = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, var monitor = self.authorizationMonitor else { return }
                    let admission = monitor.begin(id: monitorID, consent: CaptureAuthorization.isGranted)
                    self.authorizationMonitor = monitor
                    if case let .stop(reason) = admission {
                        await self.stopForAuthorizationChange(reason, id: monitorID)
                        return
                    }
                    guard admission == .proceed else { return }
                    let current = try? await activationStore.snapshot()
                    guard var latest = self.authorizationMonitor else { return }
                    let decision = latest.finish(current: current, consent: CaptureAuthorization.isGranted, id: monitorID)
                    self.authorizationMonitor = latest
                    guard case let .stop(reason) = decision else { return }
                    await self.stopForAuthorizationChange(reason, id: monitorID)
                }
            }
        }
    }

    @MainActor
    private func stopForAuthorizationChange(_ reason: TunnelAuthorizationMonitor.StopReason, id: UUID) async {
        guard authorizationMonitor?.id == id else { return }
        authorizationMonitor = nil
        consentMonitor?.invalidate()
        consentMonitor = nil
        await MITM.stopTunnel()
        cancelTunnelWithError(reason)
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        await MainActor.run {
            authorizationMonitor = nil
            consentMonitor?.invalidate(); consentMonitor = nil
        }
        await MITM.stopTunnel()
    }
}
