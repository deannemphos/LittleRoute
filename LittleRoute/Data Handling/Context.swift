import AVFoundation
import SwiftData
import MKPointOfInterestCategory

// Users can use this to create their own custom context pools if the predefined groupings
// aren't good enough for them
//
// @NOTE: define Context with var when instantiating, otherwise categories become immutable
struct Context {
    var categories: MKPointOfInterestCategory[] // all POI categories in this context
    var isEndabled: Bool                        // are we checking for this context
    let name: String                            // user defined name of context
    let contextColor: Color                     // color/theme for background when in context 
}
