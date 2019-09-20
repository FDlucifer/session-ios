import PromiseKit

final class LokiDeviceLinkingSession : NSObject {
    private let delegate: LokiDeviceLinkingSessionDelegate
    private var timer: Timer?
    public var isListeningForLinkingRequests = false
    
    // MARK: Lifecycle
    public init(delegate: LokiDeviceLinkingSessionDelegate) {
        self.delegate = delegate
    }
    
    // MARK: Settings
    private let listeningTimeout: TimeInterval = 60

    // MARK: Public API
    public func startListeningForLinkingRequests() {
        isListeningForLinkingRequests = true
        timer = Timer.scheduledTimer(withTimeInterval: listeningTimeout, repeats: false) { [weak self] timer in
            guard let self = self else { return }
            self.stopListeningForLinkingRequests()
            self.delegate.handleDeviceLinkingSessionTimeout()
        }
    }
    
    public func processLinkingRequest(from slaveHexEncodedPublicKey: String, with slaveSignature: Data) {
        guard isListeningForLinkingRequests else { return }
        stopListeningForLinkingRequests()
        let master = LokiDeviceLink.Device(hexEncodedPublicKey: OWSIdentityManager.shared().identityKeyPair()!.hexEncodedPublicKey)
        let slave = LokiDeviceLink.Device(hexEncodedPublicKey: slaveHexEncodedPublicKey, signature: slaveSignature)
        let deviceLink = LokiDeviceLink(between: master, and: slave)
        delegate.authorizeDeviceLinkIfValid(deviceLink)
    }
    
    public func stopListeningForLinkingRequests() {
        timer?.invalidate()
        timer = nil
        isListeningForLinkingRequests = false
    }
}
