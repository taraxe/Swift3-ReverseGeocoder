import UIKit
import CoreLocation
import PlaygroundSupport
import Foundation

PlaygroundPage.current.needsIndefiniteExecution = true

class ReverseGeocoder: NSObject {
    
    static let instance:ReverseGeocoder = ReverseGeocoder()
    
    struct UID :Equatable {
        let value:Int
        static func ==(lhs: UID, rhs: UID) -> Bool {
            return lhs.value.hashValue == rhs.value.hashValue
        }
    }
    
    struct GeoHashString : Hashable {
        let value:String
        var hashValue:Int { get {
            return value.hashValue
        }}
        static func ==(lhs: GeoHashString, rhs: GeoHashString) -> Bool {
            return lhs.value.hashValue == rhs.value.hashValue
        }
    }
    
    struct Request : Geohashable {
        let latitude: CLLocationDegrees
        let longitude: CLLocationDegrees
        let priority: Priority
        let uid:UID
        
        func toCLoc() -> CLLocation {
            return CLLocation(latitude: self.latitude, longitude: self.longitude)
        }
        
        func geoHash() -> GeoHashString {
            return GeoHashString(value : self.geohash)
        }
        
        func copy(priority:Priority)-> Request{
            return Request(latitude: self.latitude, longitude: self.longitude, priority: priority, uid: self.uid)
        }
    }
    
    struct MaxRetryError : Error {
        let message:String
        init(_ description:String){
            message = description
        }
    }
    enum Priority: Int {
        case low = 0
        case medium = 1
        case high = 2
    }
    
    typealias Response = [CLPlacemark]
    
    private let geocoder = CLGeocoder()
    private let timer:DispatchSourceTimer
    private let timerQueue = DispatchQueue(label :"com.zenly.reversegeocoder.timer", qos: .default)
    private let workerQueue = DispatchQueue(label: "com.zenly.reversegeocoder.worker", qos: .default)
    private let lockQueue = DispatchQueue(label: "com.zenly.reversegeocoder.lock", qos: .default, attributes: .concurrent)
    
    private var workItems:[WorkItem] = []
    private var cache = Cache<GeoHashString, Response>()
    private let maxRetries:Int
    
    private init(heartBeat:DispatchTimeInterval = DispatchTimeInterval.seconds(3), retries:Int = 3){
        timer = DispatchSource.makeTimerSource(flags: [], queue: timerQueue)
        timer.scheduleRepeating(deadline: DispatchTime.now(), interval: heartBeat)
        maxRetries = retries
        super.init()
        timer.setEventHandler(handler: handleWorkItem)
        
    }
    
    typealias Callback = (Result<Response>) -> ()
    typealias Operation = (Request, @escaping Callback) -> ()
    typealias WorkItem = (Request, Operation, Date, Callback, Int)
    
    /* Helpers */
    private static func sameUuid(_ request:Request) -> ((WorkItem)-> Bool) {
        return {(item:WorkItem) -> Bool in
            return item.0.uid == request.uid
        }
    }
    private static let priorityAndDateSort = { (a:WorkItem, b:WorkItem) -> Bool in
        return (a.0.priority.rawValue < b.0.priority.rawValue) && (a.2 > b.2)
    }
    
    
    func queue(request:Request, callback:@escaping Callback) {
        
        let hash = request.geoHash()
        if let cached = cache.get(hash){
            // if we find it in cache, no need to queue, return result
            callback(Result.success(cached))
        } else {
            
            // build the operation to be processed by the worker
            let operation:Operation = { (req:Request, cb:@escaping Callback) in
                
                self.reverseGeocode(req){ resp in
                    if case let Result.success(value) = resp, value.count > 0 {
                        self.cache.set(hash, value)
                    }
                    cb(resp)
                }
            }
            
            self.withWriteLock {
                // if we find a request with same uuid, replace the associated operation
                if let index = self.workItems.index(where : ReverseGeocoder.sameUuid(request)) {
                    let (req, _, _, _, _) = self.workItems[index]
                    print("Found request with same uid \(req.uid), will replace it")
                    self.workItems.remove(at: index)
                }
                print("Queuing (\(request.latitude), \(request.longitude)) with priority \(request.priority.rawValue) and uid \(request.uid)")
                self.workItems.append((request, operation, Date(), callback, 0))
                self.workItems.sort(by: ReverseGeocoder.priorityAndDateSort)
            }
        }
    }
    
    private func withReadLock(_ block:@escaping () -> ()) {
        lockQueue.async(execute: block)
    }
    private func withWriteLock(_ block:@escaping () -> ()) {
        lockQueue.async(execute: DispatchWorkItem(qos: .default, flags: .barrier, block: block ))
    }
    
    func updatePriority(on:@escaping (WorkItem) -> Bool, priority:Priority){
        withWriteLock {
            if let index = self.workItems.index(where: { on($0) }) {
                let (req, op, _, cb, retries) = self.workItems[index]
                self.workItems.insert((req.copy(priority: priority), op, Date(), cb, retries), at: index)
            }
        }
        
    }
    
    func cancel(on:@escaping (WorkItem) -> Bool){
        withWriteLock {
            if let index = self.workItems.index(where: { on($0) }) {
                self.workItems.remove(at: index)
            }
        }
        
    }
    
    private func reverseGeocode(_ request:Request, _ callback:@escaping (Result<Response>)->()){
        self.geocoder.reverseGeocodeLocation(request.toCLoc(), completionHandler: { result in
            callback(result.1.map {Result.failure($0)} ?? Result.success(result.0 ?? []))
        })
    }
    
    private func handleWorkItem(){
        self.withWriteLock {
            var shouldRepeat = false
            repeat {
                if let (request, operation, date, callback, retries) = self.workItems.popLast() {
                    let hash = request.geoHash()
                    if let fromCache = self.cache.get(hash) {
                        shouldRepeat = true
                        callback(Result.success(fromCache))
                    } else {
                    
                        if retries < self.maxRetries {
                            self.workerQueue.async(execute : { _ in
                            
                                operation(request){ result in
                                    switch result {
                                        case .success(_):
                                            callback(result)
                                        case .failure(_):
                                            // TODO handle CLError.Code to decide if we should retry or not
                                            self.workItems.append((request, operation, date, callback, retries + 1))
                                    }
                                }
                            })
                        } else {
                            callback(Result.failure(MaxRetryError("Could not fetch result after \(self.maxRetries) retries")))
                        }
                    }
                }
            } while shouldRepeat
        }
    }
    
    func start(){
        timer.activate()
    }
    
    func stop(){
        timer.cancel()
        workItems.removeAll()
        cache.flush()
    }
}

let rg = ReverseGeocoder.instance

let reqs = [
    ReverseGeocoder.Request(latitude: CLLocationDegrees(48.8631359), longitude: CLLocationDegrees(2.313386), priority: ReverseGeocoder.Priority.high, uid: ReverseGeocoder.UID(value: 1)),
    ReverseGeocoder.Request(latitude: CLLocationDegrees(48.840698), longitude: CLLocationDegrees(2.3673583), priority: ReverseGeocoder.Priority.low, uid: ReverseGeocoder.UID(value: 2)),
    ReverseGeocoder.Request(latitude: CLLocationDegrees(48.8606111), longitude: CLLocationDegrees(2.3354553), priority: ReverseGeocoder.Priority.medium, uid: ReverseGeocoder.UID(value: 1)),
    ReverseGeocoder.Request(latitude: CLLocationDegrees(48.869632), longitude: CLLocationDegrees(2.3694652), priority: ReverseGeocoder.Priority.low, uid: ReverseGeocoder.UID(value: 4)),
    ReverseGeocoder.Request(latitude: CLLocationDegrees(48.830816), longitude: CLLocationDegrees(2.3532014), priority: ReverseGeocoder.Priority.high, uid: ReverseGeocoder.UID(value: 5)),
    ReverseGeocoder.Request(latitude: CLLocationDegrees(48.830816), longitude: CLLocationDegrees(2.3532014), priority: ReverseGeocoder.Priority.high, uid: ReverseGeocoder.UID(value: 6)),
    ReverseGeocoder.Request(latitude: CLLocationDegrees(100000.0), longitude: CLLocationDegrees(0.0), priority: ReverseGeocoder.Priority.high, uid: ReverseGeocoder.UID(value: 7)), // a failing request
    ReverseGeocoder.Request(latitude: CLLocationDegrees(48.830816), longitude: CLLocationDegrees(2.5532014), priority: ReverseGeocoder.Priority.high, uid: ReverseGeocoder.UID(value: 8)),
    ReverseGeocoder.Request(latitude: CLLocationDegrees(40.833816), longitude: CLLocationDegrees(2.3532019), priority: ReverseGeocoder.Priority.high, uid: ReverseGeocoder.UID(value: 9)),
    ReverseGeocoder.Request(latitude: CLLocationDegrees(43.834816), longitude: CLLocationDegrees(2.3532314), priority: ReverseGeocoder.Priority.high, uid: ReverseGeocoder.UID(value: 10)),
]
rg.start()

reqs.forEach{ req in rg.queue(request: req){ result in
    switch result {
    case .success(let response):
        print("(\(req.latitude), \(req.longitude)) with priority \(req.priority.rawValue) -> OK")
    case .failure(let err):
        print(err.localizedDescription)
    }
    }}





