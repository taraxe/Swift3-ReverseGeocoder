import Foundation

public extension Optional {
    public func exists(_ predicate: (Wrapped) -> Bool )-> Bool {
        return self.map{predicate($0)} ?? false
    }
}
