import UIKit
import WebRTC
import SessionMessagingKit

final class IncomingCallBanner: UIView, UIGestureRecognizerDelegate {
    private static let swipeToOperateThreshold: CGFloat = 60
    private var previousY: CGFloat = 0
    let call: SessionCall
    
    // MARK: UI Components
    private lazy var profilePictureView: ProfilePictureView = {
        let result = ProfilePictureView()
        let size = CGFloat(60)
        result.size = size
        result.set(.width, to: size)
        result.set(.height, to: size)
        return result
    }()
    
    private lazy var displayNameLabel: UILabel = {
        let result = UILabel()
        result.textColor = UIColor.white
        result.font = .boldSystemFont(ofSize: Values.largeFontSize)
        result.lineBreakMode = .byTruncatingTail
        return result
    }()
    
    private lazy var answerButton: UIButton = {
        let result = UIButton(type: .custom)
        let image = UIImage(named: "AnswerCall")!.withTint(.white)?.resizedImage(to: CGSize(width: 24.8, height: 24.8))
        result.setImage(image, for: UIControl.State.normal)
        result.set(.width, to: 48)
        result.set(.height, to: 48)
        result.backgroundColor = Colors.accent
        result.layer.cornerRadius = 24
        result.addTarget(self, action: #selector(answerCall), for: UIControl.Event.touchUpInside)
        return result
    }()
    
    private lazy var hangUpButton: UIButton = {
        let result = UIButton(type: .custom)
        let image = UIImage(named: "EndCall")!.withTint(.white)?.resizedImage(to: CGSize(width: 29.6, height: 11.2))
        result.setImage(image, for: UIControl.State.normal)
        result.set(.width, to: 48)
        result.set(.height, to: 48)
        result.backgroundColor = Colors.destructive
        result.layer.cornerRadius = 24
        result.addTarget(self, action: #selector(endCall), for: UIControl.Event.touchUpInside)
        return result
    }()
    
    private lazy var panGestureRecognizer: UIPanGestureRecognizer = {
        let result = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        result.delegate = self
        return result
    }()
    
    // MARK: Initialization
    public static var current: IncomingCallBanner?
    
    init(for call: SessionCall) {
        self.call = call
        super.init(frame: CGRect.zero)
        setUpViewHierarchy()
        setUpGestureRecognizers()
        if let incomingCallBanner = IncomingCallBanner.current {
            incomingCallBanner.dismiss()
        }
        IncomingCallBanner.current = self
    }
    
    override init(frame: CGRect) {
        preconditionFailure("Use init(message:) instead.")
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(coder:) instead.")
    }
    
    private func setUpViewHierarchy() {
        self.backgroundColor = UIColor(hex: 0x000000).withAlphaComponent(0.9)
        self.layer.cornerRadius = Values.veryLargeSpacing
        self.layer.masksToBounds = true
        self.set(.height, to: 100)
        profilePictureView.publicKey = call.sessionID
        profilePictureView.update()
        displayNameLabel.text = call.contactName
        let stackView = UIStackView(arrangedSubviews: [profilePictureView, displayNameLabel, hangUpButton, answerButton])
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = Values.largeSpacing
        self.addSubview(stackView)
        stackView.center(.vertical, in: self)
        stackView.autoPinWidthToSuperview(withMargin: Values.mediumSpacing)
    }
    
    private func setUpGestureRecognizers() {
        let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tapGestureRecognizer.numberOfTapsRequired = 1
        addGestureRecognizer(tapGestureRecognizer)
        addGestureRecognizer(panGestureRecognizer)
    }
    
    // MARK: Interaction
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer == panGestureRecognizer {
            let v = panGestureRecognizer.velocity(in: self)
            return abs(v.y) > abs(v.x) // It has to be more vertical than horizontal
        } else {
            return true
        }
    }
    
    @objc private func handleTap(_ gestureRecognizer: UITapGestureRecognizer) {
        showCallVC(answer: false)
    }
    
    @objc private func handlePan(_ gestureRecognizer: UIPanGestureRecognizer) {
        let translationY = gestureRecognizer.translation(in: self).y
        switch gestureRecognizer.state {
        case .changed:
            self.transform = CGAffineTransform(translationX: 0, y: min(translationY, IncomingCallBanner.swipeToOperateThreshold))
            if abs(translationY) > IncomingCallBanner.swipeToOperateThreshold && abs(previousY) < IncomingCallBanner.swipeToOperateThreshold {
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred() // Let the user know when they've hit the swipe to reply threshold
            }
            previousY = translationY
        case .ended, .cancelled:
            if abs(translationY) > IncomingCallBanner.swipeToOperateThreshold {
                if translationY > 0 { showCallVC(answer: false) }
                else { endCall() } // TODO: Or just put the call on hold?
            } else {
                self.transform = .identity
            }
        default: break
        }
    }
    
    @objc private func answerCall() {
        let userDefaults = UserDefaults.standard
        if userDefaults[.hasSeenCallIPExposureWarning] {
            showCallVC(answer: true)
        } else {
            showCallModal()
        }
    }
    
    internal func showCallModal() {
        let callModal = CallModal() { [weak self] in
            self?.showCallVC(answer: true)
        }
        callModal.modalPresentationStyle = .overFullScreen
        callModal.modalTransitionStyle = .crossDissolve
        guard let presentingVC = CurrentAppContext().frontmostViewController() else { preconditionFailure() } // TODO: Handle more gracefully
        presentingVC.present(callModal, animated: true, completion: nil)
    }
    
    @objc private func endCall() {
        self.call.endSessionCall()
        self.dismiss()
    }
    
    public func showCallVC(answer: Bool) {
        dismiss()
        guard let presentingVC = CurrentAppContext().frontmostViewController() else { preconditionFailure() } // TODO: Handle more gracefully
        let callVC = CallVC(for: self.call)
        callVC.shouldAnswer = answer
        if let conversationVC = presentingVC as? ConversationVC {
            callVC.conversationVC = conversationVC
            conversationVC.inputAccessoryView?.isHidden = true
            conversationVC.inputAccessoryView?.alpha = 0
        }
        presentingVC.present(callVC, animated: true, completion: nil)
    }
    
    public func show() {
        self.alpha = 0.0
        let window = CurrentAppContext().mainWindow!
        window.addSubview(self)
        let topMargin = UIApplication.shared.keyWindow!.safeAreaInsets.top - Values.smallSpacing
        self.autoPinWidthToSuperview(withMargin: Values.smallSpacing)
        self.autoPinEdge(toSuperviewEdge: .top, withInset: topMargin)
        UIView.animate(withDuration: 0.5, delay: 0, options: [], animations: {
            self.alpha = 1.0
        }, completion: nil)
        Vibration.shared.startVibration()
    }
    
    public func dismiss() {
        Vibration.shared.stopVibrationIfPossible()
        UIView.animate(withDuration: 0.5, delay: 0, options: [], animations: {
            self.alpha = 0.0
        }, completion: { _ in
            IncomingCallBanner.current = nil
            self.removeFromSuperview()
        })
    }

}
