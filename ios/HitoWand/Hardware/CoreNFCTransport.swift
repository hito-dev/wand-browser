import Foundation
@preconcurrency import CoreNFC

@MainActor
final class CoreNFCTransport: NSObject, NFCTransport, @preconcurrency NFCNDEFReaderSessionDelegate {
    var onEvent: ((String, JSONValue) -> Void)?
    var onStatus: ((String, Bool) -> Void)?
    private var session: NFCNDEFReaderSession?
    private var activated = false
    private var readers: [String: String] = [:] // scan request -> reader
    private var starting: [String: CheckedContinuation<Void, Error>] = [:]
    private var pendingWrite: Write?
    private var tag: (any NFCNDEFTag)?
    private var tagBusy = false
    private var pollTask: Task<Void, Never>?

    private struct Write {
        let request: String
        let message: NFCNDEFMessage
        let overwrite: Bool
        let continuation: CheckedContinuation<Void, Error>
    }

    func scan(reader: String, request: String) async throws {
        guard !readers.values.contains(reader) else { throw WebError("InvalidStateError", "This reader is already scanning.") }
        guard readers.count < 16 else { throw WebError("QuotaExceededError", "Too many NFC readers.") }
        readers[request] = reader
        if activated { return }
        try await withCheckedThrowingContinuation { continuation in
            starting[request] = continuation
            do { try ensureSession() }
            catch {
                readers.removeValue(forKey: request)
                starting.removeValue(forKey: request)?.resume(throwing: error)
            }
        }
    }
    func write(reader: String, request: String, records: [NDEFRecord], overwrite: Bool) async throws {
        guard pendingWrite == nil else { throw WebError("InvalidStateError", "Another NFC write is pending.") }
        guard !records.isEmpty, records.count <= 64 else { throw WebError("TypeError", "Supply between 1 and 64 NDEF records.") }
        let message = NFCNDEFMessage(records: try records.map { try $0.payload() })
        guard message.length <= 65_536 else { throw WebError("QuotaExceededError", "NDEF message exceeds 64 KiB.") }
        try await withCheckedThrowingContinuation { continuation in
            pendingWrite = Write(request: request, message: message, overwrite: overwrite, continuation: continuation)
            do {
                try ensureSession()
                if let tag, tag.isAvailable, !tagBusy, let session { process(tag, in: session) }
            } catch { finishWrite(.failure(WebError.wrapping(error))) }
        }
    }
    private func ensureSession() throws {
        guard NFCNDEFReaderSession.readingAvailable else {
            throw WebError("NotSupportedError", "NFC is unavailable. Use an NFC-capable physical iPhone.")
        }
        guard session == nil else { return }
        let next = NFCNDEFReaderSession(delegate: self, queue: .main, invalidateAfterFirstRead: false)
        next.alertMessage = pendingWrite == nil ? "Hold your iPhone near an NFC tag to read it." : "Hold your iPhone near the tag you want to write."
        session = next; activated = false
        next.begin()
        onStatus?("Starting NFC…", false)
    }
    func readerSessionDidBecomeActive(_ session: NFCNDEFReaderSession) {
        guard self.session === session else { return }
        activated = true
        let pending = starting
        starting.removeAll()
        pending.values.forEach { $0.resume() }
        onStatus?("NFC scanning", false)
    }
    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        guard self.session === session else { return }
        self.session = nil; activated = false; tag = nil; tagBusy = false
        pollTask?.cancel(); pollTask = nil
        let code = (error as NSError).code
        let timeout = code == NFCReaderError.Code.readerSessionInvalidationErrorSessionTimeout.rawValue
        let cancelled = code == NFCReaderError.Code.readerSessionInvalidationErrorUserCanceled.rawValue
        let failure = cancelled ? WebError.aborted : WebError("NotReadableError", timeout ? "The NFC scan timed out. Tap Scan again in site controls." : error.localizedDescription)
        for (request, continuation) in starting {
            readers.removeValue(forKey: request)
            continuation.resume(throwing: failure)
        }
        starting.removeAll()
        if let write = pendingWrite { pendingWrite = nil; write.continuation.resume(throwing: failure) }
        for (request, reader) in readers {
            onEvent?(cancelled ? "nfc.stopped" : "nfc.error", .object(["reader": .string(reader), "request": .string(request), "error": failure.json]))
        }
        if cancelled { readers.removeAll() }
        onStatus?(cancelled ? "NFC scan cancelled" : "NFC scan ended", !readers.isEmpty)
    }
    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        // Read/write delegate mode uses didDetect tags instead.
    }
    func readerSession(_ session: NFCNDEFReaderSession, didDetect tags: [any NFCNDEFTag]) {
        guard self.session === session, !tagBusy else { return }
        guard tags.count == 1, let detected = tags.first else {
            session.alertMessage = "More than one tag found. Present just one tag."
            restartPolling(in: session)
            return
        }
        tagBusy = true
        tag = detected
        let sessionID = ObjectIdentifier(session)
        session.connect(to: detected) { [weak self] error in
            MainActor.assumeIsolated {
                guard let self, let session = self.session, ObjectIdentifier(session) == sessionID,
                      let detected = self.tag else { return }
                self.tagBusy = false
                if let error { self.tagFailure(error, in: session); return }
                self.process(detected, in: session)
            }
        }
    }
    private func process(_ tag: any NFCNDEFTag, in session: NFCNDEFReaderSession) {
        guard self.session === session, !tagBusy else { return }
        pollTask?.cancel(); pollTask = nil
        tagBusy = true
        let sessionID = ObjectIdentifier(session)
        tag.queryNDEFStatus { [weak self] status, capacity, error in
            MainActor.assumeIsolated {
                guard let self, let session = self.session, ObjectIdentifier(session) == sessionID,
                      let tag = self.tag else { return }
                if let error { self.tagFailure(error, in: session); return }
                guard status != .notSupported else {
                    self.tagFailure(WebError("NotSupportedError", "This tag is not NDEF formatted."), in: session); return
                }
                if let write = self.pendingWrite {
                    guard status == .readWrite else {
                        self.finishWrite(.failure(WebError("NotAllowedError", "This NFC tag is read-only.")))
                        self.restartPolling(in: session); return
                    }
                    guard write.message.length <= capacity else {
                        self.finishWrite(.failure(WebError("NotSupportedError", "The NFC message exceeds the tag's capacity.")))
                        self.restartPolling(in: session); return
                    }
                    if !write.overwrite {
                        let requestID = write.request
                        tag.readNDEF { [weak self] message, error in
                            let empty = message?.records.allSatisfy { $0.typeNameFormat == .empty } ?? true
                            MainActor.assumeIsolated {
                                guard let self, let session = self.session, ObjectIdentifier(session) == sessionID,
                                      let write = self.pendingWrite, write.request == requestID, let tag = self.tag else { return }
                                if let error { self.tagFailure(error, in: session); return }
                                guard empty else {
                                    self.finishWrite(.failure(WebError("NotAllowedError", "The tag contains data and overwrite is false.")))
                                    self.restartPolling(in: session); return
                                }
                                self.performWrite(write, to: tag, in: session)
                            }
                        }
                    } else { self.performWrite(write, to: tag, in: session) }
                } else {
                    tag.readNDEF { [weak self] message, error in
                        let decoded: Result<[NDEFRecord], WebError>
                        do { decoded = .success(try (message?.records ?? []).map { try NDEFRecord.decode($0) }) }
                        catch { decoded = .failure(WebError.wrapping(error)) }
                        MainActor.assumeIsolated {
                            guard let self, let session = self.session, ObjectIdentifier(session) == sessionID,
                                  let tag = self.tag else { return }
                            if let error { self.tagFailure(error, in: session); return }
                            do {
                                let records = try decoded.get()
                                for reader in self.readers.values {
                                    self.onEvent?("nfc.reading", .object(["reader": .string(reader), "serialNumber": .string(""),
                                                                      "records": .array(records.map(\.json))]))
                                }
                                self.tagBusy = false
                                if self.pendingWrite != nil { self.process(tag, in: session) }
                                else { self.restartPolling(in: session) }
                            } catch { self.tagFailure(error, in: session) }
                        }
                    }
                }
            }
        }
    }
    private func performWrite(_ write: Write, to tag: any NFCNDEFTag, in session: NFCNDEFReaderSession) {
        guard pendingWrite?.request == write.request else { restartPolling(in: session); return }
        let sessionID = ObjectIdentifier(session)
        let requestID = write.request
        tag.writeNDEF(write.message) { [weak self] error in
            MainActor.assumeIsolated {
                guard let self, let session = self.session, ObjectIdentifier(session) == sessionID,
                      self.pendingWrite?.request == requestID else { return }
                self.finishWrite(error.map { .failure(WebError("NetworkError", $0.localizedDescription)) } ?? .success(()))
                if self.readers.isEmpty {
                    session.alertMessage = error == nil ? "Tag written." : "Could not write the tag."
                    self.closeSession()
                } else { self.restartPolling(in: session) }
            }
        }
    }
    private func tagFailure(_ error: Error, in session: NFCNDEFReaderSession) {
        let error = error as? WebError ?? WebError("NotReadableError", error.localizedDescription)
        finishWrite(.failure(error))
        for reader in readers.values { onEvent?("nfc.error", .object(["reader": .string(reader), "error": error.json])) }
        session.alertMessage = error.message
        if readers.isEmpty { closeSession() } else { restartPolling(in: session) }
    }
    private func finishWrite(_ result: Result<Void, WebError>) {
        guard let write = pendingWrite else { return }
        pendingWrite = nil
        write.continuation.resume(with: result.mapError { $0 as Error })
    }
    private func restartPolling(in session: NFCNDEFReaderSession) {
        tagBusy = false
        pollTask?.cancel()
        guard self.session === session else { return }
        if readers.isEmpty && pendingWrite == nil { closeSession(); return }
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.session === session, !self.tagBusy else { return }
            self.tag = nil
            session.restartPolling()
        }
    }
    func cancel(request: String) {
        if let reader = readers.removeValue(forKey: request) {
            onEvent?("nfc.stopped", .object(["reader": .string(reader), "request": .string(request)]))
        }
        starting.removeValue(forKey: request)?.resume(throwing: WebError.aborted)
        if pendingWrite?.request == request {
            finishWrite(.failure(.aborted))
            // In-flight tag writes cannot be recalled; invalidate the native session and
            // discard its callbacks, so they cannot be mistaken for another write.
            for (id, continuation) in starting {
                readers.removeValue(forKey: id)
                continuation.resume(throwing: WebError.aborted)
            }
            starting.removeAll()
            closeSession()
            onStatus?("NFC write cancelled", !readers.isEmpty)
        }
        if readers.isEmpty && pendingWrite == nil {
            closeSession()
            onStatus?("NFC idle", false)
        }
    }
    func restart() throws {
        guard !readers.isEmpty, session == nil else { throw WebError("InvalidStateError", "There is no NFC scan to restart.") }
        try ensureSession()
    }
    private func closeSession() {
        let previous = session
        session = nil; activated = false; tag = nil; tagBusy = false
        pollTask?.cancel(); pollTask = nil
        previous?.invalidate()
    }
    func reset() {
        for continuation in starting.values { continuation.resume(throwing: WebError.aborted) }
        starting.removeAll(); readers.removeAll()
        finishWrite(.failure(.aborted))
        closeSession()
        onStatus?("NFC idle", false)
    }
}
