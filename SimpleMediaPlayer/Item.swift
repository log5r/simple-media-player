//
//  Item.swift
//  SimpleMediaPlayer
//
//  Created by Judau on 2026/07/04.
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
