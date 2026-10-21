import Foundation
import MatterMacModels
@testable import MattermostAPI
import Testing
import TestSupport
import os

/// Проверяет MatterDock-fallback для серверов, отдающих медиа-тела в zstd
/// (решение docs/decisions/0039): текст запроса опускает `Accept-Encoding`,
/// подставляет уникальный параметр против кеша вариантов nginx, chunked-тела
/// раскодируются, body-лимиты соблюдаются.
@Suite("RawZstdBypass")
struct RawZstdBypassTests {
    static let token = BearerCredential(token: "abcdefghijklmnopqrstuvwxyz", kind: .session)!

    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03, 0x04])

    // MARK: Текст запроса

    @Test func wireRequestOmitsAcceptEncodingAndBustsVariantCache() throws {
        var headers: HTTPHeaders = ["Accept": "image/*"]
        headers.add("Accept-Encoding", "identity")
        headers.add("Range", "bytes=0-")
        let request = HTTPRequest(method: .get,
                                  url: URL(string: "https://chat.example.test/api/v4/users/abc/image?_=7")!,
                                  headers: headers, credential: Self.token)
        func requestLine() throws -> String {
            let wire = String(decoding: try RawZstdBypass.buildRequest(request), as: UTF8.self)
            return String(wire.split(separator: "\r\n").first ?? "")
        }
        // Уникальный `zcb` ведёт запрос мимо закешированного zstd-варианта:
        // адрес оканчивается новым шестнадцатеричным значением параметра.
        let lineA = try requestLine()
        let lineB = try requestLine()
        let pattern = #"GET /api/v4/users/abc/image\?_=7&zcb=[0-9a-f]{1,8} HTTP/1\.1"#
        #expect(lineA.range(of: pattern, options: .regularExpression) != nil)
        #expect(lineB.range(of: pattern, options: .regularExpression) != nil)
        #expect(lineA != lineB)
        let wire = String(decoding: try RawZstdBypass.buildRequest(request), as: UTF8.self)
        #expect(wire.contains("Host: chat.example.test\r\n"))
        #expect(wire.contains("Authorization: Bearer abcdefghijklmnopqrstuvwxyz\r\n"))
        #expect(wire.contains("Accept: image/*\r\n"))
        #expect(wire.contains("Range: bytes=0-\r\n"))
        #expect(wire.contains("Connection: close\r\n"))
        #expect(!wire.lowercased().contains("accept-encoding:"))
        #expect(wire.hasSuffix("\r\n\r\n"))
    }

    @Test func wireRequestKeepsNonStandardPort() throws {
        let request = HTTPRequest(method: .get,
                                  url: URL(string: "http://127.0.0.1:8065/company/chat/api/v4/users/me")!,
                                  credential: Self.token)
        let wire = String(decoding: try RawZstdBypass.buildRequest(request), as: UTF8.self)
        let line = String(wire.split(separator: "\r\n").first ?? "")
        #expect(line.range(of: #"GET /company/chat/api/v4/users/me\?zcb=[0-9a-f]{1,8} HTTP/1\.1"#,
                           options: .regularExpression) != nil)
        #expect(wire.contains("Host: 127.0.0.1:8065\r\n"))
    }

    // MARK: Разбор ответа

    @Test func parseHeadSplitsStatusHeadersAndBody() throws {
        let head = Data("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 12\r\n\r\n".utf8)
            + Data([0x89, 0x50])
        let (response, body) = try RawZstdBypass.parseHead(head)
        #expect(response.statusCode == 200)
        #expect(response.headers["Content-Type"] == "image/png")
        #expect(response.contentLengthBytes == 12)
        #expect(body == Data([0x89, 0x50]))
    }

    @Test func parseHeadRejectsMalformed() {
        #expect(throws: APIError.malformedResponse) {
            _ = try RawZstdBypass.parseHead(Data("garbage".utf8))
        }
        #expect(throws: APIError.malformedResponse) {
            _ = try RawZstdBypass.parseHead(Data("HTTP/1.1 notanumber\r\n\r\n".utf8))
        }
    }

    @Test func parseHeadAcceptsChunkedAndRejectsOtherTransferEncodings() throws {
        let chunked = Data("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nTransfer-Encoding: chunked\r\n\r\n1a".utf8)
        let (response, remainder) = try RawZstdBypass.parseHead(chunked)
        #expect(response.statusCode == 200)
        #expect(response.headers["Content-Type"] == "image/png")
        #expect(remainder == Data("1a".utf8))
        #expect(throws: APIError.malformedResponse) {
            _ = try RawZstdBypass.parseHead(
                Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n".utf8))
        }
    }

    // MARK: Раскодировщик chunked

    @Test func chunkedDecoderAssemblesFramedBody() throws {
        let frame = Data("4\r\nWiki\r\n6\r\npedia \r\n0\r\n\r\n".utf8)
        var decoder = RawZstdBypass.ChunkedBodyDecoder()
        let decoded = try decoder.consume(frame)
        #expect(decoded == Data("Wikipedia ".utf8))
        #expect(decoder.isComplete)
    }

    @Test func chunkedDecoderAcceptsByteByByteInputAndChunkExtensions() throws {
        // RFC-пример с расширением чанка и трейлером; байты приходят по одному.
        var decoder = RawZstdBypass.ChunkedBodyDecoder()
        var assembled = Data()
        for byte in Data("5;x\r\nHello\r\n0\r\nX-Checksum: 1\r\n\r\n".utf8) {
            assembled += try decoder.consume(Data([byte]))
        }
        #expect(assembled == Data("Hello".utf8))
        #expect(decoder.isComplete)
    }

    @Test func chunkedDecoderRejectsBadChunkSize() {
        #expect(throws: APIError.malformedResponse) {
            var decoder = RawZstdBypass.ChunkedBodyDecoder()
            _ = try decoder.consume(Data("zz\r\nab".utf8))
        }
    }

    @Test func chunkedDecoderRejectsMissingChunkTail() {
        #expect(throws: APIError.malformedResponse) {
            var decoder = RawZstdBypass.ChunkedBodyDecoder()
            _ = try decoder.consume(Data("2\r\nabXX\r\n".utf8))
        }
    }

    // MARK: Живой обмен по loopback

    @Test func fetchesBodyAndSendsNoAcceptEncoding() async throws {
        let server = try await LocalHTTPServer.start(handler: { _ in
            var headers: HTTPHeaders = ["Content-Type": "image/png"]
            headers.set("Content-Length", String(Self.png.count))
            return LocalHTTPServer.Response(status: 200, headers: headers, body: .data(Self.png))
        })
        defer { server.stop() }
        let request = HTTPRequest(method: .get, url: server.endpoint().url(path: ["api", "v4", "users", "abc", "image"]),
                                  headers: ["Accept": "image/*"], credential: Self.token)
        let response = try await RawZstdBypass.fetch(request, limits: ResponseLimits(maximumBodyBytes: 1024))
        #expect(response.statusCode == 200)
        #expect(response.mediaType == "image/png")
        #expect(response.body == Self.png)
        let sent = server.requests
        #expect(sent.first?.headers["Accept-Encoding"] == nil)
        #expect(sent.first?.headers["Authorization"] == "Bearer abcdefghijklmnopqrstuvwxyz")
        #expect(sent.first?.queryValue("zcb") != nil)
    }

    // MARK: Chunked-обмен

    @Test func fetchDecodesChunkedBody() async throws {
        let tail = Data([0x05, 0x06])
        let server = try await LocalHTTPServer.start(handler: { _ in
            LocalHTTPServer.Response(status: 200, headers: ["Content-Type": "image/png"],
                                     body: .chunked([Self.png, tail], pause: .milliseconds(10)))
        })
        defer { server.stop() }
        let request = HTTPRequest(method: .get, url: server.endpoint().url(path: ["img"]),
                                  headers: ["Accept": "image/*"], credential: Self.token)
        let response = try await RawZstdBypass.fetch(request, limits: ResponseLimits(maximumBodyBytes: 1024))
        #expect(response.statusCode == 200)
        #expect(response.mediaType == "image/png")
        #expect(response.body == Self.png + tail)
    }

    @Test func chunkedFetchEnforcesBodyLimit() async throws {
        let server = try await LocalHTTPServer.start(handler: { _ in
            LocalHTTPServer.Response(status: 200, headers: ["Content-Type": "image/png"],
                                     body: .chunked([Self.png], pause: nil))
        })
        defer { server.stop() }
        let request = HTTPRequest(method: .get, url: server.endpoint().url(path: ["img"]), credential: Self.token)
        await #expect(throws: APIError.responseTooLarge(limitBytes: 4)) {
            _ = try await RawZstdBypass.fetch(request, limits: ResponseLimits(maximumBodyBytes: 4))
        }
    }

    @Test func fetchEnforcesBodyLimit() async throws {
        let server = try await LocalHTTPServer.start(handler: { _ in
            var headers: HTTPHeaders = ["Content-Type": "image/png"]
            headers.set("Content-Length", String(Self.png.count))
            return LocalHTTPServer.Response(status: 200, headers: headers, body: .data(Self.png))
        })
        defer { server.stop() }
        let request = HTTPRequest(method: .get, url: server.endpoint().url(path: ["img"]), credential: Self.token)
        await #expect(throws: APIError.responseTooLarge(limitBytes: 4)) {
            _ = try await RawZstdBypass.fetch(request, limits: ResponseLimits(maximumBodyBytes: 4))
        }
    }

    @Test func transferWritesBodyToFileHandle() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("matterdock-bypass-\(UUID().uuidString).bin")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        let progressLog = OSAllocatedUnfairLock(initialState: [TransferProgress]())
        let server = try await LocalHTTPServer.start(handler: { _ in
            var headers: HTTPHeaders = ["Content-Type": "application/octet-stream"]
            headers.set("Content-Length", String(Self.png.count))
            return LocalHTTPServer.Response(status: 200, headers: headers, body: .data(Self.png))
        })
        defer { server.stop() }
        let request = HTTPRequest(method: .get, url: server.endpoint().url(path: ["files", "x"], query: [URLQueryItem(name: "download", value: "1")]),
                                  credential: Self.token, timeout: HTTPRequest.transferTimeout)
        let response = try await RawZstdBypass.transfer(request, to: handle,
                                                        limits: ResponseLimits(maximumBodyBytes: Int64.max)) { p in
            progressLog.withLock { state in state.append(p) }
        }
        try handle.close()
        let progress = progressLog.withLock { $0 }
        #expect(response.statusCode == 200)
        #expect(response.body.isEmpty)
        #expect(progress.last?.completedBytes == Int64(Self.png.count))
        #expect(progress.last?.totalBytes == Int64(Self.png.count))
        #expect(try Data(contentsOf: url) == Self.png)
    }

    @Test func transferDecodesChunkedBodyToFileHandle() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("matterdock-bypass-\(UUID().uuidString).bin")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        let progressLog = OSAllocatedUnfairLock(initialState: [TransferProgress]())
        let server = try await LocalHTTPServer.start(handler: { _ in
            LocalHTTPServer.Response(status: 200, headers: ["Content-Type": "application/octet-stream"],
                                     body: .chunked([Self.png, Self.png], pause: .milliseconds(10)))
        })
        defer { server.stop() }
        let request = HTTPRequest(method: .get, url: server.endpoint().url(path: ["files", "x"]),
                                  credential: Self.token, timeout: HTTPRequest.transferTimeout)
        let response = try await RawZstdBypass.transfer(request, to: handle,
                                                        limits: ResponseLimits(maximumBodyBytes: Int64.max)) { p in
            progressLog.withLock { state in state.append(p) }
        }
        try handle.close()
        let progress = progressLog.withLock { $0 }
        #expect(response.statusCode == 200)
        // У chunked-ответов общего размера нет — только принятые байты.
        #expect(progress.last?.completedBytes == Int64(Self.png.count * 2))
        #expect(progress.last?.totalBytes == nil)
        #expect(try Data(contentsOf: url) == Self.png + Self.png)
    }
}
