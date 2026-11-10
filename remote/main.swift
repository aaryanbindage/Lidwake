// lidwaked — LidWake's remote control server. Serves the web UI and a small JSON
// API that forwards to the `lidwake` CLI, so any browser can stop a session or
// add events. For access from anywhere it either connects out to a LidWake
// relay (PUBLIC=relay, end-to-end encrypted, permanent link — see relay/) or
// runs a Cloudflare quick tunnel (PUBLIC=cloudflare); Tailscale Funnel is set
// up by `lidwake remote --public tailscale` instead. Ends a session if the Mac
// overheats. Runs as a LaunchAgent; direct /api calls need the token from
// `lidwake remote`.
import CryptoKit
import Foundation
import Network

let cliPath = "/usr/local/bin/lidwake"
let webRoot = "/usr/local/share/lidwake/index.html"
let stateDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/LidWake")
let queue = DispatchQueue(label: "lidwaked", attributes: .concurrent)

func logLine(_ message: String) {
    FileHandle.standardError.write(Data("\(Date()) lidwaked: \(message)\n".utf8))
}

func config(_ key: String) -> String? {
    guard let text = try? String(contentsOf: stateDir.appendingPathComponent("config"), encoding: .utf8)
    else { return nil }
    return text.split(separator: "\n").last { $0.hasPrefix(key + "=") }
        .map { String($0.dropFirst(key.count + 1)) }
}

func runCLI(_ args: [String]) -> (code: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cliPath)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, error.localizedDescription) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

// MARK: - HTTP

struct Request {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

struct Response {
    var status: Int
    var contentType: String
    var body: Data

    static func json(_ status: Int, _ object: [String: Any]) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return Response(status: status, contentType: "application/json", body: data)
    }

    static func error(_ status: Int, _ message: String) -> Response {
        json(status, ["error": message])
    }
}

/// Returns nil until a full request (headers + Content-Length body) is buffered.
func parseRequest(_ data: Data) -> Request? {
    guard let sep = data.range(of: Data("\r\n\r\n".utf8)),
          let head = String(data: data[data.startIndex..<sep.lowerBound], encoding: .utf8)
    else { return nil }
    var lines = head.components(separatedBy: "\r\n")
    let requestLine = lines.removeFirst().split(separator: " ")
    guard requestLine.count >= 2 else { return nil }
    var headers: [String: String] = [:]
    for line in lines {
        guard let colon = line.firstIndex(of: ":") else { continue }
        headers[line[..<colon].lowercased()] =
            line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    let length = Int(headers["content-length"] ?? "") ?? 0
    guard data.distance(from: sep.upperBound, to: data.endIndex) >= length else { return nil }
    let bodyStart = sep.upperBound
    let body = data.subdata(in: bodyStart..<data.index(bodyStart, offsetBy: length))
    let path = requestLine[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
    return Request(method: String(requestLine[0]), path: path, headers: headers, body: body)
}

final class Client {
    private let connection: NWConnection
    private var buffer = Data()

    init(_ connection: NWConnection) { self.connection = connection }

    func start() {
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
            if let data { self.buffer.append(data) }
            if self.buffer.count > 256 * 1024 { return self.connection.cancel() }
            if let request = parseRequest(self.buffer) { return self.send(handle(request)) }
            if done || error != nil { return self.connection.cancel() }
            self.receive()
        }
    }

    private func send(_ response: Response) {
        let reasons = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
                       429: "Too Many Requests", 500: "Internal Server Error"]
        let head = "HTTP/1.1 \(response.status) \(reasons[response.status] ?? "OK")\r\n"
            + "Content-Type: \(response.contentType)\r\n"
            + "Content-Length: \(response.body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "X-Content-Type-Options: nosniff\r\n"
            + "X-Frame-Options: DENY\r\n"
            + "Referrer-Policy: no-referrer\r\n"
            + "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in
            self.connection.cancel()
        })
    }
}

// MARK: - API

// The page can be on the public internet, so throttle token guessing: after 20
// wrong tokens in a minute, every API call is refused until the minute passes.
let authLock = NSLock()
var authFailures: [Date] = []

func authLockedOut() -> Bool {
    authLock.lock(); defer { authLock.unlock() }
    let cutoff = Date().addingTimeInterval(-60)
    authFailures.removeAll { $0 < cutoff }
    return authFailures.count >= 20
}

func recordAuthFailure() {
    authLock.lock(); defer { authLock.unlock() }
    authFailures.append(Date())
}

func authorized(_ request: Request) -> Bool {
    guard let token = try? String(contentsOf: stateDir.appendingPathComponent("remote.token"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty
    else { return false }
    let given = Array((request.headers["authorization"] ?? "").utf8)
    let expected = Array("Bearer \(token)".utf8)
    guard given.count == expected.count else { return false }
    return zip(given, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
}

/// Event arguments from the web UI. `--cmd` is refused: it would turn the token into a remote shell.
func eventArgs(_ body: [String: Any]) -> [String]? {
    guard let args = body["args"] as? [String] else { return [] }
    let blocked: Set<String> = ["--cmd", "-b", "--background"]
    return args.contains(where: blocked.contains) ? nil : args
}

func status() -> Response {
    let (code, output) = runCLI(["status", "--json"])
    guard code == 0 else { return .error(500, output) }
    return Response(status: 200, contentType: "application/json", body: Data(output.utf8))
}

func command(_ args: [String]) -> Response {
    let (code, output) = runCLI(args)
    guard code == 0 else {
        let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "lidwake: ", with: "")
        return .error(400, message.isEmpty ? "command failed" : message)
    }
    return status()
}

func handle(_ request: Request) -> Response {
    if request.method == "GET" && (request.path == "/" || request.path == "/index.html") {
        guard let html = FileManager.default.contents(atPath: webRoot) else {
            return .error(500, "web UI missing at \(webRoot)")
        }
        return Response(status: 200, contentType: "text/html; charset=utf-8", body: html)
    }
    guard request.path.hasPrefix("/api/") else { return .error(404, "not found") }
    guard !authLockedOut() else { return .error(429, "too many wrong tokens — try again in a minute") }
    guard authorized(request) else {
        recordAuthFailure()
        return .error(401, "missing or wrong token")
    }
    let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
    return route(request.method, request.path, body)
}

/// The API itself, shared by direct requests (token-checked above) and relay
/// requests (authenticated by decrypting with the relay key).
func route(_ method: String, _ path: String, _ body: [String: Any]) -> Response {
    let id = (body["id"] as? Int).map(String.init) ?? ""

    switch (method, path) {
    case ("GET", "/api/status"):
        return status()
    case ("POST", "/api/start"):
        guard let args = eventArgs(body) else { return .error(400, "that event can't be used remotely") }
        return command(["start", "--background"] + args)
    case ("POST", "/api/add"):
        guard let args = eventArgs(body) else { return .error(400, "that event can't be used remotely") }
        return command(["add"] + args)
    case ("POST", "/api/remove"):
        return command(["remove", id])
    case ("POST", "/api/extend"):
        return command(["extend", id, body["by"] as? String ?? "30m"])
    case ("POST", "/api/then"):
        return command(["set", "then", body["action"] as? String ?? ""])
    case ("POST", "/api/stop"):
        return command(["stop"])
    case ("POST", "/api/end"):
        return command(["end"])
    default:
        return .error(404, "unknown endpoint")
    }
}

// MARK: - main

let portNumber = UInt16(config("REMOTE_PORT") ?? "") ?? 7878
guard let port = NWEndpoint.Port(rawValue: portNumber) else { fatalError("bad port") }

_ = runCLI(["remote", "--url"])   // makes sure a token exists

let listener: NWListener
do {
    listener = try NWListener(using: .tcp, on: port)
} catch {
    logLine("can't listen on port \(portNumber): \(error)")
    exit(1)
}
listener.newConnectionHandler = { Client($0).start() }
listener.stateUpdateHandler = { state in
    switch state {
    case .ready: logLine("listening on port \(portNumber)")
    case .failed(let error): logLine("listener failed: \(error)"); exit(1)   // launchd restarts us
    default: break
    }
}
listener.start(queue: queue)

// MARK: - public tunnel

let publicURLFile = stateDir.appendingPathComponent("public.url")
var tunnel: Process?

/// cloudflared's output so far (the URL can arrive split across reads).
final class TunnelScan {
    var output = ""
    var found = false
}

/// Runs `cloudflared` as a quick tunnel to this server and records its https URL.
/// Restarts it if it exits; the URL changes each time cloudflared restarts.
func runTunnel() {
    let candidates = ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"]
    guard let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        logLine("PUBLIC=cloudflare but cloudflared isn't installed (brew install cloudflared)")
        return
    }
    try? FileManager.default.removeItem(at: publicURLFile)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: bin)
    p.arguments = ["tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:\(portNumber)"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    let scan = TunnelScan()
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        guard !scan.found else { return }
        scan.output = String((scan.output + String(decoding: chunk, as: UTF8.self)).suffix(8192))
        guard let range = scan.output.range(of: #"https://[a-z0-9-]+\.trycloudflare\.com"#, options: .regularExpression)
        else { return }
        scan.found = true
        let url = String(scan.output[range]) + "/"
        try? url.write(to: publicURLFile, atomically: true, encoding: .utf8)
        logLine("public URL: \(url)")
        // No token in the push: an ntfy topic isn't secret enough for it.
        _ = runCLI(["_notify", "Remote control is now at \(url)"])
    }
    p.terminationHandler = { _ in
        pipe.fileHandleForReading.readabilityHandler = nil
        try? FileManager.default.removeItem(at: publicURLFile)
        logLine("cloudflared exited; restarting in 10s")
        queue.asyncAfter(deadline: .now() + 10) { runTunnel() }
    }
    do {
        try p.run()
        tunnel = p
    } catch {
        logLine("couldn't start cloudflared: \(error)")
    }
}

// MARK: - relay (e.g. on Render)

/// Connects out to a LidWake relay so a browser anywhere can reach this Mac at a
/// permanent address. The relay only passes along opaque blobs: requests and
/// replies are sealed with AES-256-GCM using a key that only this Mac and the
/// link's #fragment hold, so the relay can't read, forge or alter them. Each
/// request carries a timestamp and a single-use nonce, which the reply echoes.
final class RelayClient {
    private let base: URL
    private let secret: String
    private let key: SymmetricKey
    private let session: URLSession
    private let lock = NSLock()
    private var seenNonces: [String: Date] = [:]
    private var failures = 0

    init?(base: String, secret: String, key: String) {
        var b64 = key.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let url = URL(string: base), let keyData = Data(base64Encoded: b64), keyData.count == 32,
              !secret.isEmpty else { return nil }
        self.base = url
        self.secret = secret
        self.key = SymmetricKey(data: keyData)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        session = URLSession(configuration: config)
    }

    func start() {
        logLine("relay: connecting to \(base.absoluteString)")
        poll()
    }

    /// Long-poll: the relay holds the request open until a browser sends something (or ~25s pass).
    private func poll() {
        var request = URLRequest(url: base.appendingPathComponent("agent/poll"))
        request.setValue(secret, forHTTPHeaderField: "X-Agent-Secret")
        session.dataTask(with: request) { data, response, error in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let requests = object["requests"] as? [[String: Any]]
            else {
                // Relay down, cold-starting (Render free tier) or no network: back off up to 30s.
                self.failures += 1
                if self.failures == 3 { logLine("relay: unreachable (\(error?.localizedDescription ?? "bad response")), retrying") }
                let delay = min(30.0, pow(2.0, Double(self.failures)))
                queue.asyncAfter(deadline: .now() + delay) { self.poll() }
                return
            }
            if self.failures >= 3 { logLine("relay: connected") }
            self.failures = 0
            for item in requests { queue.async { self.process(item) } }
            self.poll()
        }.resume()
    }

    private func process(_ item: [String: Any]) {
        guard let id = item["id"] as? String, let sealed = item["data"] as? String else { return }
        guard let plain = open(sealed),
              let message = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
              let nonce = message["nonce"] as? String, let sentAt = message["ts"] as? Double,
              let method = message["method"] as? String, let path = message["path"] as? String
        else { return reply(["id": id, "error": "undecryptable"]) }
        guard abs(Date().timeIntervalSince1970 - sentAt / 1000) < 120, isFresh(nonce) else {
            return reply(["id": id, "error": "stale"])
        }
        let response = route(method, path, message["body"] as? [String: Any] ?? [:])
        let body = (try? JSONSerialization.jsonObject(with: response.body)) ?? ["error": "bad response"]
        let answer: [String: Any] = ["nonce": nonce, "status": response.status, "body": body]
        guard let answerData = try? JSONSerialization.data(withJSONObject: answer),
              let sealedAnswer = seal(answerData) else { return }
        reply(["id": id, "data": sealedAnswer])
    }

    private func reply(_ payload: [String: Any]) {
        var request = URLRequest(url: base.appendingPathComponent("agent/reply"))
        request.httpMethod = "POST"
        request.setValue(secret, forHTTPHeaderField: "X-Agent-Secret")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        session.dataTask(with: request).resume()
    }

    /// Rejects a nonce seen in the last 5 minutes, so a captured request can't be replayed.
    private func isFresh(_ nonce: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let cutoff = Date().addingTimeInterval(-300)
        seenNonces = seenNonces.filter { $0.value > cutoff }
        guard seenNonces[nonce] == nil else { return false }
        seenNonces[nonce] = Date()
        return true
    }

    // Wire format: base64(nonce[12] | ciphertext | tag[16]) — what WebCrypto produces with the IV prepended.
    private func seal(_ data: Data) -> String? {
        (try? AES.GCM.seal(data, using: key))?.combined?.base64EncodedString()
    }

    private func open(_ text: String) -> Data? {
        guard let data = Data(base64Encoded: text), let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }
}

var relay: RelayClient?

func readState(_ name: String) -> String {
    (try? String(contentsOf: stateDir.appendingPathComponent(name), encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

switch config("PUBLIC") {
case "cloudflare":
    runTunnel()
case "relay":
    relay = RelayClient(base: config("RELAY_URL") ?? "", secret: readState("relay.secret"), key: readState("relay.key"))
    if let relay { relay.start() } else { logLine("relay: missing RELAY_URL or keys — run: lidwake remote --public relay URL") }
default:
    break
}

// Thermal guard: a closed laptop can't vent through the keyboard, so end the session if it gets critical.
let thermalTimer = DispatchSource.makeTimerSource(queue: queue)
thermalTimer.schedule(deadline: .now() + 10, repeating: 10)
thermalTimer.setEventHandler {
    if ProcessInfo.processInfo.thermalState == .critical {
        _ = runCLI(["signal", "thermal"])
    }
}
thermalTimer.resume()

dispatchMain()
