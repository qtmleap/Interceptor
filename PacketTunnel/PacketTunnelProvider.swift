//
//  PacketTunnelProvider.swift
//  packet-tunnel
//
//  Created by devonly on 2025/08/11.
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import Mudmouth
import NetworkExtension
import SwiftyLogger

class PacketTunnelProvider: NEPacketTunnelProvider {
    private var consentMonitor: Timer?

    /// どういうときに呼ばれるの、これ
    /// NOTE: startVPNTunnelが実行されたときのオプションがここで渡される
    /// - Parameter options: <#options description#>
    override func startTunnel(options: [String: NSObject]? = nil) async throws {
        try CaptureAuthorization.requireConsent()
        // Fail closed before routing anything if the target list is missing or invalid.
        let hosts = try CaptureHostList.decodeTargets(from: options).map(\.host)
        try await MITM.startTunnel(options: options)
        do {
            try CaptureAuthorization.requireConsent()
            try await setTunnelNetworkSettings(CaptureHostList.tunnelSettings(hosts: hosts))
            try CaptureAuthorization.requireConsent()
        } catch {
            await MITM.stopTunnel()
            try? await setTunnelNetworkSettings(nil)
            throw error
        }
        await MainActor.run {
            consentMonitor = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard !CaptureAuthorization.isGranted else { return }
                self?.consentMonitor?.invalidate()
                self?.consentMonitor = nil
                Task {
                    await MITM.stopTunnel()
                    self?.cancelTunnelWithError(CaptureAuthorization.Failure.consentRequired)
                }
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        await MainActor.run { consentMonitor?.invalidate(); consentMonitor = nil }
        await MITM.stopTunnel()
    }
}
