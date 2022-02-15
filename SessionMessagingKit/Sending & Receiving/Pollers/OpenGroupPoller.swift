import PromiseKit
import SessionSnodeKit

extension OpenGroupAPI {
    public final class Poller {
        private let server: String
        private var timer: Timer? = nil
        private var hasStarted = false
        private var isPolling = false

        // MARK: - Settings
        
        internal static let maxInactivityPeriod: Double = (14 * 24 * 60 * 60)
        private static let pollInterval: TimeInterval = 4
        
        // MARK: - Lifecycle
        
        public init(for server: String) {
            self.server = server
        }

        @objc public func startIfNeeded() {
            guard !hasStarted else { return }
            
            DispatchQueue.main.async { [weak self] in // Timers don't do well on background queues
                self?.hasStarted = true
                self?.timer = Timer.scheduledTimer(withTimeInterval: Poller.pollInterval, repeats: true) { _ in
                    self?.poll().retainUntilComplete()
                }
                self?.poll().retainUntilComplete()
            }
        }

        @objc public func stop() {
            timer?.invalidate()
            hasStarted = false
        }

        // MARK: - Polling
        
        @discardableResult
        public func poll() -> Promise<Void> {
            return poll(isBackgroundPoll: false)
        }

        @discardableResult
        public func poll(isBackgroundPoll: Bool) -> Promise<Void> {
            guard !self.isPolling else { return Promise.value(()) }
            
            self.isPolling = true
            let (promise, seal) = Promise<Void>.pending()
            promise.retainUntilComplete()
            
            OpenGroupAPI.poll(server)
                .done(on: OpenGroupAPI.workQueue) { [weak self] response in
                    self?.isPolling = false
                    self?.handlePollResponse(response, isBackgroundPoll: isBackgroundPoll)
                    seal.fulfill(())
                }
                .catch(on: OpenGroupAPI.workQueue) { [weak self] error in
                    SNLog("Open group polling failed due to error: \(error).")
                    self?.isPolling = false
                    seal.fulfill(()) // The promise is just used to keep track of when we're done
                }
    //        OpenGroupAPI.compactPoll(server)
    //        OpenGroupAPI.legacyCompactPoll(server)
    //            .done(on: OpenGroupAPI.workQueue) { [weak self] response in
    //                guard let self = self else { return }
    //                self.isPolling = false
    //                response.results.forEach { self.handleCompactPollBody($0, isBackgroundPoll: isBackgroundPoll) }
    //                seal.fulfill(())
    //            }
    //            .catch(on: OpenGroupAPI.workQueue) { error in
    //                SNLog("Open group polling failed due to error: \(error).")
    //                self.isPolling = false
    //                seal.fulfill(()) // The promise is just used to keep track of when we're done
    //            }
            
            return promise
        }
        
        private func handlePollResponse(_ response: [OpenGroupAPI.Endpoint: (info: OnionRequestResponseInfoType, data: Codable)], isBackgroundPoll: Bool) {
            let storage = SNMessagingKitConfiguration.shared.storage
            
            response.forEach { endpoint, response in
                switch endpoint {
                    case .roomMessagesRecent(let roomToken), .roomMessagesBefore(let roomToken, _), .roomMessagesSince(let roomToken, _):
                        guard let responseData: [OpenGroupAPI.Message] = response.data as? [OpenGroupAPI.Message] else {
                            //SNLog("Open group polling failed due to error: \(error).")
                            return  // TODO: Throw error?
                        }
                        
                        handleMessages(responseData, roomToken: roomToken, isBackgroundPoll: isBackgroundPoll, using: storage)
                        
                    case .roomPollInfo(let roomToken, _):
                        guard let responseData: OpenGroupAPI.RoomPollInfo = response.data as? OpenGroupAPI.RoomPollInfo else {
                            //SNLog("Open group polling failed due to error: \(error).")
                            return  // TODO: Throw error?
                        }
                        
                        handlePollInfo(responseData, roomToken: roomToken, isBackgroundPoll: isBackgroundPoll, using: storage)
                        
                    default: break // No custom handling needed
                }
            }
        }
        
        // MARK: - Custom response handling
        // TODO: Shift this logic to the OpenGroupManager? (seems like the place it should belong?)
        
        private func handleMessages(_ messages: [OpenGroupAPI.Message], roomToken: String, isBackgroundPoll: Bool, using storage: SessionMessagingKitStorageProtocol) {
            // Sorting the messages by server ID before importing them fixes an issue where messages that quote older messages can't find those older messages
            let openGroupID = "\(server).\(roomToken)"
            let sortedMessages: [OpenGroupAPI.Message] = messages
                .sorted { lhs, rhs in lhs.seqNo < rhs.seqNo }
            
            storage.write { transaction in
                var messageServerIDsToRemove: [UInt64] = []
                
                sortedMessages.forEach { message in
                    guard let base64EncodedString: String = message.base64EncodedData, let data = Data(base64Encoded: base64EncodedString), let sender: String = message.sender else {
                        // A message with no data has been deleted so add it to the list to remove
                        messageServerIDsToRemove.append(UInt64(message.seqNo))
                        return
                    }
                    
                    let envelope = SNProtoEnvelope.builder(type: .sessionMessage, timestamp: UInt64(floor(message.posted)))
                    envelope.setContent(data)
                    envelope.setSource(sender)
                    
                    do {
                        let data = try envelope.buildSerializedData()
                        let (message, proto) = try MessageReceiver.parse(data, openGroupMessageServerID: UInt64(message.seqNo), isRetry: false, using: transaction)
                        try MessageReceiver.handle(message, associatedWithProto: proto, openGroupID: openGroupID, isBackgroundPoll: isBackgroundPoll, using: transaction)
                    }
                    catch {
                        SNLog("Couldn't receive open group message due to error: \(error).")
                    }
                }

                // Handle any deletions that are needed
                guard !messageServerIDsToRemove.isEmpty else { return }
                guard let transaction: YapDatabaseReadWriteTransaction = transaction as? YapDatabaseReadWriteTransaction else { return }
                guard let threadID = storage.v2GetThreadID(for: openGroupID), let thread = TSGroupThread.fetch(uniqueId: threadID, transaction: transaction) else {
                    return
                }
                
                var messagesToRemove: [TSMessage] = []
                
                thread.enumerateInteractions(with: transaction) { interaction, stop in
                    guard let message: TSMessage = interaction as? TSMessage, messageServerIDsToRemove.contains(message.openGroupServerMessageID) else { return }
                    messagesToRemove.append(message)
                }
                
                messagesToRemove.forEach { $0.remove(with: transaction) }
            }
        }
        
        private func handlePollInfo(_ pollInfo: OpenGroupAPI.RoomPollInfo, roomToken: String, isBackgroundPoll: Bool, using storage: SessionMessagingKitStorageProtocol) {
            // TODO: Handle other properties???.

    //        public let token: String?
    //        public let created: TimeInterval?
    //        public let name: String?
    //        public let description: String?
    //        public let imageId: Int64?
    //
    //        public let infoUpdates: Int64?
    //        public let messageSequence: Int64?
    //        public let activeUsers: Int64?
    //        public let activeUsersCutoff: Int64?
    //        public let pinnedMessages: [PinnedMessage]?
    //
    //        public let admin: Bool?
    //        public let globalAdmin: Bool?
    //        public let admins: [String]?
    //        public let hiddenAdmins: [String]?
    //
    //        public let moderator: Bool?
    //        public let globalModerator: Bool?
    //        public let moderators: [String]?
    //        public let hiddenModerators: [String]?
            
            // - Moderators
            OpenGroupAPI.moderators[server] = (OpenGroupAPI.moderators[server] ?? [:])
                .setting(roomToken, Set(pollInfo.moderators ?? []))

    //        public let read: Bool?
    //        public let defaultRead: Bool?
    //        public let write: Bool?
    //        public let defaultWrite: Bool?
    //        public let upload: Bool?
    //        public let defaultUpload: Bool?
    //
    //        /// Only populated and different if the `info_updates` counter differs from the provided `info_updated` value
    //        public let details: Room?
        }
        
        // MARK: - Legacy Handling

        private func handleCompactPollBody(_ body: OpenGroupAPI.LegacyCompactPollResponse.Result, isBackgroundPoll: Bool) {
            let storage = SNMessagingKitConfiguration.shared.storage
            // - Messages
            // Sorting the messages by server ID before importing them fixes an issue where messages that quote older messages can't find those older messages
            let openGroupID = "\(server).\(body.room)"
            let messages = (body.messages ?? []).sorted { ($0.serverID ?? 0) < ($1.serverID ?? 0) }
            
            storage.write { transaction in
                messages.forEach { message in
                    guard let data = Data(base64Encoded: message.base64EncodedData) else {
                        return SNLog("Ignoring open group message with invalid encoding.")
                    }
                    let envelope = SNProtoEnvelope.builder(type: .sessionMessage, timestamp: message.sentTimestamp)
                    envelope.setContent(data)
                    envelope.setSource(message.sender!) // Safe because messages with a nil sender are filtered out
                    do {
                        let data = try envelope.buildSerializedData()
                        let (message, proto) = try MessageReceiver.parse(data, openGroupMessageServerID: UInt64(message.serverID!), isRetry: false, using: transaction)
                        try MessageReceiver.handle(message, associatedWithProto: proto, openGroupID: openGroupID, isBackgroundPoll: isBackgroundPoll, using: transaction)
                    } catch {
                        SNLog("Couldn't receive open group message due to error: \(error).")
                    }
                }
            }
            
            // - Moderators
            if var x = OpenGroupAPI.moderators[server] {
                x[body.room] = Set(body.moderators ?? [])
                OpenGroupAPI.moderators[server] = x
            }
            else {
                OpenGroupAPI.moderators[server] = [ body.room : Set(body.moderators ?? []) ]
            }
            
            // - Deletions
            let deletedMessageServerIDs = Set((body.deletions ?? []).map { UInt64($0.deletedMessageID) })
            storage.write { transaction in
                let transaction = transaction as! YapDatabaseReadWriteTransaction
                guard let threadID = storage.v2GetThreadID(for: openGroupID),
                    let thread = TSGroupThread.fetch(uniqueId: threadID, transaction: transaction) else { return }
                var messagesToRemove: [TSMessage] = []
                
                thread.enumerateInteractions(with: transaction) { interaction, stop in
                    guard let message = interaction as? TSMessage, deletedMessageServerIDs.contains(message.openGroupServerMessageID) else { return }
                    messagesToRemove.append(message)
                }
                
                messagesToRemove.forEach { $0.remove(with: transaction) }
            }
        }
    }
}
