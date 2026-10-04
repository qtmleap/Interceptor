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
        try await setTunnelNetworkSettings(settings)
        try await MITM.startTunnel(options: options)
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

    /// スプラトゥーン3のトークンを取得するためだけの設定
    /// NOTE: この設定は、スプラトゥーン3のトークン取得に必要なプロキシ設定を含んでいます
    /// NOTE: 他のデータも取ってきたい場合にはここを変更する必要がある
    let settings: NETunnelNetworkSettings = {
        NSLog("Creating tunnel network settings")
        let proxySettings: NEProxySettings = .init()
        proxySettings.httpsServer = NEProxyServer(address: "127.0.0.1", port: 6_836)
        proxySettings.httpsEnabled = true
        // ここのドメインでしかプロクシを実行しないようにする(ということはURL自体はあまり関係ない)
        // 任天堂関連のドメインを列挙
        // swiftlint:disable:next force_unwrapping
        proxySettings.matchDomains = [
            URL(string: "https://api.lp1.av5ja.srv.nintendo.net")!.host!, // Splatoon 3
            URL(string: "https://app.splatoon2.nintendo.net")!.host!, // Splatoon 2
            URL(string: "https://api.lp1.87abc152.srv.nintendo.net")!.host!, // Zelda Notes
            URL(string: "https://web.sd.lp1.acbaa.srv.nintendo.net")!.host!, // NookLink
            URL(string: "https://app.smashbros.nintendo.net")!.host!, // Smash World
        ]
        let ipv4Settings = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.0"])
        let networkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        networkSettings.mtu = 1_500
        networkSettings.proxySettings = proxySettings
        networkSettings.ipv4Settings = ipv4Settings
        return networkSettings
    }()
}
