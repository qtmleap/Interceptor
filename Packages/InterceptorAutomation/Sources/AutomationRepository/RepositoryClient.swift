import AutomationCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum RepositoryClientError: Error, Equatable, Sendable {
    /// Response was not an HTTPURLResponse.
    case nonHTTPResponse
    /// Any redirect is refused; the target is never requested.
    case redirected
    /// Any status other than 200 (including 304, 3xx, 204, 206, 4xx, 5xx).
    case unexpectedStatus(Int)
    /// Declared Content-Length or actually received decoded bytes exceeded the cap.
    case responseTooLarge
    /// Absolute total deadline (default 15 s) elapsed.
    case timedOut
    /// Connection failure, URL loading failure or a refused authentication challenge.
    case transport
}

/// Fetches repository envelopes and plugin packages over HTTPS. Every request owns a fresh ephemeral
/// `URLSession` that is invalidated on every outcome; nothing is shared between requests.
public struct RepositoryClient: Sendable {
    public static let defaultDeadline: TimeInterval = 15

    let deadline: TimeInterval
    let protocolClasses: [AnyClass]

    /// `protocolClasses` replaces the session's protocol list (tests install a `URLProtocol` fixture);
    /// production callers leave it empty. The hardening is applied to the configuration afterwards.
    /// `deadline` is the total time for one request and is capped at `defaultDeadline`.
    public init(deadline: TimeInterval = RepositoryClient.defaultDeadline, protocolClasses: [AnyClass] = []) {
        self.deadline = min(max(deadline, 0.001), RepositoryClient.defaultDeadline)
        self.protocolClasses = protocolClasses
    }

    public func preview(url: RepositoryURL, now: Date) async throws -> VerifiedSnapshot {
        let data = try await fetch(url.envelopeURL, maxBytes: Limits.envelope)
        return try RepositoryEnvelope.verify(envelope: data, url: url, now: now)
    }

    public func fetchPackage(entry: IndexEntry, from snapshot: VerifiedSnapshot) async throws -> PluginPackage {
        guard snapshot.index.plugins.contains(entry) else { throw AutomationError.staleSnapshot }
        let url = try snapshot.url.packageURL(path: entry.packagePath)
        let data = try await fetch(url, maxBytes: min(entry.size, Limits.package))
        return try PluginPackage.validate(data, against: entry)
    }

    private func fetch(_ url: URL, maxBytes: Int) async throws -> Data {
        try Task.checkCancellation()
        let data = try await BoundedFetch(url: url, maxBytes: maxBytes, deadline: deadline, protocolClasses: protocolClasses).run()
        try Task.checkCancellation()
        return data
    }
}

/// One GET request with its own session and delegate. All outcomes funnel through `finish`, which runs its
/// effects exactly once: it records the outcome, stops the task, invalidates the session and resumes the
/// continuation. Later delegate callbacks, the deadline timer and cancellation are then no-ops.
private final class BoundedFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let maxBytes: Int
    private let deadline: TimeInterval
    private let protocolClasses: [AnyClass]

    private let lock = NSLock()
    private var outcome: Result<Data, Error>?
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var timer: DispatchWorkItem?
    /// Touched only on the session's serial delegate queue.
    private var buffer = Data()

    init(url: URL, maxBytes: Int, deadline: TimeInterval, protocolClasses: [AnyClass]) {
        self.url = url; self.maxBytes = maxBytes; self.deadline = deadline; self.protocolClasses = protocolClasses
    }

    func run() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { begin($0) }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    private func begin(_ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        if let early = outcome { lock.unlock(); continuation.resume(with: early); return }  // cancelled before start
        self.continuation = continuation
        lock.unlock()

        let config = URLSessionConfiguration.ephemeral
        if !protocolClasses.isEmpty { config.protocolClasses = protocolClasses }
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = deadline
        config.timeoutIntervalForResource = deadline
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = nil

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: deadline)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        let timer = DispatchWorkItem { [weak self] in self?.finish(.failure(RepositoryClientError.timedOut)) }

        lock.lock()
        if outcome != nil { lock.unlock(); session.invalidateAndCancel(); return }  // finished while configuring
        self.session = session; self.task = task; self.timer = timer
        lock.unlock()

        DispatchQueue.global().asyncAfter(deadline: .now() + deadline, execute: timer)  // monotonic clock
        task.resume()
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let continuation = self.continuation, session = self.session, task = self.task, timer = self.timer
        self.continuation = nil; self.session = nil; self.task = nil; self.timer = nil
        lock.unlock()

        timer?.cancel()
        task?.cancel()
        session?.invalidateAndCancel()  // releases the session's strong reference to this delegate
        continuation?.resume(with: result)
    }

    private var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return outcome != nil }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard !isFinished else { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse else {
            finish(.failure(RepositoryClientError.nonHTTPResponse)); completionHandler(.cancel); return
        }
        guard http.statusCode == 200 else {
            finish(.failure(RepositoryClientError.unexpectedStatus(http.statusCode))); completionHandler(.cancel); return
        }
        if http.expectedContentLength > Int64(maxBytes) {
            finish(.failure(RepositoryClientError.responseTooLarge)); completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !isFinished else { return }
        guard data.count <= maxBytes - buffer.count else {
            finish(.failure(RepositoryClientError.responseTooLarge))
            return
        }
        buffer.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let timedOut = (error as? URLError)?.code == .timedOut
            finish(.failure(timedOut ? RepositoryClientError.timedOut : RepositoryClientError.transport))
        } else {
            finish(.success(buffer))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        finish(.failure(RepositoryClientError.redirected))
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        answer(challenge, completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        answer(challenge, completionHandler)
    }

    /// Only the system's default TLS server-trust evaluation is allowed; no credential is ever supplied.
    private func answer(_ challenge: URLAuthenticationChallenge,
                        _ completionHandler: @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            finish(.failure(RepositoryClientError.transport))
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse,
                    completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void) {
        completionHandler(nil)
    }
}
