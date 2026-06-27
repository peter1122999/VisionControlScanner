//
//  NoICloudConfirmScene.swift
//  VisionControlScannerApp
//
//  Created by Avery Varney on 6/26/26.
//


// Scenes/NoICloudConfirmScene.swift
import Foundation

enum NoICloudConfirmScene {
    static let definition = SceneDefinition(
        identifier: "noICloudConfirm",
        displayName: "Skip Apple Account",
        matchKeywords: [
            "are you sure you don't want to sign in",
            "your mac and apple devices work better together",
            "set up without an apple account",
            "skip sign in"
        ],
        layout: .infoWithContinue
    )
}