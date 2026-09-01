// Dev tool: an in-process SSH server for exercising the app's tunnel path.
//   swift run sshtestserver <port>
// Accepts user "tester" with ANY password; forwards direct-tcpip anywhere.
import Citadel
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

final class AnyPasswordAuthDelegate: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .password

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        responsePromise.succeed(request.username == "tester" ? .success : .failure)
    }
}

struct ForwardingDelegate: DirectTCPIPDelegate {
    final class SSHSidePipe: ChannelInboundHandler {
        typealias InboundIn = IOData
        let peer: Channel
        init(peer: Channel) { self.peer = peer }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            if case .byteBuffer(let buffer) = unwrapInboundIn(data) {
                peer.writeAndFlush(buffer, promise: nil)
            }
        }

        func channelInactive(context: ChannelHandlerContext) {
            peer.close(mode: .all, promise: nil)
            context.fireChannelInactive()
        }
    }

    final class RemoteSidePipe: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        let peer: Channel
        init(peer: Channel) { self.peer = peer }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            peer.writeAndFlush(unwrapInboundIn(data), promise: nil)
        }

        func channelInactive(context: ChannelHandlerContext) {
            peer.close(mode: .all, promise: nil)
            context.fireChannelInactive()
        }
    }

    func initializeDirectTCPIPChannel(
        _ channel: Channel, request: SSHChannelType.DirectTCPIP, context: SSHContext
    ) -> EventLoopFuture<Void> {
        ClientBootstrap(group: channel.eventLoop)
            .connect(host: request.targetHost, port: request.targetPort)
            .flatMap { remote in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(SSHSidePipe(peer: remote))
                    try remote.pipeline.syncOperations.addHandler(RemoteSidePipe(peer: channel))
                }
            }
    }
}

let port = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 42024 : 42024
let server = try await SSHServer.host(
    host: "127.0.0.1",
    port: port,
    hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())],
    authenticationDelegate: AnyPasswordAuthDelegate())
server.enableDirectTCPIP(withDelegate: ForwardingDelegate())
print("ssh test server listening on 127.0.0.1:\(port)")
try await Task.sleep(for: .seconds(3600))
