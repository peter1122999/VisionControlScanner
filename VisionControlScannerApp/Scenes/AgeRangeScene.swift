//
//  AgeRangeScene.swift
//  VisionControlScannerApp
//
//  Created by Avery Varney on 6/30/26.
//


//
//  AgeRangeScene.swift
//  VisionControlScannerApp
//
//  macOS 26 Setup Assistant – parental-controls age picker.
//

import Foundation

enum AgeRangeScene {
    static let definition = SceneDefinition(
        identifier: "ageRange",
        displayName: "Age Range",
        matchKeywords: [
            "age range",
            "select the age range",
            "set up parental controls",
            "parental controls and",
            "12 or younger",
            "13 to 17",
            "18 or older"
        ],
        layout: .listPicker
    )
}