//
//  Item.swift
//  LittleRoute
//
//  Created by Dean Nemphos on 12/4/24.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
