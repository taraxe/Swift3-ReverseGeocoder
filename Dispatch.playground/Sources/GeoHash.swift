import Foundation
import CoreLocation

private let BASE32 = Array("0123456789bcdefghjkmnpqrstuvwxyz".characters)
private let BASE32_BITFLOW_INIT: UInt8 = 0b10000

private enum Parity {
    case Even, Odd
}

public protocol Geohashable {
    var latitude:  CLLocationDegrees { get }
    var longitude: CLLocationDegrees { get }
}

public extension Geohashable {
    var geohash: String {
        return geohash(precision: 8)
    }
    
    func geohash(precision: Int) -> String {
        var lat = (-90.0, 90.0)
        var lon = (-180.0, 180.0)
        
        var geohash = ""
        var parity: Parity = .Even
        var base32char = 0
        var bit = BASE32_BITFLOW_INIT
        
        let hash = { (coordinate: CLLocationDegrees, tupple: inout (Double, Double)) -> Void in
            let mid = (tupple.0 + tupple.1) / 2
            
            if coordinate >= mid {
                base32char |= Int(bit)
                tupple.0 = mid
            } else {
                tupple.1 = mid
            }
        }
        
        while geohash.characters.count < precision {
            switch parity {
            case .Even:
                hash(longitude, &lon)
            case .Odd:
                hash(latitude, &lat)
            }
            
            parity = (parity == .Even ? .Odd : .Even)
            
            bit >>= 1
            
            if bit == 0b00000  {
                geohash += String(BASE32[base32char])
                bit = BASE32_BITFLOW_INIT // set next character round.
                base32char = 0
            }
        }
        
        return geohash
    }
}
