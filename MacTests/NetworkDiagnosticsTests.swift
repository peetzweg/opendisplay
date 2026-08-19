import XCTest

final class LocalNetworkVerdictTests: XCTestCase {
    func testRouterAnsweringMeansPeerTrafficIsPlausible() {
        XCTAssertEqual(LocalNetworkProbe(gateway: true, internet: true).verdict, .ok)
    }

    func testRouterAnsweringWithoutInternetIsStillFineForUs() {
        // OpenDisplay never leaves the LAN. An offline router that answers is a
        // perfectly good network to stream over, and must not be flagged.
        XCTAssertEqual(LocalNetworkProbe(gateway: true, internet: false).verdict, .ok)
    }

    func testWorkingInternetOverASilentSubnetIsTheBlockedSignature() {
        XCTAssertEqual(LocalNetworkProbe(gateway: false, internet: true).verdict, .blocked)
    }

    func testEverythingSilentIsAnOutageNotAHostileNetwork() {
        XCTAssertEqual(LocalNetworkProbe(gateway: false, internet: false).verdict, .offline)
    }

    func testNoJudgeableRouterNeverAccusesTheNetwork() {
        // A full-tunnel VPN owns the default route, so there is no LAN gateway
        // we can learn anything from — stay quiet rather than guess.
        XCTAssertEqual(LocalNetworkProbe(gateway: nil, internet: true).verdict, .unknown)
    }

    func testOnlyTheBlockedAndOfflineVerdictsAdvise() {
        XCTAssertNil(LocalNetworkVerdict.ok.advice)
        XCTAssertNil(LocalNetworkVerdict.unknown.advice)
        XCTAssertNotNil(LocalNetworkVerdict.offline.advice)
        XCTAssertNotNil(LocalNetworkVerdict.blocked.advice)
    }

    func testAdviceStaysOneLineAndLeavesTheCableToTheRowAbove() {
        // It sits inline in a 440pt panel at caption size, so it has to stay a
        // single sentence. It must not suggest USB: the empty-list row directly
        // above already does, and repeating it reads as noise. The hedge about
        // which of the two causes this is belongs on the Local Network row.
        for verdict in [LocalNetworkVerdict.blocked, .offline] {
            let advice = verdict.advice ?? ""
            XCTAssertLessThanOrEqual(advice.count, 70, advice)
            XCTAssertFalse(advice.contains("USB"), advice)
        }
    }
}

final class ProbeOutcomeTests: XCTestCase {
    func testInconclusiveIsNotReportedAsUnreachable() {
        // The distinction the whole diagnosis rests on: a probe macOS refused to
        // send says nothing about the network, so it must not read as silence.
        XCTAssertEqual(ProbeOutcome.answered.reachability, true)
        XCTAssertEqual(ProbeOutcome.silent.reachability, false)
        XCTAssertNil(ProbeOutcome.inconclusive.reachability)
    }
}

final class IPv4SubnetTests: XCTestCase {
    /// 192.168.50.69/24, as measured on the network this feature was built for.
    private let lan = IPv4Subnet(address: IPv4Subnet.parse("192.168.50.69")!,
                                 mask: IPv4Subnet.parse("255.255.255.0")!)

    func testRouterOnOurLinkIsRecognised() {
        XCTAssertTrue(lan.contains("192.168.50.254"))
    }

    func testTailscaleGatewayIsNotMistakenForOurLink() {
        // The check that stops a full-tunnel VPN from being probed as if it were
        // the WiFi an iPad sits on.
        XCTAssertFalse(lan.contains("100.84.23.49"))
    }

    func testGarbageAddressIsNotAMatch() {
        XCTAssertFalse(lan.contains("not-an-address"))
        XCTAssertNil(IPv4Subnet.parse("192.168.50"))
    }
}

final class ICMPProbeTests: XCTestCase {
    func testEchoRequestIsAWellFormedType8WithAValidChecksum() {
        let packet = ICMPProbe.echoRequest(payload: Array("token".utf8))

        XCTAssertEqual(packet[0], 8)                    // echo request
        XCTAssertEqual(packet[1], 0)
        // A packet carrying its own correct checksum sums to zero.
        XCTAssertEqual(ICMPProbe.checksum(packet), 0)
    }

    func testReplyIsMatchedByTokenPastTheIPHeader() {
        // macOS hands back the IP header too, so the ICMP type sits at byte 20
        // for a 5-word header. Getting this offset wrong was the difference
        // between "router silent" and "router fine".
        let datagram = ipv4Header() + [0, 0, 0, 0, 0, 0, 0, 0] + Array("tok".utf8)

        XCTAssertTrue(ICMPProbe.isEchoReply(datagram, token: "tok"))
    }

    func testSomeoneElsesReplyIsNotOurs() {
        let datagram = ipv4Header() + [0, 0, 0, 0, 0, 0, 0, 0] + Array("other".utf8)

        XCTAssertFalse(ICMPProbe.isEchoReply(datagram, token: "tok"))
    }

    func testUnreachableReplyIsNotAPong() {
        // Type 3 (destination unreachable) quotes our request back, so the token
        // is present — the type is the only thing separating it from a pong.
        let datagram = ipv4Header() + [3, 0, 0, 0, 0, 0, 0, 0] + Array("tok".utf8)

        XCTAssertFalse(ICMPProbe.isEchoReply(datagram, token: "tok"))
    }

    func testTruncatedDatagramIsRejected() {
        XCTAssertFalse(ICMPProbe.isEchoReply([], token: "tok"))
        XCTAssertFalse(ICMPProbe.isEchoReply(ipv4Header(), token: "tok"))
        XCTAssertFalse(ICMPProbe.isEchoReply([0x60, 0, 0, 0], token: "tok"))   // IPv6
    }

    /// A 20-byte IPv4 header: version 4, header length 5 words.
    private func ipv4Header() -> [UInt8] {
        [0x45] + [UInt8](repeating: 0, count: 19)
    }
}
