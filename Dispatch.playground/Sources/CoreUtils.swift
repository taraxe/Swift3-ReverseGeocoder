import Foundation

public enum Result<Value> {
    /// Success wraps a Value value
    case success(Value)
    
    /// Failure wraps an ErrorType
    case failure(Error)
    
    public init(_ capturing: () throws -> Value) {
        do {
            self = .success(try capturing())
        } catch {
            self = .failure(error)
        }
    }
    public var value: Value? {
        switch self {
        case .success(let v): return v
        case .failure: return nil
        }
    }
    public var error: Error? {
        switch self {
        case .success: return nil
        case .failure(let e): return e
        }
    }
    public var isError: Bool {
        switch self {
        case .success: return false
        case .failure: return true
        }
    }
    public func unwrap() throws -> Value {
        switch self {
        case .success(let v): return v
        case .failure(let e): throw e
        }
    }
    public func flatMap<U>(transform: (Value) -> Result<U>) -> Result<U> {
        switch self {
        case .success(let val): return transform(val)
        case .failure(let e): return .failure(e)
        }
    }
    public func map<U>(transform: (Value) throws -> U) -> Result<U> {
        switch self {
        case .success(let val): return Result<U> { try transform(val) }
        case .failure(let e): return .failure(e)
        }
    }
}




public class Cache<K: Hashable, V> {
    var cache:[K:V] = [:]
    
    public init(){}
    
    public func set(_ key:K, _ value:V)->V{
        cache[key] = value
        return value
    }
    
    public func get(_ key:K)->V? {
        return cache[key]
    }
    public  func getOrElse(_ key:K, orElse:@escaping ()->V)->V? {
        return get(key) ?? set(key, orElse())
    }
    public  func flush(){
        self.cache.removeAll()
    }
}
