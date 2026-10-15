//
//  SSLProxyingListTests.swift
//  InterceptorTests
//

import Foundation
@testable import Interceptor
import JavaScriptCore
@testable import Mudmouth
import NetworkExtension
import XCTest

@MainActor
final class SSLProxyingListTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "SSLProxyingListTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    private func makeStore() -> SSLProxyingListStore {
        .init(defaults: defaults)
    }

    private func hosts(_ store: SSLProxyingListStore) -> [String] {
        store.options.map(\.host)
    }

    // MARK: Validation

    func testValidation() {
        for host in ["example.com", "a-b.example.co.jp", "api.lp1.87abc152.srv.nintendo.net", "1.example.com", String(repeating: "a", count: 63) + ".com"] {
            XCTAssertTrue(CaptureHostList.isValid(host), host)
        }
        let tooLong = Array(repeating: String(repeating: "a", count: 60), count: 5).joined(separator: ".") + ".com"
        for host in ["", "localhost", "example", "printer.local", "127.0.0.1", "1.2.3.4", "*.example.com", "https://example.com",
                     "example.com/path", "example.com:443", "exa mple.com", "-a.example.com", "a-.example.com", "a..example.com",
                     "bücher.example", "Example.com", "example.com.", String(repeating: "a", count: 64) + ".com", tooLong, "[::1]"]
        {
            XCTAssertFalse(CaptureHostList.isValid(host), host)
        }
    }

    func testCanonicalizeTrimsLowercasesAndRemovesOneTrailingDot() {
        XCTAssertEqual(CaptureHostList.canonicalize("  Example.COM.\n"), "example.com")
        XCTAssertEqual(CaptureHostList.canonicalize("example.com.."), "example.com.")
        XCTAssertEqual(try? CaptureHostList.validate(" API.Example.com. ").get(), "api.example.com")
        XCTAssertEqual(CaptureHostList.validate("   "), .failure(.empty))
        XCTAssertEqual(CaptureHostList.validate("example.com.."), .failure(.invalid))
    }

    // MARK: Store

    func testInitialListIsOriginalFiveRoutedHosts() {
        let store = makeStore()
        XCTAssertEqual(hosts(store), [
            "api.lp1.av5ja.srv.nintendo.net", "api.lp1.87abc152.srv.nintendo.net", "app.splatoon2.nintendo.net",
            "app.smashbros.nintendo.net", "web.sd.lp1.acbaa.srv.nintendo.net",
        ])
        XCTAssertEqual(store.options.first?.paths.map(\.path), ["/api/bullet_tokens"])
        XCTAssertNil(store.loadError)
        XCTAssertNotNil(defaults.data(forKey: SSLProxyingListStore.key))
    }

    func testEmptyListStaysEmptyButAbsentKeySeeds() {
        let store = makeStore()
        store.delete(at: IndexSet(integersIn: 0 ..< store.options.count))
        XCTAssertTrue(makeStore().options.isEmpty)
        defaults.removeObject(forKey: SSLProxyingListStore.key)
        XCTAssertEqual(makeStore().options.count, 5)
    }

    func testCorruptAndUnknownVersionArePreservedAndBlockMutation() throws {
        let blobs = [Data("not json".utf8), Data(#"{"version":2,"options":[]}"#.utf8), Data(#"{"version":1,"options":[{"host":"Bad Host","paths":[],"capture":true,"notify":true}]}"#.utf8)]
        for blob in blobs {
            defaults.set(blob, forKey: SSLProxyingListStore.key)
            let store = makeStore()
            XCTAssertNotNil(store.loadError)
            XCTAssertTrue(store.options.isEmpty)
            XCTAssertThrowsError(try store.add("example.com"))
            store.sort(ascending: true)
            XCTAssertEqual(defaults.data(forKey: SSLProxyingListStore.key), blob)
        }
        defaults.set(blobs[0], forKey: SSLProxyingListStore.key)
        let store = makeStore()
        store.reset()
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.options.count, 5)
        XCTAssertEqual(makeStore().options.count, 5)
    }

    func testResetIsNoOpWithoutError() throws {
        let store = makeStore()
        try store.add("example.com")
        store.reset()
        XCTAssertEqual(hosts(store).last, "example.com")
    }

    func testAddNormalizesAndPersists() throws {
        let store = makeStore()
        try store.add("  New.Example.COM. ")
        XCTAssertEqual(hosts(store).last, "new.example.com")
        XCTAssertEqual(hosts(makeStore()).last, "new.example.com")
        XCTAssertThrowsError(try store.add("new.example.com"))
        XCTAssertThrowsError(try store.add("NEW.example.com."))
        XCTAssertThrowsError(try store.add("https://x.example.com"))
        XCTAssertEqual(store.options.count, 6)
    }

    func testRenameAllowsSelfRejectsDuplicateAndPreservesFields() throws {
        let store = makeStore()
        let original = store.options[0]
        try store.rename(original.host, to: original.host.uppercased())
        XCTAssertEqual(store.options[0].host, original.host)
        XCTAssertThrowsError(try store.rename(original.host, to: store.options[1].host))
        XCTAssertThrowsError(try store.rename("missing.example.com", to: "other.example.com"))

        try store.rename(original.host, to: "renamed.example.com")
        let renamed = makeStore().options[0]
        XCTAssertEqual(renamed.host, "renamed.example.com")
        XCTAssertEqual(renamed.paths.map(\.path), original.paths.map(\.path))
        XCTAssertEqual(renamed.capture, original.capture)
        XCTAssertEqual(renamed.notify, original.notify)
        XCTAssertEqual(renamed.script, original.script)
        XCTAssertEqual(store.options.count, 5)
    }

    func testRenamePreservesCustomFields() throws {
        let custom = ProxyOption(host: "a.example.com", paths: [.init(path: "/x", capture: false, notify: false)], capture: false, notify: false, script: "1+1")
        let envelope = try ["version": 1 as Any, "options": JSONSerialization.jsonObject(with: JSONEncoder().encode([custom]))] as [String: Any]
        try defaults.set(JSONSerialization.data(withJSONObject: envelope), forKey: SSLProxyingListStore.key)
        let store = makeStore()
        try store.rename("a.example.com", to: "b.example.com")
        let option = makeStore().options[0]
        XCTAssertEqual(option.host, "b.example.com")
        XCTAssertEqual(option.paths.map(\.path), ["/x"])
        XCTAssertEqual(option.paths.map(\.capture), [false])
        XCTAssertEqual(option.paths.map(\.notify), [false])
        XCTAssertFalse(option.capture)
        XCTAssertFalse(option.notify)
        XCTAssertEqual(option.script, "1+1")
    }

    func testDeletePersists() {
        let store = makeStore()
        let expected = Array(hosts(store).dropFirst())
        store.delete(at: [0])
        XCTAssertEqual(hosts(makeStore()), expected)
    }

    func testMoveAndSortPersist() {
        let store = makeStore()
        let initial = hosts(store)
        store.move(from: [0], to: 3)
        let moved = [initial[1], initial[2], initial[0], initial[3], initial[4]]
        XCTAssertEqual(hosts(makeStore()), moved)
        store.sort(ascending: true)
        XCTAssertEqual(hosts(makeStore()), initial.sorted())
        store.sort(ascending: false)
        XCTAssertEqual(hosts(makeStore()), initial.sorted(by: >))
    }

    func testTuberoseOptionsFollowStore() throws {
        let store = makeStore()
        let tuberose = Tuberose(store: store)
        try store.add("added.example.com")
        XCTAssertEqual(tuberose.options.map(\.host), hosts(store))
        XCTAssertEqual(tuberose.options.last?.host, "added.example.com")
    }

    // MARK: Payload

    func testEnabledTargetsGuards() throws {
        let a = ProxyOption(host: "a.example.com", paths: [])
        let b = ProxyOption(host: "b.example.com", paths: [], capture: false)
        XCTAssertEqual(try CaptureHostList.enabledTargets(in: [a, b]).map(\.host), ["a.example.com"])
        XCTAssertThrowsError(try CaptureHostList.enabledTargets(in: []))
        XCTAssertThrowsError(try CaptureHostList.enabledTargets(in: [b]))
        XCTAssertThrowsError(try CaptureHostList.enabledTargets(in: [a, a]))
        XCTAssertThrowsError(try CaptureHostList.enabledTargets(in: [.init(host: "A.example.com", paths: [])]))
        XCTAssertThrowsError(try CaptureHostList.enabledTargets(in: [.init(host: "bad", paths: [])]))
    }

    func testDecodeTargetsRejectsInvalidPayloads() throws {
        let good = try JSONEncoder().encode([ProxyOption(host: "a.example.com", paths: [])])
        XCTAssertEqual(try CaptureHostList.decodeTargets(from: ["ProxyTargets": good as NSData]).map(\.host), ["a.example.com"])
        XCTAssertThrowsError(try CaptureHostList.decodeTargets(from: nil))
        XCTAssertThrowsError(try CaptureHostList.decodeTargets(from: [:]))
        XCTAssertThrowsError(try CaptureHostList.decodeTargets(from: ["ProxyTargets": "x" as NSString]))
        XCTAssertThrowsError(try CaptureHostList.decodeTargets(from: ["ProxyTargets": Data("{".utf8) as NSData]))
        XCTAssertThrowsError(try CaptureHostList.decodeTargets(from: ["ProxyTargets": Data("[]".utf8) as NSData]))
        let upper = try JSONEncoder().encode([ProxyOption(host: "A.example.com", paths: [])])
        XCTAssertThrowsError(try CaptureHostList.decodeTargets(from: ["ProxyTargets": upper as NSData]))
    }

    // MARK: PAC / settings

    private func proxy(_ url: String, hosts: [String] = ["api.example.com"]) throws -> String {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(CaptureHostList.pacScript(hosts: hosts))
        let function = try XCTUnwrap(context.objectForKeyedSubscript("FindProxyForURL"))
        let host = URL(string: url)?.host ?? ""
        return try XCTUnwrap(function.call(withArguments: [url, host])?.toString())
    }

    func testPACRoutesOnlyExactHTTPSHosts() throws {
        let proxied = "PROXY 127.0.0.1:6836"
        XCTAssertEqual(try proxy("https://api.example.com/x"), proxied)
        XCTAssertEqual(try proxy("https://API.Example.com/x?q=1"), proxied)
        XCTAssertEqual(try proxy("https://api.example.com"), proxied)
        XCTAssertEqual(try proxy("https://api.example.com:443/x"), proxied)
        XCTAssertEqual(try proxy("https://child.api.example.com/"), "DIRECT")
        XCTAssertEqual(try proxy("https://example.com/"), "DIRECT")
        XCTAssertEqual(try proxy("https://other.example.com/"), "DIRECT")
        XCTAssertEqual(try proxy("https://api.example.com./"), "DIRECT")
        XCTAssertEqual(try proxy("http://api.example.com/"), "DIRECT")
        XCTAssertEqual(try proxy("https://api.example.com:8443/"), "DIRECT")
        XCTAssertEqual(try proxy("https://api.example.com/", hosts: []), "DIRECT")
    }

    func testPACEscapesHostLiterals() throws {
        XCTAssertEqual(try proxy("https://a.example.com/", hosts: ["a.example.com\"];evil();//"]), "DIRECT")
    }

    func testTunnelSettings() throws {
        let list = ["a.example.com", "b.example.com"]
        let settings = try CaptureHostList.tunnelSettings(hosts: list)
        let proxySettings = try XCTUnwrap(settings.proxySettings)
        XCTAssertEqual(proxySettings.matchDomains, list)
        XCTAssertTrue(proxySettings.autoProxyConfigurationEnabled)
        XCTAssertFalse(proxySettings.httpsEnabled)
        XCTAssertFalse(proxySettings.httpEnabled)
        XCTAssertNil(proxySettings.proxyAutoConfigurationURL)
        XCTAssertEqual(proxySettings.proxyAutoConfigurationJavaScript, CaptureHostList.pacScript(hosts: list))
        XCTAssertThrowsError(try CaptureHostList.tunnelSettings(hosts: []))
        XCTAssertThrowsError(try CaptureHostList.tunnelSettings(hosts: ["bad host"]))
        XCTAssertThrowsError(try CaptureHostList.tunnelSettings(hosts: ["a.example.com", "a.example.com"]))
    }
}
