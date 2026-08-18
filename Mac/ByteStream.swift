// Transport abstraction: send bytes, read exactly N bytes, close.
// Wire framing is [4-byte BE length][payload].

import Foundation
import Network

protocol ByteStream: AnyObject {
    /// `completion` fires once `data` is handed off to the transport.
    func send(_ data: Data, completion: @escaping (Error?) -> Void)

    /// Reads exactly `count` bytes, or nil on failure/close.
    func receive(exactly count: Int, completion: @escaping (Data?) -> Void)

    func cancel()
}

/// NWConnection-backed transport: WiFi, -host/-port, usbmux.
final class NetworkByteStream: ByteStream {
    let connection: NWConnection

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        connection.send(content: data, completion: .contentProcessed { completion($0) })
    }

    func receive(exactly count: Int, completion: @escaping (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) {
            data, _, _, error in
            guard error == nil, let data, data.count == count else {
                completion(nil)
                return
            }
            completion(data)
        }
    }

    func cancel() {
        connection.cancel()
    }
}
