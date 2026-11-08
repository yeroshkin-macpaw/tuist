import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A response whose body arrives as the server sends it, for long-lived responses such as ND-JSON log streams. The
/// shared session's 90-second resource timeout would cut those off, so each stream gets a session that allows an hour
/// (the request timeout still ends a stream that goes quiet), invalidated when the stream ends.
enum StreamingResponse {
    private static let resourceTimeout: TimeInterval = 3600

    static func start(
        _ request: URLRequest,
        session base: URLSession
    ) async throws -> (URLResponse, AsyncThrowingStream<ArraySlice<UInt8>, any Error>) {
        let configuration = base.configuration
        configuration.timeoutIntervalForResource = resourceTimeout
        #if canImport(FoundationNetworking)
            // FoundationNetworking has no `bytes(for:)`; a data delegate hands the chunks over as they arrive.
            let delegate = Delegate()
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            let task = session.dataTask(with: request)
            delegate.chunks.onTermination = { _ in
                task.cancel()
                session.finishTasksAndInvalidate()
            }
            let response = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    delegate.setResponseContinuation(continuation)
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
            return (response, delegate.stream)
        #else
            let session = URLSession.tuist(configuration: configuration)
            let (bytes, response) = try await session.bytes(for: request)
            let stream = AsyncThrowingStream<ArraySlice<UInt8>, any Error> { continuation in
                // One chunk per line, so a reader sees each log line as soon as it arrives.
                let reader = Task {
                    var line: [UInt8] = []
                    do {
                        for try await byte in bytes {
                            line.append(byte)
                            if byte == UInt8(ascii: "\n") || line.count >= 64 * 1024 {
                                continuation.yield(ArraySlice(line))
                                line.removeAll(keepingCapacity: true)
                            }
                        }
                        if !line.isEmpty { continuation.yield(ArraySlice(line)) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                    session.finishTasksAndInvalidate()
                }
                continuation.onTermination = { _ in
                    reader.cancel()
                    bytes.task.cancel()
                }
            }
            return (response, stream)
        #endif
    }

    #if canImport(FoundationNetworking)
        private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
            let stream: AsyncThrowingStream<ArraySlice<UInt8>, any Error>
            let chunks: AsyncThrowingStream<ArraySlice<UInt8>, any Error>.Continuation
            private let lock = NSLock()
            private var responseContinuation: CheckedContinuation<URLResponse, any Error>?

            override init() {
                (stream, chunks) = AsyncThrowingStream.makeStream()
            }

            func setResponseContinuation(_ continuation: CheckedContinuation<URLResponse, any Error>) {
                lock.withLock { responseContinuation = continuation }
            }

            private func takeResponseContinuation() -> CheckedContinuation<URLResponse, any Error>? {
                lock.withLock {
                    defer { responseContinuation = nil }
                    return responseContinuation
                }
            }

            func urlSession(
                _: URLSession,
                dataTask _: URLSessionDataTask,
                didReceive response: URLResponse,
                completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
            ) {
                takeResponseContinuation()?.resume(returning: response)
                completionHandler(.allow)
            }

            func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
                chunks.yield(ArraySlice(data))
            }

            func urlSession(_ session: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
                if let error {
                    takeResponseContinuation()?.resume(throwing: error)
                    chunks.finish(throwing: error)
                } else {
                    chunks.finish()
                }
                session.finishTasksAndInvalidate()
            }
        }
    #endif
}
