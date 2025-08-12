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
  /// どういうときに呼ばれるの、これ
  /// NOTE: startVPNTunnelが実行されたときのオプションがここで渡される
  /// - Parameter options: <#options description#>
  override func startTunnel(options: [String: NSObject]? = nil) async throws {
    NSLog("Starting tunnel with options: \(String(describing: options))")
    SwiftyLogger.debug("Starting tunnel with options: \(String(describing: options))")
    try await setTunnelNetworkSettings(settings)
    try await MITM.startTunnel(options: options)
  }
  
  /// スプラトゥーン3のトークンを取得するためだけの設定
  /// NOTE: この設定は、スプラトゥーン3のトークン取得に必要なプロキシ設定を含んでいます
  /// NOTE: 他のデータも取ってきたい場合にはここを変更する必要がある
  let settings: NETunnelNetworkSettings = {
    NSLog("Creating tunnel network settings")
    let url: URL = .init(string: "https://api.lp1.av5ja.srv.nintendo.net/api/bullet_tokens")!
    let proxySettings: NEProxySettings = .init()
    proxySettings.httpsServer = NEProxyServer(address: "127.0.0.1", port: 6_836)
    proxySettings.httpsEnabled = true
    // ここのドメインでしかプロクシを実行しないようにする(ということはURL自体はあまり関係ない)
    // swiftlint:disable:next force_unwrapping
    proxySettings.matchDomains = [url.host!]
    let ipv4Settings = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.0"])
    let networkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    networkSettings.mtu = 1_500
    networkSettings.proxySettings = proxySettings
    networkSettings.ipv4Settings = ipv4Settings
    return networkSettings
  }()
}
