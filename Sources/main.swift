// OX Link: lets the OX Tone Recall add-on in LUNA reach an OX Amp Top Box on the local network.
//
// LUNA only lets an add-on page connect to this computer, so OX Link listens on this computer
// (loopback only, port LINK_PORT) and passes the page's messages to the OX and back. It finds
// OXes the way macOS does, by their network name (Bonjour, _uadevice._tcp), and checks each one
// really is an OX before using it. It only connects to OXes, only on the OX's two ports, and
// only accepts pages from the OX Tone Recall add-on (or local development pages and non-browser
// tools on this computer), so a website in a browser can't reach the OX through it.
//
// Protocol: the page opens ws://127.0.0.1:LINK_PORT and sends one JSON hello.
//   {"op":"list"}                               -> {"app","version","state","devices":[{name,host,address}]}
//   {"op":"connect","host":"OX001234","port":4740} -> {"ok":true}, then every message in either
//                                                  direction is passed through unchanged.
//   A refused request answers {"ok":false,"error":"..."} and closes.

import AppKit
import Network
import ServiceManagement

let LINK_PORT: UInt16 = 47474
let OX_PORTS: Set<UInt16> = [4740, 4718] // the OX's audio engine and its device service
let ADD_ON_ORIGINS: Set<String> = ["ua-content://com.shawnrasson.ox-tone-recall"]
let VERSION = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
let LOG_URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/OX Link.log")

func log(_ line: String) {
  let stamp = ISO8601DateFormatter().string(from: Date())
  let text = "\(stamp) \(line)\n"
  NSLog("%@", line)
  if let handle = try? FileHandle(forWritingTo: LOG_URL) {
    handle.seekToEndOfFile()
    handle.write(text.data(using: .utf8)!)
    try? handle.close()
  } else {
    try? text.data(using: .utf8)!.write(to: LOG_URL)
  }
}

/// Pages allowed to use OX Link: the OX Tone Recall add-on in LUNA, pages served from this
/// computer while developing, and tools that send no Origin at all (not browsers).
func originAllowed(_ origin: String?) -> Bool {
  guard let origin = origin?.lowercased() else { return true }
  if ADD_ON_ORIGINS.contains(origin) { return true }
  guard let url = URL(string: origin), let scheme = url.scheme, ["http", "https"].contains(scheme) else { return false }
  return ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")
}

// MARK: - WebSocket helpers

func webSocketParameters() -> NWParameters {
  let ws = NWProtocolWebSocket.Options()
  ws.autoReplyPing = true
  let params = NWParameters.tcp
  params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
  return params
}

func sendText(_ connection: NWConnection, _ text: String, then: (() -> Void)? = nil) {
  let meta = NWProtocolWebSocket.Metadata(opcode: .text)
  let context = NWConnection.ContentContext(identifier: "text", metadata: [meta])
  connection.send(content: text.data(using: .utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in then?() })
}

/// The next text message, or nil when the connection closed or failed. Other frames are skipped.
func receiveText(_ connection: NWConnection, _ handler: @escaping (String?) -> Void) {
  connection.receiveMessage { data, context, _, error in
    if error != nil { return handler(nil) }
    let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
    if meta?.opcode == .close { return handler(nil) }
    if meta?.opcode == .text, let data, let text = String(data: data, encoding: .utf8) { return handler(text) }
    if data == nil && meta == nil { return handler(nil) }
    receiveText(connection, handler) // ping, pong or binary: keep reading
  }
}

func json(_ object: [String: Any]) -> String {
  let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
  return String(data: data, encoding: .utf8) ?? "{}"
}

// MARK: - Finding OXes

struct OX {
  let name: String
  var host: String { "\(name).local" }
  var address: String?
  var verified: Bool
}

/// Is there an OX at `host`? One read-only request for the cab, mic and room section, which only an
/// OX has. Calls back with the answer and the address it connected to.
func probeOX(host: String, done: @escaping (Bool, String?) -> Void) {
  let queue = DispatchQueue(label: "ox-link.probe")
  guard let url = URL(string: "ws://\(host):4740/") else { return done(false, nil) }
  let connection = NWConnection(to: .url(url), using: webSocketParameters())
  var finished = false
  func finish(_ ok: Bool) {
    if finished { return }
    finished = true
    var address: String?
    if case let .hostPort(h, _)? = connection.currentPath?.remoteEndpoint {
      address = "\(h)".components(separatedBy: "%").first
    }
    connection.cancel()
    done(ok, address)
  }
  connection.stateUpdateHandler = { state in
    switch state {
    case .ready:
      sendText(connection, "get /device/inputs/cabinet_mic_room?message_id=1")
      receiveText(connection) { text in
        queue.async {
          guard let text, let data = text.data(using: .utf8),
                let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return finish(false) }
          let error = reply["error"]
          finish((error == nil || error is NSNull) && reply["data"] != nil && !(reply["data"] is NSNull))
        }
      }
    case .failed, .cancelled: finish(false)
    default: break
    }
  }
  connection.start(queue: queue)
  queue.asyncAfter(deadline: .now() + 6) { finish(false) }
}

final class Discovery {
  private(set) var devices: [String: OX] = [:] // by lowercased name
  private(set) var state = "Starting"
  var onChange: () -> Void = {}
  private var browser: NWBrowser?
  private var timer: Timer?

  var oxes: [OX] { devices.values.filter(\.verified).sorted { $0.name < $1.name } }

  func start() {
    let browser = NWBrowser(for: .bonjour(type: "_uadevice._tcp", domain: "local."), using: NWParameters())
    browser.stateUpdateHandler = { [weak self] state in
      DispatchQueue.main.async {
        switch state {
        case .ready: self?.state = "Looking for an OX on this network"
        case let .waiting(error): self?.state = "Waiting for permission to use the local network (\(error.localizedDescription))"
        case let .failed(error): self?.state = "Can't search the network: \(error.localizedDescription)"
        default: break
        }
        log("Search: \(self?.state ?? "")")
        self?.onChange()
      }
    }
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      DispatchQueue.main.async { self?.update(results) }
    }
    browser.start(queue: .main)
    self.browser = browser
    // An OX that was still starting up when it appeared is checked again.
    timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.recheck() }
  }

  private func update(_ results: Set<NWBrowser.Result>) {
    var seen = Set<String>()
    for result in results {
      guard case let .service(name, _, _, _) = result.endpoint else { continue }
      let key = name.lowercased()
      seen.insert(key)
      if devices[key] == nil {
        devices[key] = OX(name: name, address: nil, verified: false)
        check(key)
      }
    }
    for key in devices.keys where !seen.contains(key) {
      log("\(devices[key]?.name ?? key) left the network")
      devices[key] = nil
    }
    onChange()
  }

  private func recheck() {
    for (key, device) in devices where !device.verified { check(key) }
  }

  private func check(_ key: String) {
    guard let device = devices[key] else { return }
    probeOX(host: device.host) { ok, address in
      DispatchQueue.main.async {
        guard var current = self.devices[key] else { return }
        current.verified = ok
        current.address = address ?? current.address
        self.devices[key] = current
        log(ok ? "Found \(current.name) at \(address ?? "?")" : "\(current.name) isn't answering as an OX (yet)")
        self.onChange()
      }
    }
  }

  /// The OX a page asked for, by name ("OX001234"), network name ("ox001234.local") or address.
  func lookup(_ host: String) -> OX? {
    let h = host.lowercased()
    return oxes.first { $0.name.lowercased() == h || $0.host.lowercased() == h || $0.address == h }
  }
}

// MARK: - The local server

final class Session {
  private let client: NWConnection
  private weak var server: LinkServer?
  private var upstream: NWConnection?
  private var connecting = false
  private var closed = false

  init(client: NWConnection, server: LinkServer) {
    self.client = client
    self.server = server
  }

  func start() {
    client.stateUpdateHandler = { [weak self] state in
      switch state {
      case .failed, .cancelled: self?.close()
      default: break
      }
    }
    client.start(queue: .main)
    readClient()
  }

  private func readClient() {
    receiveText(client) { [weak self] text in
      guard let self, !self.closed else { return }
      guard let text else { return self.close() }
      if let upstream = self.upstream { sendText(upstream, text) }
      else if !self.connecting { self.hello(text) }
      self.readClient()
    }
  }

  private func readUpstream() {
    guard let upstream else { return }
    receiveText(upstream) { [weak self] text in
      guard let self, !self.closed else { return }
      guard let text else { return self.close() }
      sendText(self.client, text)
      self.readUpstream()
    }
  }

  private func hello(_ text: String) {
    guard let server, let data = text.data(using: .utf8),
          let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let op = request["op"] as? String else { return fail("Expected {\"op\": ...} first") }
    switch op {
    case "list":
      sendText(client, server.listJSON())
    case "connect":
      guard let host = request["host"] as? String, let port = (request["port"] as? NSNumber)?.uint16Value else { return fail("connect needs host and port") }
      guard OX_PORTS.contains(port) else { return fail("OX Link only connects to the OX's ports 4740 and 4718") }
      guard let ox = server.discovery.lookup(host) else { return fail("No OX called \(host) on this network") }
      guard let url = URL(string: "ws://\(ox.address ?? ox.host):\(port)/") else { return fail("Bad address") }
      connecting = true
      let up = NWConnection(to: .url(url), using: webSocketParameters())
      up.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        switch state {
        case .ready:
          self.connecting = false
          self.upstream = up
          sendText(self.client, "{\"ok\":true}")
          self.readUpstream()
        case .failed, .cancelled:
          if self.connecting { self.fail("Couldn't reach \(ox.name)") } else { self.close() }
        default: break
        }
      }
      up.start(queue: .main)
      DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
        if self?.connecting == true { up.cancel(); self?.fail("\(ox.name) didn't answer") }
      }
    default:
      fail("Unknown request \(op)")
    }
  }

  private func fail(_ message: String) {
    connecting = false
    sendText(client, json(["ok": false, "error": message])) { [weak self] in
      DispatchQueue.main.async { self?.close() }
    }
  }

  func close() {
    if closed { return }
    closed = true
    upstream?.cancel()
    client.cancel()
    server?.remove(self)
  }
}

final class LinkServer {
  let discovery: Discovery
  private var listener: NWListener?
  private var sessions: [ObjectIdentifier: Session] = [:]
  private(set) var error: String?
  var onChange: () -> Void = {}

  var sessionCount: Int { sessions.count }

  init(discovery: Discovery) { self.discovery = discovery }

  func start() {
    let ws = NWProtocolWebSocket.Options()
    ws.autoReplyPing = true
    ws.setClientRequestHandler(.main) { _, headers in
      let origin = headers.first { $0.name.lowercased() == "origin" }?.value
      if originAllowed(origin) { return .init(status: .accept, subprotocol: nil) }
      log("Refused a page from \(origin ?? "?")")
      return .init(status: .reject, subprotocol: nil)
    }
    let params = NWParameters.tcp
    params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
    params.requiredInterfaceType = .loopback // this computer only
    params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: LINK_PORT)!)
    params.allowLocalEndpointReuse = true
    do {
      let listener = try NWListener(using: params)
      listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
      listener.stateUpdateHandler = { [weak self] state in
        DispatchQueue.main.async {
          if case let .failed(e) = state { self?.error = "Can't listen on port \(LINK_PORT): \(e.localizedDescription)"; log(self?.error ?? "") }
          if case .ready = state { self?.error = nil; log("Listening on 127.0.0.1:\(LINK_PORT)") }
          self?.onChange()
        }
      }
      listener.start(queue: .main)
      self.listener = listener
    } catch {
      self.error = "Can't listen on port \(LINK_PORT): \(error.localizedDescription)"
      log(self.error ?? "")
    }
  }

  private func accept(_ connection: NWConnection) {
    let session = Session(client: connection, server: self)
    sessions[ObjectIdentifier(session)] = session
    session.start()
    onChange()
  }

  func remove(_ session: Session) {
    sessions[ObjectIdentifier(session)] = nil
    onChange()
  }

  func listJSON() -> String {
    json([
      "app": "OX Link",
      "version": VERSION,
      "state": discovery.state,
      "devices": discovery.oxes.map { ["name": $0.name, "host": $0.host, "address": $0.address ?? ""] },
    ])
  }
}

// MARK: - Menu bar

final class AppDelegate: NSObject, NSApplicationDelegate {
  let discovery = Discovery()
  lazy var server = LinkServer(discovery: discovery)
  private var item: NSStatusItem!

  func applicationDidFinishLaunching(_ notification: Notification) {
    log("OX Link \(VERSION) starting")
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let image = NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: "OX Link") {
      image.isTemplate = true
      item.button?.image = image
    } else {
      item.button?.title = "OX"
    }
    discovery.onChange = { [weak self] in self?.rebuildMenu() }
    server.onChange = { [weak self] in self?.rebuildMenu() }
    server.start()
    discovery.start()
    startAtLoginFirstTime()
    rebuildMenu()
  }

  /// The first time it runs, OX Link asks to start at login, so it is there whenever LUNA is.
  private func startAtLoginFirstTime() {
    let key = "didOfferStartAtLogin"
    guard !UserDefaults.standard.bool(forKey: key) else { return }
    UserDefaults.standard.set(true, forKey: key)
    do { try SMAppService.mainApp.register(); log("Set to start at login") }
    catch { log("Couldn't set start at login: \(error.localizedDescription)") }
  }

  private func rebuildMenu() {
    let menu = NSMenu()
    menu.autoenablesItems = false
    let title = NSMenuItem(title: "OX Link \(VERSION)", action: nil, keyEquivalent: "")
    title.isEnabled = false
    menu.addItem(title)
    if let error = server.error {
      menu.addItem(disabled(error))
    } else if discovery.oxes.isEmpty {
      menu.addItem(disabled(discovery.state))
    } else {
      for ox in discovery.oxes { menu.addItem(disabled("\(ox.name)  ·  \(ox.address ?? ox.host)")) }
    }
    if server.sessionCount > 0 { menu.addItem(disabled("In use by OX Tone Recall")) }
    menu.addItem(.separator())
    let login = NSMenuItem(title: "Start at Login", action: #selector(toggleStartAtLogin), keyEquivalent: "")
    login.target = self
    login.state = SMAppService.mainApp.status == .enabled ? .on : .off
    menu.addItem(login)
    let logItem = NSMenuItem(title: "Show Log", action: #selector(showLog), keyEquivalent: "")
    logItem.target = self
    menu.addItem(logItem)
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Quit OX Link", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    item.menu = menu
    item.button?.toolTip = discovery.oxes.isEmpty ? "OX Link: no OX found yet" : "OX Link: \(discovery.oxes.map(\.name).joined(separator: ", "))"
  }

  private func disabled(_ text: String) -> NSMenuItem {
    let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
  }

  @objc private func toggleStartAtLogin() {
    do {
      if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
      else { try SMAppService.mainApp.register() }
    } catch { log("Start at login: \(error.localizedDescription)") }
    rebuildMenu()
  }

  @objc private func showLog() {
    NSWorkspace.shared.open(LOG_URL)
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
