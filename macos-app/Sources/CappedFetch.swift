import Foundation

struct FetchResult {
    // nil on an error or when the body passed the cap.
    let data: Data?
    let response: URLResponse?
    let error: Error?
    let tooLarge: Bool
    // The addresses the connection really used, whatever name the URL had.
    let remoteAddress: String?
    let localAddress: String?

    var status: Int? { (response as? HTTPURLResponse)?.statusCode }
}

// Stops a download at its cap while the bytes arrive, and never follows a redirect.
final class CappedFetcher: NSObject, URLSessionDataDelegate {
    private struct Job {
        var data = Data()
        var tooLarge = false
        var remote: String?
        var local: String?
        let cap: Int
        let completion: (FetchResult) -> Void
    }

    private let lock = NSLock()
    private var jobs: [Int: Job] = [:]
    private var session: URLSession!

    init(configuration: URLSessionConfiguration) {
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func fetch(_ request: URLRequest, maxBytes: Int, completion: @escaping (FetchResult) -> Void) {
        let task = session.dataTask(with: request)
        lock.lock()
        jobs[task.taskIdentifier] = Job(cap: maxBytes, completion: completion)
        lock.unlock()
        task.resume()
    }

    // The session holds this object until then, so a short-lived fetcher must call it.
    func invalidate() {
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        defer { lock.unlock() }
        let id = dataTask.taskIdentifier
        guard let job = jobs[id], !job.tooLarge else { return }
        if job.data.count + data.count > job.cap {
            jobs[id]?.tooLarge = true
            jobs[id]?.data = Data()
            dataTask.cancel()
        } else {
            // In place: a copy taken out of the dictionary would be duplicated on every chunk.
            jobs[id]?.data.append(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock()
        defer { lock.unlock() }
        // Through a proxy the addresses are the proxy's, so they stay unknown.
        guard let last = metrics.transactionMetrics.last, !last.isProxyConnection else { return }
        jobs[task.taskIdentifier]?.remote = last.remoteAddress
        jobs[task.taskIdentifier]?.local = last.localAddress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let job = jobs.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let job = job else { return }
        // The cancel that enforces the cap is not a failure of the request itself.
        let failure = job.tooLarge ? nil : error
        job.completion(FetchResult(data: job.tooLarge || failure != nil ? nil : job.data, response: task.response,
                                   error: failure, tooLarge: job.tooLarge, remoteAddress: job.remote, localAddress: job.local))
    }
}
