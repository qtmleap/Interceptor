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
    @MainActor private var pluginProcessor: HTTPPluginProcessor?
    #if DEBUG
    @MainActor private var outboundProbe: HTTPPluginOutboundProbe?
    #endif
    private let lifecycle = TunnelLifecycle()

    /// どういうときに呼ばれるの、これ
    /// NOTE: startVPNTunnelが実行されたときのオプションがここで渡される
    /// - Parameter options: <#options description#>
    override func startTunnel(options: [String: NSObject]? = nil) async throws {
        // Issued synchronously before any suspension so a later stop/start invalidates it at once.
        let start = lifecycle.start { [self] ticket in try await runStart(ticket: ticket, options: options) }
        try await start.task.value
    }

    private func runStart(ticket: UUID, options: [String: NSObject]?) async throws {
        var startingProcessor: HTTPPluginProcessor?
        #if DEBUG
        var startingProbe: HTTPPluginOutboundProbe?
        #endif
        do {
            try requireCurrent(ticket)
            // Previous starts and their observer callbacks finish before a new
            // global MITM instance can be installed by this serialized operation.
            await teardown(monitorID: nil)
            try requireCurrent(ticket)
            try CaptureAuthorization.requireConsent()
            // Fail closed before routing anything if the target list is missing or invalid.
            let hosts = try CaptureHostList.decodeTargets(from: options).map(\.host)
            guard let activationURL = AutomationSharedConfiguration.activationURL() else { throw AutomationError.corruptStore }
            let activationStore = PluginActivationStore(fileURL: activationURL)
            // A corrupt grant file disables plugin processing. It is preserved for user recovery.
            let activation = try? await activationStore.snapshot()
            try requireCurrent(ticket)
            let lifecycle = lifecycle
            #if DEBUG
            let probe = HTTPPluginOutboundProbe.make(options: options, snapshot: activation, activationURL: activationURL,
                                                     isCurrent: { lifecycle.isCurrent(ticket) })
            startingProbe = probe
            let observer = probe?.observer
            #else
            let observer: HTTPPluginOutboundDispatcher.Observer? = nil
            #endif
            let processor = activation.flatMap {
                $0.revisions.isEmpty ? nil : HTTPPluginProcessor(
                    store: activationStore, snapshot: $0,
                    hasCaptureConsent: { CaptureAuthorization.isGranted && lifecycle.isCurrent(ticket) },
                    outboundObserver: observer
                )
            }
            startingProcessor = processor
            // Atomic with ticket validity: stop/newer start now shuts this processor down immediately.
            let shutdown: @Sendable () -> Void = { processor?.shutdown() }
            guard lifecycle.attach(ticket, shutdown: shutdown) else { throw CancellationError() }
            let installed = await MainActor.run {
                lifecycle.installIfCurrent(ticket) {
                    pluginProcessor = processor
                    #if DEBUG
                    outboundProbe = probe
                    #endif
                }
            }
            guard installed else { throw CancellationError() }
            try await MITM.startTunnel(options: options, pluginProcessor: processor)
            try requireCurrent(ticket)
            try CaptureAuthorization.requireConsent()
            try await setTunnelNetworkSettings(CaptureHostList.tunnelSettings(hosts: hosts))
            try requireCurrent(ticket)
            try CaptureAuthorization.requireConsent()
            let monitored = await MainActor.run {
                lifecycle.installIfCurrent(ticket) {
                    installMonitor(activation: activation, store: activationStore, id: ticket)
                }
            }
            guard monitored else { throw CancellationError() }
            #if DEBUG
            // Local readiness only (never lifecycle callbacks): startup fully succeeded; replies still check isCurrent.
            startingProbe?.markReady()
            #endif
        } catch {
            // Own failed startup is cleaned before the next serialized global operation runs.
            lifecycle.invalidate(ticket)
            startingProcessor?.shutdown()
            await teardown(monitorID: nil)
            #if DEBUG
            let drained = await startingProcessor?.waitUntilStopped() ?? true
            _ = await startingProbe?.finish(drained: drained)
            #endif
            try? await setTunnelNetworkSettings(nil)
            throw error
        }
    }

    private func requireCurrent(_ ticket: UUID) throws {
        guard lifecycle.isCurrent(ticket) else { throw CancellationError() }
    }

    @MainActor
    private func installMonitor(activation: PluginActivationSnapshot?, store activationStore: PluginActivationStore, id monitorID: UUID) {
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
                guard var latest = self.authorizationMonitor, latest.id == monitorID else { return }
                let decision = latest.finish(current: current, consent: CaptureAuthorization.isGranted, id: monitorID)
                self.authorizationMonitor = latest
                guard case let .stop(reason) = decision else { return }
                await self.stopForAuthorizationChange(reason, id: monitorID)
            }
        }
    }

    @MainActor
    private func stopForAuthorizationChange(_ reason: TunnelAuthorizationMonitor.StopReason, id: UUID) async {
        guard authorizationMonitor?.id == id else { return }
        // Only the current ticket may stop; a stale monitor must not cancel a newer session.
        guard let stop = lifecycle.stop(expected: id, cleanup: { [self] in
            await teardown(monitorID: id)
            cancelTunnelWithError(reason)
        }) else { return }
        await stop.value
    }

    #if DEBUG
    /// Read-only identity query for the physical harness: answers only a fully started, still-current probe.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        Task { @MainActor [weak self] in
            completionHandler?(HTTPPluginOutboundProbe.reply(request: messageData, probe: self?.outboundProbe))
        }
    }
    #endif

    override func stopTunnel(with reason: NEProviderStopReason) async {
        let stop = lifecycle.stop { [self] in await teardown(monitorID: nil) }
        await stop?.value
    }

    /// Runs serialized. `monitorID` nil clears any monitor (explicit stop).
    private func teardown(monitorID: UUID?) async {
        #if DEBUG
        let probe = await MainActor.run {
            let probe = outboundProbe
            outboundProbe = nil
            return probe
        }
        #endif
        let processor = await MainActor.run {
            if monitorID == nil || authorizationMonitor?.id == monitorID {
                authorizationMonitor = nil
                consentMonitor?.invalidate(); consentMonitor = nil
            }
            let processor = pluginProcessor
            processor?.shutdown()
            pluginProcessor = nil
            return processor
        }
        await MITM.stopTunnel()
        let drained = await processor?.waitUntilStopped() ?? true
        #if DEBUG
        _ = await probe?.finish(drained: drained)
        #else
        _ = drained
        #endif
    }
}
