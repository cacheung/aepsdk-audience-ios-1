/*
 Copyright 2020 Adobe. All rights reserved.
 This file is licensed to you under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License. You may obtain a copy
 of the License at http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software distributed under
 the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR REPRESENTATIONS
 OF ANY KIND, either express or implied. See the License for the specific language
 governing permissions and limitations under the License.
 */

import AEPCore
import AEPServices
import Foundation

/// Audience extension for the Adobe Experience Platform SDK
@objc(AEPMobileAudience)
public class Audience: NSObject, Extension {
    private(set) var hitQueue: HitQueuing?
    public let runtime: ExtensionRuntime
    public let name = AudienceConstants.EXTENSION_NAME
    public let friendlyName = AudienceConstants.FRIENDLY_NAME
    public static let extensionVersion = AudienceConstants.EXTENSION_VERSION
    public let metadata: [String: String]? = nil
    private(set) var state: AudienceState?

    // MARK: Extension

    public required init?(runtime: ExtensionRuntime) {
        self.runtime = runtime
        super.init()

        guard let dataQueue = ServiceProvider.shared.dataQueueService.getDataQueue(label: name) else {
            Log.error(label: getLogTagWith(functionName: #function), "Failed to create Data Queue, Audience could not be initialized")
            return
        }

        hitQueue = PersistentHitQueue(dataQueue: dataQueue, processor: AudienceHitProcessor(responseHandler: handleNetworkResponse(entity:responseData:)))

        state = AudienceState()
    }

    // internal init added for tests
    internal init(runtime: ExtensionRuntime, hitQueue: HitQueuing) {
        self.runtime = runtime
        super.init()
        state = AudienceState()
        self.hitQueue = hitQueue
    }

    /// Invoked when the `EventHub` has successfully registered the Audience extension.
    public func onRegistered() {
        registerListener(type: EventType.lifecycle, source: EventSource.responseContent, listener: handleLifecycleResponse(event:))
        registerListener(type: EventType.analytics, source: EventSource.responseContent, listener: handleAnalyticsResponse(event:))

        registerListener(type: EventType.audienceManager, source: EventSource.requestContent, listener: handleAudienceContentRequest(event:))
        registerListener(type: EventType.audienceManager, source: EventSource.requestIdentity, listener: handleAudienceIdentityRequest(event:))
        registerListener(type: EventType.audienceManager, source: EventSource.requestReset, listener: handleAudienceResetRequest(event:))
        registerListener(type: EventType.configuration, source: EventSource.responseContent, listener: handleConfigurationResponse(event:))
    }

    public func onUnregistered() {}

    public func readyForEvent(_ event: Event) -> Bool {
        let configurationStatus = getSharedState(extensionName: AudienceConstants.SharedStateKeys.CONFIGURATION, event: event)?.status ?? .none

        let identityStatus = getSharedState(extensionName: AudienceConstants.SharedStateKeys.IDENTITY, event: event)?.status ?? .none

        if event.type == EventType.audienceManager, event.source == EventSource.requestContent {
            return configurationStatus != .pending && identityStatus != .pending
        }

        return configurationStatus == .set
    }

    // MARK: Event Listeners

    /// Processes Configuration Response content events to retrieve the configuration data and privacy status settings.
    /// - Parameter:
    ///   - event: The configuration response event
    private func handleConfigurationResponse(event: Event) {
        guard let privacyStatusStr = event.data?[AudienceConstants.Configuration.GLOBAL_CONFIG_PRIVACY] as? String else { return }
        let privacyStatus = PrivacyStatus(rawValue: privacyStatusStr) ?? PrivacyStatus.unknown
        if privacyStatus == .optedOut {
            // send opt-out hit
            handleOptOut(event: event)
            createSharedState(data: state?.getStateData() ?? [:], event: event)
        }

        // if privacy status is opted out, audience manager data in the AudienceState will be cleared.
        state?.setMobilePrivacy(status: privacyStatus)

        // update hit queue with privacy status
        hitQueue?.handlePrivacyChange(status: privacyStatus)
    }

    // Handles the signalWithData API by sending the AAM hit with passed event data then dispatching a response event with the visitorProfile
    /// - Parameter event: The event coming from the signalWithData API
    private func handleAudienceContentRequest(event: Event) {
        queueHit(event: event)
    }

    // Handles the getVisitorProfile API by getting the current visitorProfile then dispatching a response event with the visitorProfile
    /// - Parameter event: The event coming from the getVisitorProfile API
    private func handleAudienceIdentityRequest(event: Event) {
        // Dispatch with dpid, dpuuid and visitorProfile
        var eventData = [String: Any]()
        eventData[AudienceConstants.EventDataKeys.VISITOR_PROFILE] = state?.getVisitorProfile()
        let responseEvent = event.createResponseEvent(name: "Audience Response Identity", type: EventType.audienceManager, source: EventSource.responseIdentity, data: eventData)

        // dispatch identity response event with shared state data
        dispatch(event: responseEvent)
    }

    // Handles the reset API which clears all the identifiers and visitorProfile then dispatches a sharedStateUpdate
    /// - Parameter event: The event coming from the reset API
    private func handleAudienceResetRequest(event: Event) {
        state?.clearIdentifiers()
        createSharedState(data: state?.getStateData() ?? [:], event: event)
    }

    /// Processes Lifecycle Response content and sends a signal to Audience Manager if aam forwarding is disabled.
    /// - Parameter:
    ///   - event: The lifecycle response event
    private func handleLifecycleResponse(event: Event) {
        guard let response = event.data else { return }
        if !response.isEmpty {
            // bail if we don't have configuration yet
            guard let configSharedState = getSharedState(extensionName: AudienceConstants.SharedStateKeys.CONFIGURATION, event: event)?.value else { return }
            let aamForwardingStatus = getAnalyticsAAMForwardingStatus(configurationSharedState: configSharedState)
            // a signal with data request will be made if aam forwarding is false
            if !aamForwardingStatus {
                queueHit(event: event)
            }
        }
    }

    /// Processes Analytics Response content events to forward any necessary requests and to create a dictionary out of the contents of the "stuff" array.
    /// - Parameter:
    ///   - event: The analytics response event
    private func handleAnalyticsResponse(event: Event) {
        guard let response = event.data?[AudienceConstants.Analytics.SERVER_RESPONSE] as? String else { return }
        if !response.isEmpty {
            guard let responseAsData: Data = response.data(using: .utf8) else {
                return
            }
            processNetworkResponse(event: event, response: responseAsData)
        }
    }

    func queueHit(event: Event) {
        if state?.getPrivacyStatus() == PrivacyStatus.optedOut {
            Log.debug(label: getLogTagWith(functionName: #function), "Unable to process AAM event as privacy status is OPT_OUT:  \(event.description)")
            // dispatch with an empty visitor profile in response if privacy is opt-out.
            dispatchResponse(visitorProfle: ["": ""], event: event)
            return
        }

        if state?.getPrivacyStatus() == PrivacyStatus.unknown {
            Log.debug(label: getLogTagWith(functionName: #function), "Unable to process AAM event as privacy status is Unknown:  \(event.description)")
            // dispatch with an empty visitor profile in response if privacy is unknown.
            dispatchResponse(visitorProfle: ["": ""], event: event)
            return
        }

        let configurationSharedState = getSharedState(extensionName: AudienceConstants.SharedStateKeys.CONFIGURATION, event: event)?.value ?? ["": ""]
        let identitySharedState = getSharedState(extensionName: AudienceConstants.SharedStateKeys.IDENTITY, event: event)?.value ?? ["": ""]

        var eventData = [String:String]()

        // if the event is a lifecycle event, convert the lifecycle keys to audience manager keys
        if event.type == EventType.lifecycle {
            eventData = convertLifecycleKeys(event: event)
        } else {
            eventData = event.data as? [String: String] ?? ["": ""]
        }

        guard let url = URL.buildAudienceHitURL(audienceState: state, configurationSharedState: configurationSharedState, identitySharedState: identitySharedState, customerEventData: eventData) else {
            Log.debug(label: getLogTagWith(functionName: #function), "Dropping Audience hit, failed to create hit URL")
            return
        }

        let aamTimeout: TimeInterval = configurationSharedState[AudienceConstants.Configuration.AAM_TIMEOUT] as? TimeInterval ?? AudienceConstants.Default.TIMEOUT
        guard let hitData = try? JSONEncoder().encode(AudienceHit(url: url, timeout: aamTimeout, event: event)) else {
            Log.debug(label: getLogTagWith(functionName: #function), "Dropping Audience hit, failed to encode AudienceHit")
            return
        }

        hitQueue?.queue(entity: DataEntity(uniqueIdentifier: UUID().uuidString, timestamp: Date(), data: hitData))
    }

    func dispatchResponse(visitorProfle: [String: String], event: Event) {
        var eventData = [String: Any]()
        eventData[AudienceConstants.EventDataKeys.VISITOR_PROFILE] = visitorProfle
        let responseEvent = event.createResponseEvent(name: "Audience Manager Profile", type: EventType.audienceManager, source: EventSource.responseContent, data: eventData)
        dispatch(event: responseEvent)
    }

    /// Updates the Audience shared state versioned at `event` with `data`
    /// - Parameters:
    ///   - event: the event to version the shared state at
    ///   - data: data for the shared state
    private func updateSharedState(event: Event, data: [String: Any]) {
        let sharedStateData = data
        Log.trace(label: getLogTagWith(functionName: #function), "Updating Audience shared state")
        createSharedState(data: sharedStateData as [String: Any], event: event)
    }

    /// Sends an opt-out hit if the current privacy status is opted-out
    /// - Parameter event: the event responsible for sending this opt-out hit
    private func handleOptOut(event: Event) {
        guard let configSharedState = getSharedState(extensionName: AudienceConstants.SharedStateKeys.CONFIGURATION, event: event)?.value else { return }
        guard let aamServer = configSharedState[AudienceConstants.Configuration.AAM_SERVER] as? String else { return }
        let uuid = state?.getUuid() ?? ""

        // only send the opt-out hit if the audience manager server and uuid are not empty
        if !uuid.isEmpty && !aamServer.isEmpty {
            ServiceProvider.shared.networkService.sendOptOutRequest(aamServer: aamServer, uuid: uuid)
        }
    }

    /// Processes a response from the Audience Manager server or Analytics extension. This function attempts to forward any necessary requests found in the AAM "dests" array, and to create a dictionary out of the contents of the "stuff" array.
    /// - Parameters:
    ///   - event: the response event to be processed
    ///   - response: the JSON response received
    private func processNetworkResponse(event: Event, response: Data) {
        // bail if we don't have configuration yet
        guard let configSharedState = getSharedState(extensionName: AudienceConstants.SharedStateKeys.CONFIGURATION, event: event)?.value else { return }
        // quick out if privacy somehow became opted out after receiving a network response
        if state?.getPrivacyStatus() == .optedOut {
            Log.debug(label: "\(name):\(#function)", "Will not process the network response as privacy is opted-out.")
            return
        }
        let timeout = getAudienceManagerTimeout(configurationSharedState: configSharedState)
        // if we have an error decoding the response, log it and bail early
        guard let audienceResponse = try? JSONDecoder().decode(AudienceHitResponse.self, from: response) else {
            Log.debug(label: "\(name):\(#function)", "Failed to decode Audience Manager response.")
            return
        }

        // process dests array
        processDestsArray(response: audienceResponse, timeout: timeout)

        // save uuid for use with subsequent calls
        let uuid = audienceResponse.uuid ?? ""
        state?.setUuid(uuid: uuid)

        // process stuff array
        let processedStuff = processStuffArray(stuff: audienceResponse.stuff ?? [AudienceStuffObject]())

        if !processedStuff.isEmpty {
            Log.trace(label: "\(name):\(#function)", "Response received: \(processedStuff).")
        } else {
            Log.trace(label: "\(name):\(#function)", "Response was empty.")
        }

        // save profile in defaults
        state?.setVisitorProfile(visitorProfile: processedStuff)

        // update audience manager shared state
        createSharedState(data: state?.getStateData() ?? [:], event: event)
    }

    /// Parses the "dests" array present in the Audience Manager response and forwards data to the url's found.
    /// - Parameters:
    ///   - response: the `AudienceHitResponse` if any
    ///   - timeout: the Audience Manager network request timeout
    private func processDestsArray(response: AudienceHitResponse, timeout: TimeInterval) {
        // check "dests" for urls to forward
        let destinations = (response.dests ?? [String]()) as [String]
        if !destinations.isEmpty {
            for dest in destinations {
                if !dest.isEmpty {
                    guard let url = URL(string: dest) else {
                        Log.error(label: "\(name):\(#function)", "Building destination URL failed, skipping forwarding for: \(dest).")
                        continue
                    }
                    Log.debug(label: "\(name):\(#function)", "Forwarding to url: \(dest).")
                    let networkRequest = NetworkRequest(url: url, httpMethod: .get, connectPayload: "", httpHeaders: [String: String](), connectTimeout: timeout, readTimeout: timeout)
                    ServiceProvider.shared.networkService.connectAsync(networkRequest: networkRequest, completionHandler: nil) // fire and forget
                }
            }
        } else {
            Log.debug(label: "\(name):\(#function)", "No destinations found in response.")
        }
    }

    /// Parses the "stuff" array and returns a dictionary containing the segments for the user.
    /// - Parameters:
    ///   - stuff: the stuff dictionary contained in the `AudienceHitResponse`
    private func processStuffArray(stuff: [AudienceStuffObject]) -> [String: String] {
        var segments = [String: String]()
        if !stuff.isEmpty {
            for stuffObject in stuff {
                guard let key = stuffObject.cookieKey else {
                    Log.debug(label: "\(name):\(#function)", "Error processing stuff object with cookie name \(String(describing: stuffObject.cookieKey)).")
                    continue
                }
                guard let value = stuffObject.cookieValue else {
                    Log.debug(label: "\(name):\(#function)", "Error processing stuff object with cookie value \(String(describing: stuffObject.cookieValue)).")
                    continue
                }
                segments[key] = value
            }
        } else {
            Log.debug(label: "\(name):\(#function)", "No `stuff` array found in response.")
        }

        return segments
    }

    /// Converts Lifecycle event data to Audience Manager context data
    /// - Parameters:
    ///   - event: the `Lifecycle` response content event
    private func convertLifecycleKeys(event: Event) -> [String: String] {
        var convertedKeys = [String: String]()
        guard let lifecycleEventData:[String: Any] = event.data else {
            return [String: String]()
        }

        if !lifecycleEventData.isEmpty {
            for keyValuePair in AudienceConstants.MapToContextDataKeys {
                guard let value = lifecycleEventData[keyValuePair.key] else {
                    Log.debug(label: "\(name):\(#function)", "\(keyValuePair.key) not found in lifecycle context data.")
                    continue
                }
                convertedKeys[keyValuePair.value] = value as? String
            }
        } else {
            Log.debug(label: "\(name):\(#function)", "No data found in the lifecycle response event.")
        }

        return convertedKeys
    }

    // MARK: Network Response Handler

    /// Invoked by the `IdentityHitProcessor` each time we receive a network response
    /// - Parameters:
    ///   - entity: The `DataEntity` that was processed by the hit processor
    ///   - responseData: the network response data if any
    private func handleNetworkResponse(entity: DataEntity, responseData: Data?) {
        if state?.getPrivacyStatus() != .optedOut, let data = entity.data, let hit = try? JSONDecoder().decode(AudienceHit.self, from: data) {
            processNetworkResponse(event: hit.event, response: data)
        }
    }

    // MARK: Helper

    func getLogTagWith(functionName: String) -> String {
        return "\(name):\(functionName)"
    }

    /// Reads the Audience Manager timeout from the configuration shared state. If not found, returns the default Audience Manager timeout of 2 seconds.
    /// - Parameter configurationSharedState: the data associated with the configuration shared state
    private func getAudienceManagerTimeout(configurationSharedState: [String: Any]?) -> TimeInterval {
        guard let timeout = configurationSharedState?[AudienceConstants.Configuration.AAM_TIMEOUT] as? Int else {
            return TimeInterval(AudienceConstants.Default.TIMEOUT)
        }

        return TimeInterval(timeout)
    }

    /// Reads the Analytics AAM forwarding status from the configuration shared state.
    /// - Parameter configurationSharedState: the data associated with the configuration shared state
    private func getAnalyticsAAMForwardingStatus(configurationSharedState: [String: Any]?) -> Bool {
        guard let status = configurationSharedState?[AudienceConstants.Configuration.ANALYTICS_AAM_FORWARDING] as? Bool else {
            return false
        }

        return status
    }

    /// Reads the Experience Cloud Org Id from the configuration shared state.
    /// - Parameter configurationSharedState: the data associated with the configuration shared state
    private func getOrgId(configurationSharedState: [String: Any]?) -> String {
        guard let orgId = configurationSharedState?[AudienceConstants.Configuration.EXPERIENCE_CLOUD_ORGID] as? String else {
            return ""
        }

        return orgId
    }

}
