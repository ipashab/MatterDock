import Foundation
import Network
import os

/// MatterDock: fallback-транспорт бинарных GET на серверах (Time Messenger),
/// которые отдают медиа-тела в zstd: их nginx кеширует варианты ответа по URL
/// и игнорирует `Vary: Accept-Encoding`, поэтому закешированный zstd-вариант
/// выдаётся при любом `Accept-Encoding`, а URLSession не умеет ни отправить
/// запрос без этого заголовка, ни декодировать zstd.
///
/// Запрос отправляется сырым HTTP/1.1 через `NWConnection`: лишних заголовков
/// не добавляется, а в адрес подставляется уникальный параметр `zcb`, который
/// уводит запрос мимо закешированного zstd-варианта — на промахе кеша сервер
/// отвечает несжатым телом. HTTP/1.1-ответы такого сервера всегда chunked,
/// поэтому тело раскодируется по кадрам (RFC 9112 §7.1). Правила те же, что у
/// основного транспорта: редиректы не отслеживаются (статус возвращается как
/// есть), тело читается до конца кадров (`Connection: close`). На серверах
/// без подобного кеша не используется — вызывается только как повтор после
/// обнаруженного `Content-Encoding: zstd` (решение docs/decisions/0039).
enum RawZstdBypass {

    /// Максимальный размер стартовой строки и заголовков ответа.
    private static let maximumHeadBytes = 64 * 1024

    private static let bannedHeaders: Set<String> = [
        "accept-encoding", "host", "authorization", "connection", "content-length", "transfer-encoding",
    ]

    // MARK: - Точка входа

    /// Полный GET-ответ в память (аватары, эскизы, превью, эмодзи, иконки).
    static func fetch(_ request: HTTPRequest, limits: ResponseLimits) async throws(APIError) -> HTTPResponse {
        guard request.method == .get else { throw .malformedResponse }
        return try await withConnection(request) { (session: Session) async throws(APIError) -> HTTPResponse in
            let (response, remainder) = try parseHead(session.head)
            var reader = BodyPieceReader(session: session, response: response, remainder: remainder)
            var body = Data()
            while let piece = try await reader.next() {
                if Int64(body.count) + Int64(piece.count) > limits.maximumBodyBytes {
                    throw APIError.responseTooLarge(limitBytes: Int(limits.maximumBodyBytes))
                }
                body += piece
            }
            return HTTPResponse(statusCode: response.statusCode, headers: response.headers, body: body)
        }
    }

    /// GET-ответ, тело пишется потоком в дескриптор (скачивание файлов).
    static func transfer(_ request: HTTPRequest, to handle: FileHandle, limits: ResponseLimits,
                         progress: (@Sendable (TransferProgress) -> Void)? = nil) async throws(APIError) -> HTTPResponse {
        guard request.method == .get else { throw .malformedResponse }
        return try await withConnection(request) { (session: Session) async throws(APIError) -> HTTPResponse in
            let (response, remainder) = try parseHead(session.head)
            // Для chunked-ответов Content-Length отсутствует — прогресс без
            // общего размера, только принятые байты.
            let total = response.contentLengthBytes
            var received: Int64 = 0
            var reader = BodyPieceReader(session: session, response: response, remainder: remainder)
            // Ошибка записи в пользовательский файл — не сетевая.
            do {
                while let piece = try await reader.next() {
                    if received + Int64(piece.count) > limits.maximumBodyBytes {
                        throw APIError.responseTooLarge(limitBytes: Int(limits.maximumBodyBytes))
                    }
                    try handle.write(contentsOf: piece)
                    received += Int64(piece.count)
                    progress?(TransferProgress(completedBytes: received, totalBytes: total))
                }
            } catch let error as APIError {
                throw error
            } catch is CancellationError {
                throw APIError.cancelled
            } catch {
                throw APIError.localFileUnavailable
            }
            return HTTPResponse(statusCode: response.statusCode, headers: response.headers)
        }
    }

    /// Итератор кусков тела ответа: chunked раскодируется по кадрам,
    /// прочие ответы передаются как есть. EOF до конца chunked-тела —
    /// ошибка разбора, вместо догадки о его длине.
    private struct BodyPieceReader {

        private let session: Session
        private let chunked: Bool
        private var decoder = ChunkedBodyDecoder()
        private var pending: Data
        private var finished = false

        init(session: Session, response: HTTPResponse, remainder: Data) {
            self.session = session
            self.chunked = response.headers["Transfer-Encoding"]?.lowercased() == "chunked"
            self.pending = remainder
        }

        /// Следующий кусок тела; `nil` — тело дочитано. Пустой кусок — читаем
        /// дальше, EOF без данных сервер закрывать не обязан.
        mutating func next() async throws(APIError) -> Data? {
            if finished { return nil }
            if !chunked {
                if !pending.isEmpty {
                    let piece = pending
                    pending = Data()
                    return piece
                }
                guard let chunk = try await session.next() else {
                    finished = true
                    return nil
                }
                return chunk
            }
            while !decoder.isComplete {
                if !pending.isEmpty {
                    let decoded = try decoder.consume(pending)
                    pending = Data()
                    if !decoded.isEmpty { return decoded }
                    // Финальная порция закрыла тело пустым куском.
                    if decoder.isComplete { break }
                }
                guard let chunk = try await session.next() else { throw .malformedResponse }
                pending = chunk
            }
            finished = true
            return nil
        }
    }

    /// Поточный раскодировщик chunked-тела (RFC 9112 §7.1): серверы
    /// Time Messenger в HTTP/1.1 отвечают chunked даже без сжатия.
    struct ChunkedBodyDecoder {

        private enum Phase {
            case sizeLine
            case body(bytes: Int)
            case bodyTail
            case trailers
        }

        private var phase: Phase = .sizeLine
        private var buffer = Data()
        private(set) var isComplete = false

        private static let maximumLineBytes = 16 * 1024

        /// Скармливает очередную порцию кадрованных байт и возвращает
        /// содержащиеся в ней декодированные куски тела. Конец тела
        /// фиксирует `isComplete` (нулевой чанк и трейлеры разобраны).
        mutating func consume(_ input: Data) throws(APIError) -> Data {
            buffer.append(input)
            var decoded = Data()
            while !isComplete {
                switch phase {
                case .sizeLine:
                    guard let lineEnd = buffer.range(of: Data("\r\n".utf8)) else {
                        guard buffer.count <= Self.maximumLineBytes else { throw .malformedResponse }
                        return decoded
                    }
                    let line = String(decoding: buffer[buffer.startIndex..<lineEnd.lowerBound], as: UTF8.self)
                    let sizeText = line.split(separator: ";", omittingEmptySubsequences: false).first.map(String.init) ?? ""
                    guard let size = Int(sizeText, radix: 16), size >= 0 else { throw .malformedResponse }
                    buffer = Data(buffer[lineEnd.upperBound...])
                    phase = size == 0 ? .trailers : .body(bytes: size)
                case .body(let bytes):
                    guard buffer.count >= bytes else { return decoded }
                    decoded += buffer.prefix(bytes)
                    buffer = Data(buffer.dropFirst(bytes))
                    phase = .bodyTail
                case .bodyTail:
                    guard buffer.count >= 2 else { return decoded }
                    guard buffer.prefix(2) == Data("\r\n".utf8) else { throw .malformedResponse }
                    buffer = Data(buffer.dropFirst(2))
                    phase = .sizeLine
                case .trailers:
                    guard let lineEnd = buffer.range(of: Data("\r\n".utf8)) else {
                        guard buffer.count <= Self.maximumLineBytes else { throw .malformedResponse }
                        return decoded
                    }
                    let emptyLine = lineEnd.lowerBound == buffer.startIndex
                    buffer = Data(buffer[lineEnd.upperBound...])
                    if emptyLine { isComplete = true }
                }
            }
            return decoded
        }
    }

    /// Разбирает стартовую строку и заголовки; остаток после `\r\n\r\n` — тело.
    static func parseHead(_ head: Data) throws(APIError) -> (HTTPResponse, Data) {
        guard let separator = head.range(of: Data("\r\n\r\n".utf8)) else { throw .malformedResponse }
        let rawHead = String(decoding: head[head.startIndex..<separator.lowerBound], as: UTF8.self)
        let body = Data(head[separator.upperBound...])
        // У последней строки заголовков нет собственного CRLF — он принадлежит
        // разделителю, поэтому разбор идёт по строкам, а не до следующего CRLF.
        let lines = rawHead.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let statusLine = lines.first else { throw .malformedResponse }
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]),
              (100..<600).contains(status) else { throw .malformedResponse }
        var headers = HTTPHeaders()
        for line in lines.dropFirst() {
            guard !line.isEmpty else { continue }
            guard let colon = line.firstIndex(of: ":") else { throw .malformedResponse }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw .malformedResponse }
            headers.add(name, value)
        }
        // Chunked-тело допустимо и раскодируется при чтении: серверы
        // Time Messenger в HTTP/1.1 отвечают Transfer-Encoding: chunked
        // всегда, в том числе на несжатые ответы. Прочие транспортные
        // кодирования не поддерживаются.
        let transferEncoding = headers["Transfer-Encoding"]?.lowercased()
        if transferEncoding != nil, transferEncoding != "chunked" { throw .malformedResponse }
        return (HTTPResponse(statusCode: status, headers: headers), body)
    }

    // MARK: - Соединение

    private struct Session: Sendable {
        let connection: NWConnection
        /// Стартовая строка, заголовки и, возможно, начало тела.
        let head: Data

        /// Очередной блок тела; `nil` — EOF.
        func next() async throws(APIError) -> Data? {
            try await receiveChunk(connection)
        }
    }

    /// Открывает соединение, отправляет запрос, читает до конца заголовков,
    /// затем выполняет `operation`; в любом исходе соединение закрывается.
    private static func withConnection<Response: Sendable>(
        _ request: HTTPRequest,
        _ operation: @escaping @Sendable (Session) async throws(APIError) -> Response
    ) async throws(APIError) -> Response {
        let wire = try buildRequest(request)
        guard let host = request.url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(request.url.port ?? (request.url.scheme == "https" ? 443 : 80)))
        else { throw .notSent(.other(code: 0)) }
        let parameters: NWParameters = request.url.scheme == "https" ? .tls : .tcp
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        defer { connection.cancel() }
        return try await withTimeout(request.timeout) { () async throws(APIError) -> Response in
            // withTaskCancellationHandler хранит нетипизированный throws
            // (AGENTS.md: типизированные *типы* функций требуют macOS 15).
            do {
                return try await withTaskCancellationHandler {
                    try await start(connection: connection)
                    try await send(connection: connection, wire: wire)
                    let head = try await receiveHead(connection)
                    return try await operation(Session(connection: connection, head: head))
                } onCancel: {
                    connection.cancel()
                }
            } catch let error as APIError {
                throw error
            } catch is CancellationError {
                throw APIError.cancelled
            } catch {
                throw APIError.outcomeUnknown(.other(code: (error as NSError).code))
            }
        }
    }

    /// Текст запроса HTTP/1.1 без `Accept-Encoding` (это и есть суть обхода).
    static func buildRequest(_ request: HTTPRequest) throws(APIError) -> Data {
        guard var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false),
              let host = request.url.host
        else { throw .notSent(.other(code: 0)) }
        // MatterDock: кеш вариантов nginx хранит zstd-копию по адресу и
        // выдаёт её при любых заголовках. Уникальный параметр делает адрес
        // непопадающим в кеш (x-cache: MISS) — на промахе сервер отдаёт
        // несжатое тело. Шестнадцатеричное значение не требует экранирования.
        var query = components.percentEncodedQuery ?? ""
        if !query.isEmpty { query += "&" }
        query += "zcb=" + String(UInt32.random(in: .min ... .max), radix: 16)
        components.percentEncodedQuery = query
        let target = components.percentEncodedPath.isEmpty
            ? "/"
            : components.percentEncodedPath + (components.percentEncodedQuery.map { "?\($0)" } ?? "")
        var lines: [String] = ["GET \(target) HTTP/1.1"]
        let standardPort = request.url.scheme == "https" ? 443 : 80
        if let port = request.url.port, port != standardPort {
            lines.append("Host: \(host):\(port)")
        } else {
            lines.append("Host: \(host)")
        }
        if let credential = request.credential {
            lines.append("Authorization: \(credential.authorizationHeaderValue)")
        }
        for field in request.headers where !bannedHeaders.contains(field.name.lowercased()) {
            lines.append("\(field.name): \(field.value)")
        }
        lines.append("Connection: close")
        lines.append("")
        lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private static func start(connection: NWConnection) async throws(APIError) {
        try await awaitContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            // Продолжение срабатывает один раз (последовательная очередь
            // соединения не гарантирует единственность перехода состояния).
            let once = OSAllocatedUnfairLock(initialState: false)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.withLock { resumed in
                        if !resumed { resumed = true; continuation.resume() }
                    }
                case .failed(let error):
                    once.withLock { resumed in
                        if !resumed {
                            resumed = true
                            var mapped = TransportErrorMapping.map(error, requestTransmitted: false)
                            if case .outcomeUnknown = mapped { mapped = .notSent(.connectionLost) }
                            if case .cancelled = mapped { mapped = .notSent(.connectionLost) }
                            continuation.resume(throwing: mapped)
                        }
                    }
                case .cancelled:
                    once.withLock { resumed in
                        if !resumed { resumed = true; continuation.resume(throwing: APIError.cancelled) }
                    }
                case .setup, .preparing, .waiting:
                    break
                @unknown default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "com.matterdock.app.raw-zstd-bypass"))
        }
    }

    private static func send(connection: NWConnection, wire: Data) async throws(APIError) {
        try await awaitContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: wire, completion: .contentProcessed { error in
                if let error {
                    var mapped = TransportErrorMapping.map(error, requestTransmitted: nil)
                    if case .cancelled = mapped { mapped = .cancelled }
                    continuation.resume(throwing: mapped)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static func receiveHead(_ connection: NWConnection) async throws(APIError) -> Data {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)
        while buffer.range(of: separator) == nil {
            guard buffer.count <= maximumHeadBytes else { throw .malformedResponse }
            guard let chunk = try await receiveChunk(connection) else { throw .malformedResponse }
            buffer += chunk
        }
        return buffer
    }

    /// Очередной блок тела; `nil` — EOF.
    private static func receiveChunk(_ connection: NWConnection) async throws(APIError) -> Data? {
        try await awaitContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error, error.isCancellation {
                    continuation.resume(throwing: APIError.cancelled)
                } else if let error {
                    continuation.resume(throwing: TransportErrorMapping.map(error, requestTransmitted: true))
                } else {
                    // Пустой блок с isComplete — EOF; пустой блок без него —
                    // читаем дальше.
                    continuation.resume(returning: isComplete ? nil : Data())
                }
            }
        }
    }

    /// Гонка операции с общим таймаутом запроса; победа сна — ошибка,
    /// победа операции — отмена сна.
    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws(APIError) -> T
    ) async throws(APIError) -> T {
        do {
            return try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(for: .seconds(max(1, seconds)))
                    throw APIError.outcomeUnknown(.timedOut)
                }
                guard let first = try await group.next() else { throw APIError.cancelled }
                group.cancelAll()
                return first
            }
        } catch let error as APIError {
            throw error
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .malformedResponse
        }
    }

    /// Оборачивает нетипизированный checked continuation в `APIError`
    /// (функции типа — см. AGENTS.md: типизированные *типы* функций с throws
    /// требуют macOS 15 и не хранятся).
    private static func awaitContinuation<T: Sendable>(
        _ body: (CheckedContinuation<T, any Error>) -> Void
    ) async throws(APIError) -> T {
        do {
            return try await withCheckedThrowingContinuation(body)
        } catch let error as APIError {
            throw error
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .outcomeUnknown(.other(code: (error as NSError).code))
        }
    }
}

extension HTTPResponse {
    /// `Content-Length` ответа как `Int64`, если он указан и корректен.
    var contentLengthBytes: Int64? {
        guard let raw = headers["Content-Length"], let value = Int64(raw), value >= 0 else { return nil }
        return value
    }
}

extension NWError {
    /// Отмена соединения (в т.ч. нашей стороной) приходит как POSIX ECANCELED.
    var isCancellation: Bool {
        if case .posix(let code) = self, code == .ECANCELED { return true }
        return false
    }
}
