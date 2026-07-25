import AVFoundation
import SwiftData
import SwiftUI
import MapKit

// Users can use this to create their own custom context pools if the predefined groupings
// aren't good enough for them
//
// @NOTE: define Context with var when instantiating, otherwise categories become immutable
struct Context {
    var categories: [MKPointOfInterestCategory] // all POI categories in this context
    var isEnabled: Bool                         // are we checking for this context
    let name: String                            // user defined name of context
    let contextColor: Color                     // color/theme for background when in context 
    
    let radius: CLLocationDistance              // radius of a given zone, i.e. stores may have a smaller radius than parks 
    let priority: Int                           // priority level from 0-100 where 100 is the highest
}
