import Network
import XCTest

final class DirectCableTests: XCTestCase {
    private func endpoint(_ host: NWEndpoint.Host) -> NWEndpoint {
        .hostPort(host: host, port: 9000)
    }

    func testLinkLocalAddressesCount() {
        XCTAssertTrue(DirectCable.isLinkLocal(endpoint(.ipv4(IPv4Address("169.254.37.173")!))))
        XCTAssertTrue(DirectCable.isLinkLocal(endpoint(.ipv6(IPv6Address("fe80::c09:d6aa:173a:3ca8")!))))
        XCTAssertTrue(DirectCable.isLinkLocal(endpoint(.name("fe80::1%en5", nil))))
    }

    func testRoutedAddressesDoNot() {
        XCTAssertFalse(DirectCable.isLinkLocal(endpoint(.ipv4(IPv4Address("192.168.178.75")!))))
        XCTAssertFalse(DirectCable.isLinkLocal(endpoint(.ipv6(IPv6Address("fd10:4a45:316d::2")!))))
        XCTAssertFalse(DirectCable.isLinkLocal(endpoint(.ipv6(IPv6Address("2001:9e8:973:a400::1")!))))
        XCTAssertFalse(DirectCable.isLinkLocal(endpoint(.name("imac.local", nil))))
        XCTAssertFalse(DirectCable.isLinkLocal(nil))
    }
}
