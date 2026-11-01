#if !os(tvOS)
import Core
import Downloads
import Foundation

/// Tunn adapter mellan en bakgrunds-`URLSession` och `DownloadTransport`. Ingen logik utöver att översätta
/// delegatanropen till `DownloadTransportEvent`; besluten tas av `DownloadManager`.
///
/// Delegatens temporärfil raderas av systemet så fort `didFinishDownloadingTo` returnerar. Därför flyttas den
/// synkront till `stagingDirectory` (samma volym) innan händelsen skickas; mottagaren flyttar den vidare med
/// `DownloadStore.completeMoving` eller raderar den.
final class BackgroundDownloadTransport: NSObject, DownloadTransport, URLSessionDownloadDelegate, @unchecked Sendable {
    static let sessionIdentifier = "se.sjodin.iptv.downloads"

    let events: AsyncStream<DownloadTransportEvent>
    private let continuation: AsyncStream<DownloadTransportEvent>.Continuation
    private let stagingDirectory: URL
    // Sätts exakt en gång i `init`, direkt efter `super.init()`, och läses sedan bara.
    private var session: URLSession!

    /// - Parameter stagingDirectory: katalog på samma volym som nedladdningarna. Töms vid start (en fil som en
    ///   tidigare körning hann mellanlagra men aldrig tog emot hör till en överföring som systemet redan avslutat).
    init(stagingDirectory: URL, allowsCellularAccess: Bool = true) {
        self.stagingDirectory = stagingDirectory
        let pair = AsyncStream<DownloadTransportEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
        super.init()
        Self.resetStaging(stagingDirectory)
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = allowsCellularAccess
        // Delegatkön är seriell (nil = intern seriell kö), så delegatanropen körs i ordning.
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    // MARK: - DownloadTransport

    func start(_ request: DownloadTransportRequest) async throws -> DownloadTaskHandle {
        let task: URLSessionDownloadTask
        if let resumeData = request.resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            let url = try request.locator.resolve(with: request.secret)
            var urlRequest = URLRequest(url: url)
            urlRequest.allowsCellularAccess = request.allowsCellular
            task = session.downloadTask(with: urlRequest)
        }
        task.taskDescription = Self.describe(request.key)
        task.resume()
        return DownloadTaskHandle(key: request.key, taskID: task.taskIdentifier)
    }

    func pause(_ handle: DownloadTaskHandle) async -> Data? {
        guard let task = await downloadTask(for: handle) else { return nil }
        // Händelser för en uppgift som stoppas av oss ignoreras i `didCompleteWithError` (avbruten).
        return await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            task.cancel(byProducingResumeData: { data in c.resume(returning: data) })
        }
    }

    func cancel(_ handle: DownloadTaskHandle) async {
        (await downloadTask(for: handle))?.cancel()
    }

    func reattach() async -> [DownloadTaskHandle] {
        await session.allTasks.compactMap { task in
            guard task is URLSessionDownloadTask, task.state == .running || task.state == .suspended,
                  let key = Self.key(from: task.taskDescription) else { return nil }
            return DownloadTaskHandle(key: key, taskID: task.taskIdentifier)
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = Self.key(from: downloadTask.taskDescription) else { return }
        continuation.yield(.progress(DownloadTaskHandle(key: key, taskID: downloadTask.taskIdentifier),
                                     bytesWritten: totalBytesWritten, totalBytes: totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = Self.key(from: downloadTask.taskDescription) else { return }
        let handle = DownloadTaskHandle(key: key, taskID: downloadTask.taskIdentifier)
        let response = downloadTask.response as? HTTPURLResponse
        let status = response?.statusCode ?? 0
        let contentType = response?.value(forHTTPHeaderField: "Content-Type")
        // Måste ske här: systemet raderar `location` när metoden returnerar.
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            let staged = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: false)
            try FileManager.default.moveItem(at: location, to: staged)
            continuation.yield(.finished(handle, stagedFile: staged, status: status, contentType: contentType))
        } catch {
            continuation.yield(.failed(handle, .storage, resumeData: nil))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Lyckade överföringar rapporterades redan i `didFinishDownloadingTo`.
        guard let error, let key = Self.key(from: task.taskDescription) else { return }
        let nsError = error as NSError
        // Avbrutet av oss (paus eller avbryt): ingen händelse.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        let failure: DownloadFailure = nsError.domain == NSURLErrorDomain ? .network : .unknown
        let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        continuation.yield(.failed(DownloadTaskHandle(key: key, taskID: task.taskIdentifier), failure,
                                   resumeData: resumeData))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        continuation.yield(.backgroundEventsFinished)
    }

    // MARK: - Hjälpare

    private func downloadTask(for handle: DownloadTaskHandle) async -> URLSessionDownloadTask? {
        await session.allTasks.first { $0.taskIdentifier == handle.taskID } as? URLSessionDownloadTask
    }

    private static func resetStaging(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    /// `profil|spellista|typ|id`. Innehåller inga uppgifter; id:t är leverantörens titel-id.
    static func describe(_ key: DownloadKey) -> String {
        [key.profileID.uuidString, key.playlistID.uuidString, key.kind.rawValue, key.providerID].joined(separator: "|")
    }

    static func key(from description: String?) -> DownloadKey? {
        guard let description else { return nil }
        let parts = description.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, let profile = UUID(uuidString: String(parts[0])),
              let playlist = UUID(uuidString: String(parts[1])), let kind = ContentKind(rawValue: String(parts[2]))
        else { return nil }
        return DownloadKey(profileID: profile, playlistID: playlist, kind: kind, providerID: String(parts[3]))
    }
}
#endif
