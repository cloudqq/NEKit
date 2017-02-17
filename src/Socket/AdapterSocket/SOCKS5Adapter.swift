import Foundation

public class SOCKS5Adapter: AdapterSocket {
    enum SOCKS5AdapterStatus {
        case invalid,
        connecting,
        readingMethodResponse,
        readingResponseFirstPart,
        readingResponseSecondPart,
        forwarding
    }
    public let serverHost: String
    public let serverPort: Int

    var internalStatus: SOCKS5AdapterStatus = .invalid

    let helloData = Data(bytes: UnsafePointer<UInt8>(([0x05, 0x01, 0x00] as [UInt8])), count: 3)

    public enum ReadTag: Int {
        case methodResponse = -20000, connectResponseFirstPart, connectResponseSecondPart
    }

    public enum WriteTag: Int {
        case open = -21000, connectIPv4, connectIPv6, connectDomainLength, connectPort
    }

    public init(serverHost: String, serverPort: Int) {
        self.serverHost = serverHost
        self.serverPort = serverPort
        super.init()
    }

    public override func openSocketWith(session: ConnectSession) {
        super.openSocketWith(session: session)

        guard !isCancelled else {
            return
        }

        do {
            internalStatus = .connecting
            try socket.connectTo(host: serverHost, port: serverPort, enableTLS: false, tlsSettings: nil)
        } catch {}
    }

    public override func didConnectWith(socket: RawTCPSocketProtocol) {
        super.didConnectWith(socket: socket)

        write(data: helloData)
        internalStatus = .readingMethodResponse
        socket.readDataTo(length: 2)
    }

    public override func didRead(data: Data, from socket: RawTCPSocketProtocol) {
        super.didRead(data: data, from: socket)

        switch internalStatus {
        case .readingMethodResponse:
            var response: [UInt8]
            if session.isIPv4() {
                response = [0x05, 0x01, 0x00, 0x01]
                response += Utils.IP.IPv4ToBytes(session.host)!
            } else if session.isIPv6() {
                response = [0x05, 0x01, 0x00, 0x04]
                response += Utils.IP.IPv6ToBytes(session.host)!
            } else {
                response = [0x05, 0x01, 0x00, 0x03]
                response.append(UInt8(session.host.utf8.count))
                response += [UInt8](session.host.utf8)
            }

            let portBytes: [UInt8] = Utils.toByteArray(UInt16(session.port)).reversed()
            response.append(contentsOf: portBytes)
            write(data: Data(bytes: response))

            internalStatus = .readingResponseFirstPart
            socket.readDataTo(length: 5)
        case .readingResponseFirstPart:
            var readLength = 0
            data.withUnsafeBytes { (ptr: UnsafePointer<UInt8>) in
                switch ptr.advanced(by: 3).pointee {
                case 1:
                    readLength = 3 + 2
                case 3:
                    readLength = Int(ptr.advanced(by: 1).pointee) + 2
                case 4:
                    readLength = 15 + 2
                default:
                    break
                }
            }
            internalStatus = .readingResponseSecondPart
            socket.readDataTo(length: readLength)
        case .readingResponseSecondPart:
            internalStatus = .forwarding
            observer?.signal(.readyForForward(self))
            delegate?.didBecomeReadyToForwardWith(session: self.session, socket: self)
        case .forwarding:
            delegate?.didRead(session: self.session, data: data, from: self)
        default:
            return
        }
    }

    override open func didWrite(data: Data?, by socket: RawTCPSocketProtocol) {
        super.didWrite(data: data, by: socket)

        if internalStatus == .forwarding {
            delegate?.didWrite(session: self.session, data: data, by: self)
        }
    }
}
