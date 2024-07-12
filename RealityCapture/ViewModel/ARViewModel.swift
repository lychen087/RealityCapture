//
//  ARViewModel.swift
//  RealityCapture
//
//  Created by lychen on 2024/4/4.
//

import Foundation
import Zip
import Combine
import ARKit
import RealityKit
import os
import CoreMotion

enum AppError : Error {
    case projectAlreadyExists
    case manifestInitializationFailed
}

enum ModelState: String, CustomStringConvertible {
    var description: String { rawValue }

    case notSet
    case detecting
    case capturing
    case completed
    case restart
    case failed
}

enum CaptureMode: String, CaseIterable {
    case manual
    case auto
}

enum PointStatus: String, CaseIterable {
    case initialized
    case captured
    case pointed
}

class ARViewModel : NSObject, ARSessionDelegate, ObservableObject {
    let logger = Logger(subsystem: AppDelegate.subsystem, category: "ARViewModel")
    
    @Published var appState = AppState()
    @Published var state: ModelState = .notSet {
        didSet {
            logger.debug("didSet AppDataModel.state to \(self.state)")
            if state != oldValue {
                performStateTransition(from: oldValue, to: state)
            }
        }
    }
    
    var session: ARSession? = nil
    var arView: ARView? = nil
    var cancellables = Set<AnyCancellable>()
    let datasetWriter: DatasetWriter
    
    init(datasetWriter: DatasetWriter) {
        self.datasetWriter = datasetWriter
        super.init()
        //self.setupObservers()
        
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            print("ARWorldTrackingConfiguration: support depth!")
            self.appState.supportsDepth = true
        }
        
        //startMotionDetection()
        
        let count = 20
        for i in 0..<count {
            self.dialPoints[i] = .initialized
        }
    }
    
    @Published var captureMode: CaptureMode = .manual
    

    @Published var anchorPosition: SIMD3<Float>? = nil // anchor position
    @Published var cameraPosition: SIMD3<Float>? = nil // camera position
    
    @Published var originAnchor: AnchorEntity? = nil // position of boundung box
    
    //@Published var progressDial: ProgressDial? = nil
    @Published var closestPoint: Int? = nil
    @Published var dialPoints: [Int: PointStatus] = [:]
    //@Published var capturedPoints: [Int] = []
    
    /// motion detection
//    var motionDetection = MotionDetection()
//    var lastAcceleration: CMAcceleration?
//    
//    func startMotionDetection() {
//        motionDetection.startAccelerometerUpdates { [weak self] data, error in
//            guard let strongSelf = self, let accelerationData = data else {
//                print("Error reading accelerometer data: \(error?.localizedDescription ?? "No error info")")
//                return
//            }
//            strongSelf.lastAcceleration = accelerationData.acceleration
//            //let totalAcceleration = sqrt(pow(accelerationData.acceleration.x, 2) + pow(accelerationData.acceleration.y, 2) + pow(accelerationData.acceleration.z, 2))
//            //print("Total acceleration: \(totalAcceleration - 1)") // minus the gravity
//            //print("Accelerometer data: x: \(accelerationData.acceleration.x), y: \(accelerationData.acceleration.y), z: \(accelerationData.acceleration.z)")
//        }
//    }
    
//    func stopMonitoringAcceleration() {
//        logger.debug("Stop Monitoring Acceleration.")
//        motionDetection.stopAccelerometerUpdates()
//    }
//    
    func getAcceleration() -> Double? {
        //        guard let acceleration = lastAcceleration else {
        //            print("No acceleration data available.")
        //            return nil
        //        }
        //        let totalAcceleration = sqrt(pow(acceleration.x, 2) + pow(acceleration.y, 2) + pow(acceleration.z, 2))
        //        return totalAcceleration - 1 // minus the gravity
        return 0.02
    }
    
    /// timer & auto capture
    @Published var isAutoCapture: Bool = false
    var autoCaptureTimer: Timer? = nil
    func switchCaptureMode() {
        switch captureMode {
        case .manual:
            captureMode = .auto
            isAutoCapture = true
            startAutoCapture()
        case .auto:
            captureMode = .manual
            isAutoCapture = false
            stopAutoCapture()
        }
    }
    
    private func startAutoCapture() {
        autoCaptureTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
           self?.captureFrame()
        }
    }

    private func stopAutoCapture() {
       autoCaptureTimer?.invalidate()
       autoCaptureTimer = nil
    }
    
    func captureFrame() {
        guard let curAcceleration = getAcceleration(), curAcceleration < 0.02 else {
            print("Acceleration too high: \(getAcceleration() ?? 0), cannot capture frame.")
            return
        }
        
        session?.captureHighResolutionFrame { [weak self] frame, error in
            //guard let frame = frame else {
            guard let self = self, let frame = frame, let closestPointIndex = self.closestPoint else {
                print("Error capturing high-resolution frame: \(error?.localizedDescription ?? "Unknown error")")
                return
            }
            let width = CVPixelBufferGetWidth(frame.capturedImage)
            let height = CVPixelBufferGetHeight(frame.capturedImage)
            print("Received frame with dimensions: \(width) x \(height)")
            
            print("Captured frame with closest point index: \(closestPointIndex)")
            self.dialPoints[closestPointIndex] = .captured
//            print("Status after update: \(self.dialPoints[closestPointIndex])")
            
            self.datasetWriter.writeFrameToDisk(frame: frame, viewModel: self)
            
        }
    }
    
    
    
    func createARConfiguration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.isAutoFocusEnabled = true
        if type(of: configuration).supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics = .sceneDepth // Activate sceneDepth
        }
        
        if let highResFormat = ARWorldTrackingConfiguration.supportedVideoFormats.first(where: { $0.imageResolution.height >= 2160 }) {
            configuration.videoFormat = highResFormat
        }
        
        return configuration
    }
    
    func resetWorldOrigin() {
        session?.pause()
        let config = createARConfiguration()
        session?.run(config, options: [.resetTracking])
    }
    
    // MARK: - ARSession
    // 每幀 ARframe 更新都會呼叫
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let cameraTransform = frame.camera.transform
        self.cameraPosition = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        
//        if let dial = progressDial {
//            self.closestPoint = dial.findNearestPoint(cameraPosition: cameraPosition!, anchorPosition: anchorPosition!)
//            dial.updatePoints(pointIndex: self.closestPoint!)
//        }
    }
    
    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        self.appState.trackingState = trackingStateToString(camera.trackingState)
    }
    
    private func performStateTransition(from fromState: ModelState, to toState: ModelState) {
        if fromState == .failed {
            logger.error("Error to failed state.")
        }

        switch toState {
            case .notSet:
                logger.debug("Set ModelState to notSet")
            
            case .detecting:
                logger.debug("Set ModelState to detecting")
                if let entity = originAnchor?.children.first(where: { $0.name == "ProgressDial"}) {
                    entity.removeFromParent()
                } else {
                    logger.error("ProgressDial entity not found")
                }
            
            case .capturing:
                logger.debug("Set ModelState to capturing")
                
                if let entity = originAnchor?.children.first(where: { $0.name == "ProgressDial"}) {

                } else {
                    logger.info("Create ProgressDial.")
                    //createProgressDial()
                }

            case .failed:
                logger.error("App failed state error")
                // Shows error screen.
            default:
                break
        }
    }
    
//    private func createProgressDial() {
//        guard let originAnchor = self.originAnchor else {
//            logger.error("originAnchor is nil")
//            return
//        }
//        
//        self.progressDial = ProgressDial(anchorPosition: anchorPosition!, model: self)
//        self.progressDial?.name = "ProgressDial"
//        originAnchor.addChild(self.progressDial!)
//    }
    
    
//    func updateAnchorPosition(_ anchorPosition: SIMD3<Float>, originAnchor: AnchorEntity) {
//        self.anchorPosition = anchorPosition
//        self.originAnchor = originAnchor
//        print("update origin anchor in viewModel: \(originAnchor.position)")
//    }
//    
//    func calculateBoundingBoxSize() -> SIMD3<Float> {
//        guard let lineXEntity = self.originAnchor?.findEntity(named: "line2") as? ModelEntity,
//            let lineYEntity = self.originAnchor?.findEntity(named: "line3") as? ModelEntity,
//            let lineZEntity = self.originAnchor?.findEntity(named: "line5") as? ModelEntity,
//            let meshX = lineXEntity.components[ModelComponent.self]?.mesh,
//            let meshY = lineYEntity.components[ModelComponent.self]?.mesh,
//            let meshZ = lineZEntity.components[ModelComponent.self]?.mesh else {
//            print("One or more entities are missing or do not have a ModelComponent.")
//            return SIMD3<Float>(0, 0, 0)
//        }
//
//        let lengthX = meshX.bounds.max.x - meshX.bounds.min.x
//        let lengthY = meshY.bounds.max.y - meshY.bounds.min.y
//        let lengthZ = meshZ.bounds.max.z - meshZ.bounds.min.z
//
//        return SIMD3<Float>(lengthX, lengthY, lengthZ)
//  
//    }
}