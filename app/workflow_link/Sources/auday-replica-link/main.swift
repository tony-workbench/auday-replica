// The phone side of the Auday workflow link, for the replica.
//
// Advertises `_auday-link._tcp` over Bonjour and accepts TLS 1.2 connections authenticated only by
// the communication password (PSK identity "auday-workflow-link-v2", HKDF-SHA256 key, cipher suite
// ECDHE-PSK-CHACHA20-POLY1305). Each decrypted connection is piped to the replica's Python server
// on a private Unix socket; the framing and every request are handled there (app/workflow_server.py).
//
// Input: one JSON line on stdin {"password", "name", "socket", "port"}. The password never
// appears in arguments. Output: JSON event lines on stdout. Closing stdin stops the listener.

import CryptoKit
import Foundation
import Network

let alphabet = Set("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")

func emit(_ value: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
    data.append(10)
    FileHandle.standardOutput.write(data)
}

func fail(_ error: String) -> Never {
    emit(["event": "failed", "error": error])
    exit(1)
}

func pskKey(_ password: String) -> Data? {
    let text = password.uppercased().filter { !$0.isWhitespace && $0 != "-" }
    guard text.count == 16, text.allSatisfy({ alphabet.contains($0) }), Set(text).count >= 4 else { return nil }
    let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(text.utf8)),
                                     salt: Data("auday-workflow-link-v2".utf8), info: Data("tls-psk".utf8),
                                     outputByteCount: 32)
    return key.withUnsafeBytes { Data($0) }
}

guard let line = readLine(), let input = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
      let password = input["password"] as? String, let name = input["name"] as? String,
      let socketPath = input["socket"] as? String else { fail("invalid_stdin") }
guard let key = pskKey(password) else { fail("use_generated_16_character_communication_password") }

let tls = NWProtocolTLS.Options()
sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
    tls_ciphersuite_t(rawValue: UInt16(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256))!)
let identity = Data("auday-workflow-link-v2".utf8)
key.withUnsafeBytes { raw in identity.withUnsafeBytes { id in
    sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions,
        DispatchData(bytes: raw) as __DispatchData, DispatchData(bytes: id) as __DispatchData)
}}
let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
parameters.includePeerToPeer = input["peerToPeer"] as? Bool ?? false

let port = (input["port"] as? Int).flatMap { $0 > 0 && $0 < 65536 ? NWEndpoint.Port(rawValue: UInt16($0)) : nil } ?? .any
guard let listener = try? NWListener(using: parameters, on: port) else { fail("listener_failed") }
listener.service = NWListener.Service(name: name, type: "_auday-link._tcp", domain: "local.")
let queue = DispatchQueue(label: "auday.replica.link")

/// Copies bytes one way until the source finishes, then finishes the destination.
func pipe(_ from: NWConnection, _ to: NWConnection, _ done: @escaping () -> Void) {
    from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
        if let data, !data.isEmpty {
            to.send(content: data, completion: .contentProcessed { sendError in
                if sendError != nil { done() } else if complete || error != nil { finish() } else { pipe(from, to, done) }
            })
        } else if complete || error != nil {
            finish()
        } else {
            pipe(from, to, done)
        }
    }
    func finish() {
        to.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in done() })
    }
}

listener.newConnectionHandler = { inbound in
    let outbound = NWConnection(to: .unix(path: socketPath), using: .tcp)
    var closed = false
    let close = {
        queue.async {
            guard !closed else { return }
            closed = true
            // Let the final TLS record and close_notify leave before tearing down.
            queue.asyncAfter(deadline: .now() + 1) { inbound.cancel(); outbound.cancel() }
        }
    }
    var ready = 0
    let start = {
        ready += 1
        if ready == 2 {
            pipe(inbound, outbound, {})
            pipe(outbound, inbound, close)
        }
    }
    inbound.stateUpdateHandler = { state in
        switch state {
        case .ready: start()
        case .failed, .cancelled: outbound.cancel()
        default: break
        }
    }
    outbound.stateUpdateHandler = { state in
        switch state {
        case .ready: start()
        case .failed, .cancelled: inbound.cancel()
        default: break
        }
    }
    outbound.start(queue: queue)
    inbound.start(queue: queue)
    // A connection that never completes a request (wrong password, stalled peer) is dropped.
    queue.asyncAfter(deadline: .now() + 120) { inbound.cancel(); outbound.cancel() }
}

listener.stateUpdateHandler = { state in
    switch state {
    case .ready: emit(["event": "ready", "port": Int(listener.port?.rawValue ?? 0), "name": name])
    case .failed(let error): fail("listener_failed: \(error)")
    default: break
    }
}
listener.serviceRegistrationUpdateHandler = { change in
    if case .add = change { emit(["event": "advertised", "name": name]) }
}
listener.start(queue: queue)

// The replica owns this process: when it closes stdin (or exits), stop advertising.
DispatchQueue.global().async {
    while readLine() != nil {}
    listener.cancel()
    exit(0)
}
dispatchMain()
