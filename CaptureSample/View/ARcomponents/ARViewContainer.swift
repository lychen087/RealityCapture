//
//  ARViewContainer.swift
//  RealityCapture
//
//  Created by lychen on 2024/7/15.
//

import Foundation
import SwiftUI
import RealityKit
import SceneKit

struct ARViewContainer: UIViewRepresentable {
    @ObservedObject var viewModel: ARViewModel
    
    init(_ vm: ARViewModel) {
        viewModel = vm
    }
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        
        let configuration = viewModel.createARConfiguration()
        configuration.planeDetection = [.horizontal]
        configuration.worldAlignment = .gravity
        configuration.isAutoFocusEnabled = true
        
        arView.debugOptions = [.showWorldOrigin]

        arView.session.run(configuration)
        arView.session.delegate = viewModel
        
        // Add tapping gesture, and add a new anchor and bounding box when tapped
        let tapGesture = UITapGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handleTap(_:)))
        arView.addGestureRecognizer(tapGesture)
        

        let panGesture = UIPanGestureRecognizer(target: context.coordinator,
                                                action: #selector(Coordinator.handlePan(_:)))
        arView.addGestureRecognizer(panGesture)
        
        
        viewModel.session = arView.session
        viewModel.arView = arView
        viewModel.arConfiguration = configuration
        
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(self)
        viewModel.$state.sink { [weak coordinator] newState in
            if newState == .detecting {
                coordinator?.resetBoundingBox()
            }
        }.store(in: &viewModel.cancellables)
        
        return coordinator
    }
}
