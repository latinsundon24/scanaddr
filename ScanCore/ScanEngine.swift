import Foundation

public struct ScanSettings: Equatable {
    public var method: String = "GET"
    public var timeout: TimeInterval = 2.0
    public var concurrency: Int = 24
    public var acceptRedirects: Bool = false
    public var acceptedStatusMin: Int = 200
    public var acceptedStatusMax: Int = 399
    public var requireKeyword: String = ""
    public var excludeKeyword: String = ""
    public var maxBodyBytes: Int = 64 * 1024

    public init() {}

    public func accepts(status: Int) -> Bool {
        status >= min(acceptedStatusMin, acceptedStatusMax) &&
        status <= max(acceptedStatusMin, acceptedStatusMax)
    }
}

public struct ScanHit: Identifiable, Equatable, Hashable {
    public var id: String { url }
    public let url: String
    public let status: Int
    public let elapsedMs: Int
    public let bytes: Int
    public let preview: String

    public init(url: String, status: Int, elapsedMs: Int, bytes: Int, preview: String) {
        self.url = url
        self.status = status
        self.elapsedMs = elapsedMs
        self.bytes = bytes
        self.preview = preview
    }
}

private final class SessionDelegate: NSObject, URLSessionTaskDelegate {
    let followRedirects: Bool
    init(followRedirects: Bool) { self.followRedirects = followRedirects }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(followRedirects ? request : nil)
    }
}

/// 真实发出 HTTP 请求的扫描引擎。IPv4 / IPv6 由系统 URLSession 直接处理，
/// 主机位 IPv6 使用标准 [addr] 形式，无需任何第三方依赖。
public final class ScanEngine: @unchecked Sendable {
    private let settings: ScanSettings
    private let session: URLSession
    private let delegate: SessionDelegate
    private let lock = NSLock()
    private var cancelled = false

    public init(settings: ScanSettings = ScanSettings()) {
        self.settings = settings
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = settings.timeout
        cfg.timeoutIntervalForResource = max(settings.timeout * 2, 4)
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpMaximumConnectionsPerHost = max(4, settings.concurrency)
        let d = SessionDelegate(followRedirects: settings.acceptRedirects)
        self.delegate = d
        self.session = URLSession(configuration: cfg, delegate: d, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// 并发探测全部 URL；只有满足状态码与关键字条件的才通过 onHit 返回。
    public func scan(urls: [String],
                     onHit: @escaping @Sendable (ScanHit) -> Void,
                     onProgress: @escaping @Sendable (Int, Int) -> Void) async {
        let total = urls.count
        guard total > 0 else { onProgress(0, 0); return }
        let workers = max(1, min(settings.concurrency, total))
        var next = 0
        var completed = 0

        await withTaskGroup(of: ScanHit?.self) { group in
            for _ in 0..<workers {
                let u = urls[next]
                next += 1
                group.addTask { await self.probe(u) }
            }
            while let hit = await group.next() {
                completed += 1
                if let h = hit { onHit(h) }
                onProgress(completed, total)
                if !self.isCancelled(), next < total {
                    let u = urls[next]
                    next += 1
                    group.addTask { await self.probe(u) }
                }
            }
        }
    }

    private func probe(_ raw: String) async -> ScanHit? {
        guard !isCancelled(), let url = URL(string: raw) else { return nil }
        var request = URLRequest(url: url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: settings.timeout)
        request.httpMethod = settings.method.uppercased()
        request.setValue("scanaddr/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("close", forHTTPHeaderField: "Connection")
        let started = Date()
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  settings.accepts(status: http.statusCode) else { return nil }
            let slice = data.prefix(max(0, settings.maxBodyBytes))
            let body = String(decoding: slice, as: UTF8.self)
            if !settings.requireKeyword.isEmpty && !body.contains(settings.requireKeyword) { return nil }
            if !settings.excludeKeyword.isEmpty && body.contains(settings.excludeKeyword) { return nil }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            return ScanHit(url: raw,
                           status: http.statusCode,
                           elapsedMs: ms,
                           bytes: data.count,
                           preview: String(body.prefix(160)))
        } catch {
            return nil
        }
    }
}
