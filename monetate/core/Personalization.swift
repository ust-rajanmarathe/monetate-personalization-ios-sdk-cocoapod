//
//  Personalization.swift
//  monetate-ios-sdk-example
//
//  Created by Umar Sayyed on 29/09/20.
//  Copyright © 2020 Monetate. All rights reserved.
//

import Foundation

public class Personalization {
    
    static private var _shared: Personalization!
    //static members
    public static var shared:Personalization {
        if Personalization._shared == nil {
            fatalError("Error - you must call setup before accessing Personalization.shared")
        }
        return Personalization._shared
    }
    
    //setup method
    /**
     Creates the object that is used for all SDK activities
     
     Init with accountId, userId.
     */
    public static func setup(account: Account, user: User) {
        Personalization._shared = Personalization(account: account, user: user)
    }
    
    //class members
    public var account: Account
    private var user: User
    
    
    //constructor
    
    private init (account: Account, user: User) {
        self.account = account
        self.user = user
    }
    
    private var queue: [ContextEnum: MEvent] = [:]
    private var errorQueue: [MError] = []
    
    public var timer = ScheduleTimer(timeInterval: 0.7, callback: {
        _ = Personalization.shared.callMonetateAPI()
    })
    
    func isContextSwitched (ctx:ContextEnum, event: MEvent) -> Bool {
        if ((ctx == .UserAgent || ctx == .IpAddress || ctx == .Coordinates ||
             ctx == .ScreenSize || ctx == .Referrer ||
             ctx == .PageView || ctx == .Metadata ||
             ctx == .CustomVariables || ctx == .Language)),
           let val1 = self.queue[ctx] as? Context,
           let val2 = event as? Context, val1.isContextSwitched(ctx: val2) {
            
            return true
        }
        
        return false
    }
    
    private func callMonetateAPIOnContextSwitched (context: ContextEnum, event:MEvent) {
        Log.debug("\n>> context switched\n")
        
        self.callMonetateAPI().on(success: { (res) in
            
            Log.debug("callMonetateAPIOnContextSwitched Success - \(self.queue.keys.count)")
            self.queue[context] = event
            self.timer.resume()
        }, failure: { (er) in
            Log.debug("callMonetateAPIOnContextSwitched Failure")
            
            self.timer.resume()
        })
    }
    
    private func callMonetateAPIOnContextSwitchedForGetActions () -> Future<APIResponse, Error> {
        let promise = Promise <APIResponse, Error>()
        
        Log.debug("\n>> context switched\n")
        self.callMonetateAPI().on(success: { (res) in
            Log.debug("callMonetateAPIOnContextSwitchedForGetActions Success \(self.queue.keys.count)")
            
            promise.succeed(value: res)
        }, failure: { (er) in
            Log.debug("callMonetateAPIOnContextSwitchedForGetActions Success \(self.queue.keys.count)")
            
            promise.fail(error: er)
        })
        return promise.future
    }
    /**
     Used to manually send all queued reporting data immediately, instead of waiting for the next automatic send. That means make api call with existing data from queue and clear it.
     */
    public func flush () {
        _=callMonetateAPI()
    }
    
    public func setCustomerId (customerId: String) {
        self.user.setCustomerId(customerId: customerId)
    }
    
    func report (context:ContextEnum, eventCB:  (() -> Future<MEvent, Error>)?) {
        if let event = eventCB {
            event().on(success: { (data) in
                if self.isContextSwitched(ctx: context, event: data) {
                    self.callMonetateAPIOnContextSwitched(context: context, event: data)
                } else {
                    self.processEventsOnEventReporting(context, data)
                }
            }, failure: { (er) in
                self.errorQueue.append(MError(description: er.localizedDescription, domain: .RuntimeError, info: nil))
                Log.error("Error - \(er.localizedDescription)")
                
            })
        }
        
    }
    /**
     Used to add events to the queue, which will be sent with the next flush() call or as part of an automatic timed send.
     
     context is name of event for example monetate:record:Impressions.
     
     eventData is data associated with event and it is optional parameter.
     */
    public func report (context:ContextEnum, event: MEvent?) {
        guard let event = event else {
            self.timer.resume()
            return
        }
        if isContextSwitched(ctx: context, event: event) {
            self.callMonetateAPIOnContextSwitched(context: context, event: event)
        } else {
            self.processEventsOnEventReporting(context, event)
        }
    }
    
    private func processEventsOnEventReporting (_ context: ContextEnum, _ event: MEvent) {
        
        Log.debug("\n>>context switched - not\n")
        Utility.processEvent(context: context, data: event, mqueue: self.queue).on(success: { (queue) in
            self.queue = queue
            Log.debug("Event Processed")
            
            self.timer.resume()
        })
    }
    
    fileprivate func processEvents(_ context: ContextEnum, _ event: MEvent, _ requestId: String, _ arrActionTypes:[ActionTypeEnum], _ promise: Promise<APIResponse, Error>) {
        if isContextSwitched(ctx: context, event: event) {
            self.callMonetateAPIOnContextSwitchedForGetActions().on(success: { (res1) in
                Utility.processEvent(context: context, data: event, mqueue: self.queue).on(success: { (mqueue) in
                    self.queue = mqueue
                    //adding decision request event
                    self.queue[.DecisionRequest] = DecisionRequest(requestId: requestId, actionTypes: arrActionTypes)
                    self.callMonetateAPI(requestId: requestId).on(success: { (res) in
                        Log.debug("processEvents context switch - API success")
                        
                        promise.succeed(value: res)
                    }, failure: { (er) in
                        Log.debug("processEvents context switch - API failure")
                        
                        promise.fail(error: er)
                    })
                })
            }, failure: { (er) in
                promise.fail(error: er)
            })
        } else {
            Utility.processEvent(context: context, data: event, mqueue: self.queue).on(success: { (queue) in
                self.queue = queue
                //adding decision request event
                self.queue[.DecisionRequest] = DecisionRequest(requestId: requestId, actionTypes: arrActionTypes)
                self.callMonetateAPI(requestId: requestId).on(success: { (res) in
                    
                    Log.debug("processEvents without context switch  - API success")
                    promise.succeed(value: res)
                }, failure: { (er) in
                    
                    Log.error("processEvents without context switch  - API failure")
                    promise.fail(error: er)
                })
            })
        }
    }
    /**
     Used to record event and also request decision(s).
     
     requestId the request identifier tying the response back to an event
     
     context ? is name of event for example monetate:record:Impressions.
     
     eventData ? is data associated with event.
     
     context and eventData are optional fields.
     
     Returns an object containing the JSON from appropriate action(s), using the types in the action table below. Those objects are reformatted into a consistent returned json with a required actionType and action.
     
     Also sends any queue data.
     
     status is the value returned from {meta: {code: ###}}. Anything other than 200 does not include actions in the return.
     */
    public func getActions (context:ContextEnum, requestId: String, arrActionTypes:[ActionTypeEnum], event: MEvent?) -> Future<APIResponse, Error> {
        
        let promise = Promise <APIResponse, Error>()
        if let event = event {
            processEvents(context, event, requestId, arrActionTypes, promise)
        }else {
            //adding decision request event
            processDecision(requestId, arrActionTypes, promise)
        }
        
        return promise.future
    }
    
    /**
     Used to record multiple events and also request decisions.
     
     requestId the request identifier tying the response back to an event
     
     context ? is name of event for example monetate:record:Impressions.
     
     eventData ? is data associated with event.
     
     Returns an object containing the JSON from appropriate action(s), using the types in the action table below. Those objects are reformatted into a consistent returned json with a required actionType and action.
     
     status is the value returned from {meta: {code: ###}}. Anything other than 200 does not include actions in the return.
     */
    public func getActions (requestId: String, arrActionTypes:[ActionTypeEnum], eventsDict:[ContextEnum: MEvent]) -> Future<APIResponse, Error> {
        
        let promise = Promise <APIResponse, Error>()
        for object in eventsDict {
            Utility.processEvent(context: object.key, data: object.value, mqueue: self.queue).on(success: { (queue) in
                self.queue = queue
            })
        }
        processDecision(requestId, arrActionTypes, promise)
        return promise.future
    }
    
    /**
     Used to add events in queue.
     
     context ? is name of event for example monetate:record:Impressions.
     
     eventData ? is data associated with event.
     
     context and eventData are optional fields.
     
     */
    public func addEvent(context:ContextEnum, event: MEvent?) {
        if let event = event {
            Utility.processEvent(context: context, data: event, mqueue: self.queue).on(success: { (queue) in
                self.queue = queue
            })
        }
    }
    
    /**
     Used request decisions with multiple contexts.
     
     requestId the request identifier tying the response back to an event
     
     Returns an object containing the JSON from appropriate action(s), using the types in the action table below. Those objects are reformatted into a consistent returned json with a required actionType and action.
     
     Also sends any queue data.
     
     status is the value returned from {meta: {code: ###}}. Anything other than 200 does not include actions in the return.
     
     */
    public func getActionsData(requestId: String, arrActionTypes:[ActionTypeEnum]) -> Future<APIResponse, Error>  {
        let promise = Promise <APIResponse, Error>()
        processDecision(requestId, arrActionTypes, promise)
        return promise.future
    }
    
    fileprivate func processDecision(_ requestId: String, _ arrActionTypes:[ActionTypeEnum], _ promise: Promise<APIResponse, Error>) {
        //adding decision request event
        self.queue[.DecisionRequest] = DecisionRequest(requestId: requestId, actionTypes: arrActionTypes)
        self.callMonetateAPI(requestId: requestId).on(success: { (res) in
            Log.debug("processDecision - API success")
            promise.succeed(value: res)
        },failure: { (er) in
            Log.error("processDecision - API failure")
            promise.fail(error: er)
        })
    }
    
    func getActions (context:ContextEnum, requestId: String, arrActionTypes:[ActionTypeEnum], eventCB: (() -> Future<MEvent, Error>)?) -> Future<APIResponse, Error> {
        let promise = Promise <APIResponse, Error>()
        
        if let event = eventCB {
            event().on(success: { (data) in
                self.processEvents(context, data, requestId, arrActionTypes, promise)
            }, failure: { (er) in
                Log.debug("getActions with multi-events - failure")
                
                self.errorQueue.append(MError(description: er.localizedDescription, domain: .RuntimeError, info: nil))
                promise.fail(error: er)
            })
        } else {
            processDecision(requestId, arrActionTypes, promise)
        }
        return promise.future
    }
    
    var API_URL = "https://api.monetate.net/api/engine/v1/decide/"
    
    func callMonetateAPI (data: Data? = nil, requestId: String?=nil) -> Future<APIResponse,Error> {
        let promise = Promise<APIResponse,Error>()
        
        var body:[String:Any] = [
            "channel":account.getChannel(),
            "sdkVersion": account.getSDKVersion(),
            "events": Utility.createEventBody(queue: self.queue)]
        if let val = self.user.monetateId { body["monetateId"] = val }
        if let val = self.user.deviceId { body["deviceId"] = val }
        if let val = self.user.customerId { body["customerId"] = val }
        Log.debug("success - \(body.toString!)")
        
        self.timer.suspend()
        Service.getDecision(url: self.API_URL + account.getShortName(), body: body, headers: nil, success: { (data, status, res) in
            self.queue = [:]
            Log.debug("callMonetateAPI - Success - \(data.toString)")
            
            promise.succeed(value: APIResponse(success: true, res: res, status: status, data: data, requestId:requestId))
        }) { (er, d, status, res) in
            Log.debug("callMonetateAPI - Error")
            
            if let err = er {
                promise.fail(error: err)
                self.errorQueue.append(MError(description: err.localizedDescription, domain: .ServerError, info: nil))
            } else {
                let er = NSError.init(domain: "API Error", code: status!, userInfo: nil)
                if let val = d {
                    let merror = MError(description: er.localizedDescription, domain: .APIError, info: val.toJSON()!)
                    Log.error("callMonetateAPI Error Message- \(val.toString)")
                    
                    self.errorQueue.append(merror)
                    promise.fail(error: merror)
                } else {
                    self.errorQueue.append(MError(description: er.localizedDescription, domain: .APIError, info: nil))
                    promise.fail(error: er)
                }
            }
        }
        return promise.future
    }
}


