// The computer side of pairing the iPhone companion (app/pair_iphone.py drives it).
//
// Input: one JSON line on stdin.
//   {"op": "discover"}  → browses `_audayreplica._tcp` for 3 s; prints {"services": [names]}.
//   {"op": "pair", "service", "password", "port", "token", "name"}
//                       → connects to that iPhone over TLS-PSK keyed by the password, sends the
//                         Mac's address (as this connection sees it), port and token, and prints
//                         the iPhone's reply. A wrong password fails the handshake.
// The password and the token never appear in arguments.

import AudayKit
import Foundation
import Network

func emit(_ value: [String: Any]) -> Never {
    var data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
    data.append(10)
    FileHandle.standardOutput.write(data)
    exit(0)
}

guard let line = readLine(), let input = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
      let op = input["op"] as? String else { emit(["ok": false, "error": "invalid_stdin"]) }
let queue = DispatchQueue(label: "auday.replica.pair")

if op == "discover" {
    var names: [String] = []
    let browser = NWBrowser(for: .bonjour(type: Pairing.serviceType, domain: "local."), using: .tcp)
    browser.browseResultsChangedHandler = { results, _ in
        names = results.compactMap { if case let .service(name, _, _, _) = $0.endpoint { name } else { nil } }.sorted()
    }
    browser.start(queue: queue)
    queue.asyncAfter(deadline: .now() + 3) { emit(["ok": true, "services": names]) }
    dispatchMain()
}

guard op == "pair", let service = input["service"] as? String, let password = input["password"] as? String,
      let token = input["token"] as? String, let port = input["port"] as? Int else { emit(["ok": false, "error": "invalid_stdin"]) }
guard let parameters = Pairing.parameters(password: password) else {
    emit(["ok": false, "error": "use_generated_16_character_communication_password"])
}
let connection = NWConnection(to: .service(name: service, type: Pairing.serviceType, domain: "local.", interface: nil),
                              using: parameters)
connection.stateUpdateHandler = { state in
    switch state {
    case .ready:
        // The address the iPhone reaches this Mac at is the local end of this connection.
        guard case let .hostPort(host, _)? = connection.currentPath?.localEndpoint, case let .ipv4(address) = host else {
            emit(["ok": false, "error": "no_ipv4_address"])
        }
        let ip = "\(address)".split(separator: "%").first.map(String.init) ?? "\(address)"
        let request: [String: Any] = ["op": "pair", "host": ip, "port": port, "token": token,
                                      "name": input["name"] as? String ?? Host.current().localizedName ?? "Mac"]
        connection.send(content: Pairing.frame(request), completion: .contentProcessed { error in
            if error != nil { emit(["ok": false, "error": "send_failed"]) }
            Pairing.receive(on: connection) { reply in
                var reply = reply ?? ["ok": false, "error": "no_reply"]
                reply["host"] = ip
                emit(reply)
            }
        })
    case .failed, .waiting:
        emit(["ok": false, "error": "awaiting_phone_or_wrong_password"])
    default: break
    }
}
connection.start(queue: queue)
// The iPhone checks it can reach this Mac before answering, which takes a moment.
queue.asyncAfter(deadline: .now() + 30) { emit(["ok": false, "error": "awaiting_phone_or_wrong_password"]) }
dispatchMain()
