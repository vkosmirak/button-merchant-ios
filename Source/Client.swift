//
// Client.swift
//
// Copyright © 2018 Button, Inc. All rights reserved. (https://usebutton.com)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//

import Foundation
import UIKit

internal enum Service: String {
    
    case postInstall = "v1/app/deferred-deeplink"
    case order       = "v1/app/order"
    case appEvents   = "v1/app/events"
    
    static let baseURL = "https://mobileapi.usebutton.com/"
    static let formattedBaseURL = "https://%@.mobileapi.usebutton.com/"
    
    func urlWith(_ applicationId: ApplicationId?) -> URL {
        guard let appId = applicationId?.rawValue else {
            return URL(string: Self.baseURL + rawValue)!
        }
        return URL(string: String(format: Self.formattedBaseURL, appId) + rawValue)!
    }
}

internal struct PendingTask {
    var urlRequest: URLRequest
    var completion: (Data?, Error?) -> Void
}

internal protocol ClientType: Activity {
    var isConfigured: Bool { get set }
    var applicationId: ApplicationId? { get set }
    var session: URLSessionType { get }
    var userAgent: UserAgentType { get }
    var defaults: ButtonDefaultsType { get }
    var system: SystemType { get }
    var pendingTasks: [PendingTask] { get set }
    func fetchPostInstallURL(parameters: [String: Any], _ completion: @escaping (URL?, String?) -> Void)
    func reportOrder(orderRequest: ReportOrderRequestType, _ completion: ((Error?) -> Void)?)
    func reportEvents(_ events: [AppEvent], ifa: String?, _ completion: ((Error?) -> Void)?)
    init(session: URLSessionType, userAgent: UserAgentType, defaults: ButtonDefaultsType, system: SystemType)
}

internal final class Client: ClientType {
    var isConfigured: Bool = false
    var applicationId: ApplicationId? {
        didSet {
            isConfigured = true
            flushPendingRequests()
        }
    }
    var session: URLSessionType
    var userAgent: UserAgentType
    var defaults: ButtonDefaultsType
    var system: SystemType
    var pendingTasks = [PendingTask]()
    
    init(session: URLSessionType, userAgent: UserAgentType, defaults: ButtonDefaultsType, system: SystemType) {
        self.applicationId = nil
        self.session = session
        self.userAgent = userAgent
        self.defaults = defaults
        self.system = system
    }
    
    func fetchPostInstallURL(parameters: [String: Any], _ completion: @escaping (URL?, String?) -> Void) {
        let request = urlRequest(url: Service.postInstall.urlWith(applicationId), parameters: parameters)
        enqueueRequest(request: request, completion: { data, _ in
            guard let data = data,
                let responseDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let object = responseDict["object"] as? [String: Any],
                let action = object["action"] as? String,
                let attributionObject = object["attribution"] as? [String: Any] else {
                    completion(nil, nil)
                    return
            }
            DispatchQueue.main.async {
                completion(URL(string: action)!, attributionObject["btn_ref"] as? String)
            }
        })
    }
    
    func reportOrder(orderRequest: ReportOrderRequestType, _ completion: ((Error?) -> Void)?) {
        let request = urlRequest(url: Service.order.urlWith(applicationId), parameters: orderRequest.parameters)
        orderRequest.report(request, with: session) { data, error in
            self.refreshSessionIfAvailable(responseData: data)
            if let completion = completion {
                completion(error)
            }
        }
    }
    
    func reportEvents(_ events: [AppEvent], ifa: String?, _ completion: ((Error?) -> Void)?) {
        guard events.count > 0 else {
            if let completion = completion {
                completion("No events to report")
            }
            return
        }
        let body = AppEventsRequestBody(ifa: ifa, events: events)
        let request = urlRequest(url: Service.appEvents.urlWith(applicationId), parameters: body.dictionaryRepresentation)
        enqueueRequest(request: request) { _, error in
            if let completion = completion {
                completion(error)
            }
        }
    }
    
    func productViewed(_ product: ButtonProductCompatible?) {
        
    }
    
    func productAddedToCard(_ product: ButtonProductCompatible?) {
        
    }
    
    func cartViewed(_ products: [ButtonProductCompatible]?) {
        
    }
    
    private func flushPendingRequests() {
        pendingTasks.forEach { pendingTask in
            var urlRequest = pendingTask.urlRequest
            guard let bodyData = urlRequest.httpBody,
                var parameters = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
                    return
            }
            if let appId = applicationId {
                parameters["application_id"] = appId.rawValue
            }
            urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: parameters)
            enqueueRequest(request: urlRequest, completion: pendingTask.completion)
        }
        pendingTasks.removeAll()
    }
}

internal extension Client {
    
    func urlRequest(url: URL, parameters: [String: Any]? = nil) -> URLRequest {
        var urlRequest = URLRequest(url: url)
        var requestParameters = parameters ?? [:]
        
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(userAgent.stringRepresentation, forHTTPHeaderField: "User-Agent")
        
        if let sessionId = defaults.sessionId {
            requestParameters["session_id"] = sessionId
        }
        
        if let appId = applicationId {
            requestParameters["application_id"] = appId.rawValue
        }
        
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: requestParameters)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        return urlRequest
    }
    
    func enqueueRequest(request: URLRequest, completion: @escaping (Data?, Error?) -> Void) {
        guard isConfigured else {
            pendingTasks.append(PendingTask(urlRequest: request, completion: completion))
            return
        }
        
        let task = session.dataTask(with: request) { data, response, error  in
            DispatchQueue.main.async {
                guard let data = data,
                    let response = response as? HTTPURLResponse, 200...299 ~= response.statusCode else {
                        completion(nil, error)
                        return
                }
                
                self.refreshSessionIfAvailable(responseData: data)
                
                completion(data, nil)
            }
        }
        
        task.resume()
    }
    
    func refreshSessionIfAvailable(responseData: Data?) {
        guard let data = responseData,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let meta = json["meta"] as? [String: Any] else {
                return
        }
        
        let value = meta["session_id"]
        switch value {
        case is String:
            defaults.sessionId = value as? String
        case is NSNull:
            defaults.clearAllData()
        default:
            break
        }
    }
}
