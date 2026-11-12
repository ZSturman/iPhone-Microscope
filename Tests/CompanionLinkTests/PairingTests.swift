import XCTest
@testable import CompanionLink

final class PairingTests: XCTestCase {
    func testUniversalLinkKeepsSecretInFragmentAndAcceptsLegacyInvitations() throws {
        let invitation = PairingInvitation(viewerID: UUID().uuidString, code: "001234", expires: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 300), secret: Data(repeating: 251, count: 32))
        XCTAssertNil(URLComponents(url: invitation.url, resolvingAgainstBaseURL: false)?.query)
        XCTAssertEqual(invitation.url.host, "zacharysturman.com")
        XCTAssertEqual(PairingInvitation(url: invitation.url), invitation)
        XCTAssertEqual(PairingInvitation(url: invitation.legacyURL), invitation)
        XCTAssertTrue(invitation.url.absoluteString.contains("%2B"))
        for invalid in [invitation.url.absoluteString.replacingOccurrences(of: "zacharysturman.com", with: "example.com"),
                        invitation.url.absoluteString.replacingOccurrences(of: "/connect#", with: "/connect/other#"),
                        invitation.url.absoluteString.replacingOccurrences(of: "/connect#", with: "/connect?secret=leak#")] {
            XCTAssertNil(PairingInvitation(url: try XCTUnwrap(URL(string: invalid))))
        }
    }
    func testInvitationPreservesLeadingZerosAndExpires() {
        let now = Date(timeIntervalSince1970: 1000)
        let invitation = PairingInvitation(viewerID: UUID().uuidString, code: "001234", expires: now.addingTimeInterval(300))
        XCTAssertEqual(PairingInvitation(url: invitation.url, now: now), invitation)
        XCTAssertNil(PairingInvitation(url: invitation.url, now: now.addingTimeInterval(301)))
        XCTAssertNil(PairingInvitation(url: invitation.url, now: now.addingTimeInterval(-20)))
    }
    func testDiscoveryOnlyMatchesTheCurrentInvitation() {
        let invitation = PairingInvitation(viewerID: UUID().uuidString, code: "123456")
        XCTAssertTrue(invitation.matchesDiscovery(["target": invitation.viewerID, "invite": invitation.id]))
        let replacement = PairingInvitation(viewerID: invitation.viewerID, code: "123456")
        XCTAssertFalse(replacement.matchesDiscovery(["target": invitation.viewerID, "invite": invitation.id]))
        XCTAssertFalse(invitation.matchesDiscovery(["target": UUID().uuidString, "invite": invitation.id]))
        XCTAssertFalse(invitation.matchesDiscovery(["target": invitation.viewerID, "invite": invitation.id], now: invitation.expires))
    }
    func testInvitationRejectsAmbiguousOrUnrelatedInput() {
        let id = UUID().uuidString
        let valid = PairingInvitation(viewerID: id, code: "123456", expires: Date(timeIntervalSince1970: 1200)).url.absoluteString
        for string in ["https://example.com", valid.replacingOccurrences(of: id, with: "bad"), valid + "&code=654321", valid.replacingOccurrences(of: "123456", with: "１２３４５６"), valid.replacingOccurrences(of: "1200", with: "nan")] {
            XCTAssertNil(PairingInvitation(url: URL(string: string)!, now: Date(timeIntervalSince1970: 1000)))
        }
        XCTAssertFalse(PairingInvitation.validCode("12345"))
        XCTAssertTrue(PairingInvitation.validCode("000001"))
    }
    func testResumeProofRejectsReplayRoleReflectionAndOtherDevices() {
        let secret = Data(repeating: 7, count: 32)
        let proof = PairingProof.make(secret: secret, role: "viewer", cameraID: "phone", viewerID: "mac", challenge: "fresh", response: "nonce")
        func verify(role: String = "viewer", camera: String = "phone", viewer: String = "mac", challenge: String = "fresh", response: String = "nonce", key: Data = secret) -> Bool {
            PairingProof.verify(proof, secret: key, role: role, cameraID: camera, viewerID: viewer, challenge: challenge, response: response)
        }
        XCTAssertTrue(verify())
        XCTAssertFalse(verify(role: "camera"))
        XCTAssertFalse(verify(camera: "other"))
        XCTAssertFalse(verify(viewer: "other"))
        XCTAssertFalse(verify(challenge: "next-session"))
        XCTAssertFalse(verify(response: "other-nonce"))
        XCTAssertFalse(verify(key: Data(repeating: 8, count: 32)))
    }
    func testPairingMessagesRoundTrip() throws {
        let messages: [CompanionMessage] = [.pair(version: 2, code: "001234", viewerID: UUID().uuidString), .credential(cameraID: UUID().uuidString, secret: Data(repeating: 8, count: 32)), .challenge(UUID().uuidString), .resume(viewerID: UUID().uuidString, nonce: UUID().uuidString, proof: Data(repeating: 1, count: 32)), .resumed(proof: Data(repeating: 2, count: 32))]
        for message in messages { XCTAssertEqual(try CompanionPacket.decode(CompanionPacket.encode(message)).0, message) }
    }
}
