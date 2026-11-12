import Foundation
import MultipeerConnectivity
import CryptoKit

/// Encrypted, one-viewer transport. All state and callbacks belong to queue.
/// A camera sends no image/control state until the viewer proves the on-screen code.
public final class CompanionSession: NSObject {
    public enum Role { case camera, viewer }
    public struct Peer: Identifiable {
        public let id: String
        public let name: String
        public let trusted: Bool
    }
    private static let service = "micro-camera"
    private let queue = DispatchQueue(label: "microscope.companion.link")
    private let role: Role
    private let peerID: MCPeerID
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var discovered: [String: MCPeerID] = [:]
    private var selectedPeer: MCPeerID?
    private var discoveryInfo: [String: [String: String]] = [:]
    public let installationID: String
    private let rememberConnections: Bool
    private var trusted: TrustedCompanion?
    private var discoveryGeneration = UUID()
    private var autoReconnect = false
    private var retryAfter = Date.distantPast
    private var qrAttempt = false
    private var pendingPair: TrustedCompanion?
    private var qrSecret: Data?
    private var qrExpires = Date.distantPast
    private var resumeAttempt = false
    private var challenge = ""
    private var responseNonce = ""
    private var qrInvitation: PairingInvitation?
    private var invitationTarget: String?
    public var hasRememberedCompanion: Bool { queue.sync { trusted != nil } }
    private var authorized = false
    private var code = ""
    private var cachedState: PhoneCameraState?
    private var inFlight: UInt64?
    private var frameSequence: UInt64 = 0
    private var generation = UUID()
    private var failures = 0
    private var blockedUntil = Date.distantPast
    public var onPeers: (([Peer]) -> Void)?
    public var onStatus: ((String) -> Void)?
    public var onAuthorized: (() -> Void)?
    public var onDisconnected: (() -> Void)?
    public var onState: ((PhoneCameraState) -> Void)?
    public var onCommand: ((UUID, PhoneCameraCommand) -> Void)?
    public var onReply: ((UUID, String?) -> Void)?
    public var onFrame: ((CompanionFrame, Data, @escaping () -> Void) -> Void)?

    public init(role: Role, name: String, rememberConnections: Bool = true) {
        self.role = role; self.rememberConnections = rememberConnections
        let key = "companion.installation.\(role == .camera ? "camera" : "viewer")"
        let id = rememberConnections ? (UserDefaults.standard.string(forKey: key) ?? UUID().uuidString) : UUID().uuidString
        installationID = id
        if rememberConnections { UserDefaults.standard.set(id, forKey: key); trusted = PairingKeychain.load(id) }
        // MCPeerID accepts 1...63 UTF-8 bytes, including non-ASCII device names.
        var short = name
        while short.utf8.count > 60 { short.removeLast() }
        peerID = MCPeerID(displayName: short.isEmpty ? "Microscope" : short)
        super.init()
        makeSession()
    }
    private func makeSession() {
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
    }
    public func browse() {
        queue.async {
            self.autoReconnect = true
            guard self.browser == nil else { self.tryReconnect(); return }
            let browser = MCNearbyServiceBrowser(peer: self.peerID, serviceType: Self.service)
            browser.delegate = self; self.browser = browser; browser.startBrowsingForPeers()
            self.onStatus?("Searching for iPhone companions…")
            self.discoveryGeneration = UUID(); self.scheduleReconnect(generation: self.discoveryGeneration)
        }
    }
    public func offerPairing(_ invitation: PairingInvitation) { queue.async { self.qrInvitation = invitation } }
    public func forgetCompanion() {
        queue.async {
            self.trusted = nil; PairingKeychain.forget(self.installationID)
            self.autoReconnect = false; self.disconnectLocked(notify: true); self.emitPeers()
        }
    }
    public func advertise(code: String, invitation: PairingInvitation? = nil) {
        queue.async {
            self.code = code; self.invitationTarget = invitation?.viewerID; self.qrSecret = invitation?.secret; self.qrExpires = invitation?.expires ?? .distantPast
            guard self.advertiser == nil else { return }
            var info = ["schema": String(CompanionPacket.version), "id": self.installationID]
            if let invitation { info["target"] = invitation.viewerID; info["invite"] = invitation.id }
            let advertiser = MCNearbyServiceAdvertiser(peer: self.peerID, discoveryInfo: info, serviceType: Self.service)
            advertiser.delegate = self; self.advertiser = advertiser; advertiser.startAdvertisingPeer()
            self.onStatus?("Ready · enter the code on your Mac")
        }
    }
    public func connect(to id: String, code: String) {
        queue.async {
            guard self.role == .viewer, let peer = self.discovered[id], PairingInvitation.validCode(code) else { return }
            self.autoReconnect = true
            self.beginConnection(peer, code: code, resume: false)
        }
    }
    private func beginConnection(_ peer: MCPeerID, code: String, resume: Bool, qrPair: TrustedCompanion? = nil) {
        disconnectLocked(notify: false)
        self.code = code; selectedPeer = peer; resumeAttempt = resume; pendingPair = qrPair; qrAttempt = qrPair != nil
        retryAfter = Date().addingTimeInterval(10)
        browser?.invitePeer(peer, to: session, withContext: Data([UInt8(CompanionPacket.version), qrAttempt ? 2 : (resume ? 1 : 0)]), timeout: 15)
        onStatus?("Pairing with \(peer.displayName)…")
        let generation = self.generation
        queue.asyncAfter(deadline: .now() + 20) {
            if self.generation == generation, !self.authorized { self.fail("Pairing timed out. Check the code, Wi-Fi and Local Network permission.") }
        }
    }
    private func tryReconnect() {
        guard role == .viewer, browser != nil, selectedPeer == nil, autoReconnect, Date() >= retryAfter else { return }
        if let invitation = qrInvitation, invitation.expires > Date(),
           let entry = discovered.first(where: { invitation.matchesDiscovery(discoveryInfo[$0.key] ?? [:]) }) {
            if let id = discoveryInfo[entry.key]?["id"], UUID(uuidString: id) != nil {
                beginConnection(entry.value, code: "", resume: true, qrPair: TrustedCompanion(id: id, secret: invitation.secret))
            }
        } else if let trusted, let entry = discovered.first(where: { discoveryInfo[$0.key]?["id"] == trusted.id }) {
            beginConnection(entry.value, code: "", resume: true)
        }
    }
    private func scheduleReconnect(generation: UUID) {
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.browser != nil, self.discoveryGeneration == generation else { return }
            self.tryReconnect(); self.scheduleReconnect(generation: generation)
        }
    }
    public func disconnect() { queue.async { self.autoReconnect = false; self.qrInvitation = nil; self.disconnectLocked(notify: true) } }
    private func disconnectLocked(notify: Bool) {
        generation = UUID(); authorized = false; selectedPeer = nil; inFlight = nil
        challenge = ""; responseNonce = ""; resumeAttempt = false; qrAttempt = false; pendingPair = nil
        session.delegate = nil; session.disconnect(); makeSession()
        if notify { onDisconnected?(); onStatus?(role == .camera ? "Ready · enter the code on your Mac" : "Companion disconnected") }
    }
    public func stop() {
        queue.async {
            self.discoveryGeneration = UUID(); self.browser?.stopBrowsingForPeers(); self.browser = nil
            self.advertiser?.stopAdvertisingPeer(); self.advertiser = nil
            self.discovered.removeAll(); self.discoveryInfo.removeAll(); self.autoReconnect = false; self.onPeers?([])
            self.disconnectLocked(notify: true)
        }
    }
    private func fail(_ message: String) {
        disconnectLocked(notify: true); onStatus?(message)
    }
    private func send(_ message: CompanionMessage, jpeg: Data = Data()) {
        guard let selectedPeer, session.connectedPeers.contains(selectedPeer) else { return }
        do { try session.send(CompanionPacket.encode(message, jpeg: jpeg), toPeers: [selectedPeer], with: .reliable) }
        catch { fail("Companion connection failed: \(error.localizedDescription)") }
    }
    public func publish(_ state: PhoneCameraState) {
        queue.async { self.cachedState = state; if self.authorized { self.send(.state(state)) } }
    }
    public func command(_ command: PhoneCameraCommand, id: UUID) {
        queue.async { if self.authorized { self.send(.command(id: id, command)) } else { self.onReply?(id, "The iPhone is disconnected.") } }
    }
    public func reply(id: UUID, error: String?) {
        queue.async { if self.authorized { self.send(.reply(id: id, error: error)) } }
    }
    public var canSendFrame: Bool { queue.sync { authorized && inFlight == nil } }
    public func sendFrame(jpeg: Data, revision: Int, seconds: Double, width: Int, height: Int) {
        queue.async {
            guard self.authorized, self.inFlight == nil else { return }
            self.frameSequence &+= 1
            let sequence = self.frameSequence
            self.inFlight = sequence
            self.send(.frame(CompanionFrame(sequence: sequence, revision: revision, seconds: seconds, width: width, height: height)), jpeg: jpeg)
            let generation = self.generation
            self.queue.asyncAfter(deadline: .now() + 8) {
                if self.generation == generation, self.inFlight == sequence { self.fail("Viewer stopped receiving frames. Reconnect from the Mac.") }
            }
        }
    }
    private func rejectPairing() {
        failures += 1
        if failures >= 5 { blockedUntil = Date().addingTimeInterval(30); failures = 0 }
        fail("Pairing rejected. Check the code; after repeated attempts wait 30 seconds.")
    }
    private func receive(_ data: Data, peer: MCPeerID) {
        guard selectedPeer == peer else { return }
        do {
            let (message, jpeg) = try CompanionPacket.decode(data)
            if !authorized {
                if role == .viewer {
                    if resumeAttempt {
                        guard let trusted = pendingPair ?? trusted else { fail("Pair again using the code on your iPhone."); return }
                        if case .challenge(let nonce) = message, UUID(uuidString: nonce) != nil, challenge.isEmpty {
                            challenge = nonce; responseNonce = UUID().uuidString
                            let proof = PairingProof.make(secret: trusted.secret, role: "viewer", cameraID: trusted.id, viewerID: installationID, challenge: nonce, response: responseNonce)
                            send(.resume(viewerID: installationID, nonce: responseNonce, proof: proof)); return
                        }
                        guard case .resumed(let proof) = message, !challenge.isEmpty,
                              PairingProof.verify(proof, secret: trusted.secret, role: "camera", cameraID: trusted.id, viewerID: installationID, challenge: challenge, response: responseNonce) else {
                            autoReconnect = false; fail("Remembered pairing changed. Enter the iPhone code to pair again."); return
                        }
                    } else {
                        guard message == .authenticated else { fail("The iPhone did not accept pairing. Check the code."); return }
                    }
                    if qrAttempt, rememberConnections, let pendingPair {
                        if PairingKeychain.save(pendingPair, id: installationID) { trusted = pendingPair }
                        else { onStatus?("Connected for this session. Could not save pairing in Keychain.") }
                    }
                    authorized = true; qrInvitation = nil; onAuthorized?(); onStatus?("Paired · waiting for camera frames")
                    return
                }
                if resumeAttempt {
                    guard case .resume(let id, let nonce, let proof) = message,
                          let trusted = qrAttempt ? qrSecret.map({ TrustedCompanion(id: invitationTarget ?? "", secret: $0) }) : trusted, trusted.id == id,
                          UUID(uuidString: nonce) != nil, !challenge.isEmpty, (!qrAttempt || qrExpires > Date()),
                          PairingProof.verify(proof, secret: trusted.secret, role: "viewer", cameraID: installationID, viewerID: id, challenge: challenge, response: nonce) else {
                        rejectPairing(); return
                    }
                    let cameraProof = PairingProof.make(secret: trusted.secret, role: "camera", cameraID: installationID, viewerID: id, challenge: challenge, response: nonce)
                    if qrAttempt, rememberConnections {
                        if PairingKeychain.save(trusted, id: installationID) { self.trusted = trusted }
                    }
                    authorized = true; send(.resumed(proof: cameraProof))
                } else {
                    var suppliedCode: String
                    var viewerID: String?
                    switch message {
                    case .pair(let version, let code, let id) where version == CompanionPacket.version && UUID(uuidString: id) != nil:
                        suppliedCode = code; viewerID = id
                    case .hello(let version, let code) where version == CompanionPacket.version:
                        suppliedCode = code
                    default: rejectPairing(); return
                    }
                    guard suppliedCode == code, PairingInvitation.validCode(code), Date() >= blockedUntil,
                          invitationTarget == nil || invitationTarget == viewerID else { rejectPairing(); return }
                    authorized = true; send(.authenticated)
                    if rememberConnections, let viewerID {
                        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                        let pair = TrustedCompanion(id: viewerID, secret: secret)
                        if PairingKeychain.save(pair, id: installationID) {
                            trusted = pair; send(.credential(cameraID: installationID, secret: secret))
                        } else { onStatus?("Connected for this session. Could not save pairing in Keychain.") }
                    }
                    invitationTarget = nil
                }
                failures = 0
                if let cachedState { send(.state(cachedState)) }
                onAuthorized?(); onStatus?("Streaming · controlled by \(peer.displayName)")
                return
            }
            switch message {
            case .credential(let id, let secret):
                guard role == .viewer, !resumeAttempt, rememberConnections, UUID(uuidString: id) != nil, secret.count == 32 else { return }
                let pair = TrustedCompanion(id: id, secret: secret)
                if PairingKeychain.save(pair, id: installationID) { trusted = pair; emitPeers() }
                else { onStatus?("Connected for this session. Could not save pairing in Keychain.") }
            case .hello, .pair, .challenge, .resume, .resumed, .authenticated: fail("Unexpected pairing request")
            case .state(let state):
                guard role == .viewer else { return }
                onState?(state)
            case .command(let id, let command): if role == .camera { onCommand?(id, command) }
            case .reply(let id, let error): if role == .viewer { onReply?(id, error) }
            case .acknowledgement(let sequence): if role == .camera, inFlight == sequence { inFlight = nil }
            case .frame(let frame):
                guard role == .viewer else { return }
                let generation = self.generation
                let acknowledge = { [weak self] in
                    self?.queue.async { [weak self] in
                        guard let self, self.generation == generation else { return }
                        self.send(.acknowledgement(frame.sequence))
                    }
                }
                if let onFrame { onFrame(frame, jpeg, { acknowledge() }) } else { acknowledge() }
            }
        } catch { fail("Incompatible or invalid companion message. Update both apps.") }
    }
}

extension CompanionSession: MCNearbyServiceBrowserDelegate, MCNearbyServiceAdvertiserDelegate {
    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        queue.async {
            guard browser === self.browser else { return }
            // MCPeerID equality, rather than the display name, distinguishes identically named phones.
            guard info?["schema"] == String(CompanionPacket.version) else { return }
            let id = self.discovered.first(where: { $0.value == peerID })?.key ?? UUID().uuidString
            self.discovered[id] = peerID; self.discoveryInfo[id] = info ?? [:]
            self.emitPeers(); self.tryReconnect()
        }
    }
    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        queue.async { self.discovered = self.discovered.filter { $0.value != peerID }; self.emitPeers() }
    }
    private func emitPeers() { onPeers?(discovered.map { Peer(id: $0.key, name: $0.value.displayName, trusted: discoveryInfo[$0.key]?["id"] == trusted?.id && trusted != nil) }.sorted { $0.name < $1.name }) }
    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        queue.async { self.onStatus?("Discovery failed. Allow Local Network access in System Settings. \(error.localizedDescription)") }
    }
    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        queue.async { self.onStatus?("Discovery failed. Allow Local Network access in Settings. \(error.localizedDescription)") }
    }
    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        queue.async {
            guard self.role == .camera, self.selectedPeer == nil, Date() >= self.blockedUntil,
                  context == Data([UInt8(CompanionPacket.version), 0]) || context == Data([UInt8(CompanionPacket.version), 1]) || context == Data([UInt8(CompanionPacket.version), 2]) else { invitationHandler(false, nil); return }
            self.selectedPeer = peerID; self.resumeAttempt = context?.last != 0
            self.qrAttempt = context?.last == 2
            invitationHandler(true, self.session)
            let generation = self.generation
            self.queue.asyncAfter(deadline: .now() + 20) {
                if self.generation == generation, !self.authorized { self.fail("Pairing timed out. Try connecting again.") }
            }
        }
    }
}

extension CompanionSession: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        queue.async {
            guard session === self.session, self.selectedPeer == peerID else { return }
            if state == .connected, self.role == .viewer {
                // Only the encrypted transport sees the pairing code, never Bonjour/invitation metadata.
                if !self.resumeAttempt { self.send(.pair(version: CompanionPacket.version, code: self.code, viewerID: self.installationID)) }
            } else if state == .connected, self.role == .camera, self.resumeAttempt {
                self.challenge = UUID().uuidString; self.send(.challenge(self.challenge))
            } else if state == .notConnected { self.fail("Companion disconnected · keep the iPhone app open, then reconnect") }
        }
    }
    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        queue.async { if session === self.session { self.receive(data, peer: peerID) } }
    }
    public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) { stream.close() }
    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) { progress.cancel() }
    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
