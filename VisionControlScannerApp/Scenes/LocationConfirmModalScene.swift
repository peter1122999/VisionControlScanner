//
//  LocationConfirmModalScene.swift
//  VisionControlScannerApp
//
//  Created by Avery Varney on 6/30/26.
//


//
//  LocationConfirmModalScene.swift
//  VisionControlScannerApp
//
//  Confirmation modal that pops over Location Services when the user
//  clicks "Don't Use Location Services" from the parent scene.
//

import Foundation

enum LocationConfirmModalScene {
    static let definition = SceneDefinition(
        identifier: "locationConfirmModal",
        displayName: "Location Confirm",
        matchKeywords: [
            "are you sure you don't want to use location",
            "are you sure you don't want to use location services",
            "don't use location services"
        ],
        layout: .infoWithContinue,
        promoteToButtons: ["cancel", "don't use"]
    )
}