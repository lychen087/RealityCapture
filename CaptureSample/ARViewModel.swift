//
//  ARViewModel.swift
//  RealityCapture
//
//  Created by lychen on 2024/4/4.
//

import Foundation
import Combine
import ARKit
import RealityKit
import os
import CoreMotion
import SwiftUI

enum AppError : Error {
    case projectAlreadyExists
    case manifestInitializationFailed
}

enum ModelState: String, CustomStringConvertible {
    var description: String { rawValue }

    case notSet
    
    case initialize
    case detecting
    case positioning
    case capturing1
    case capturing2
    case training
    case feedback
    case readyToRecapture
    
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

enum CaptureErrorLog: String, CaseIterable {
    case distance  // camera distance
    case height    // camera vertical angle
    case notAlign  // camera facing direction
    
    case capturing // no error
}


//private let logger = Logger(subsystem: "com.lychen.CaptureSample", category: "ARViewModel")
class ARViewModel : NSObject, ARSessionDelegate, ObservableObject {
    let logger = Logger(subsystem: "com.lychen.CaptureSample", category: "ARViewModel")

    @Published var appState = AppState()
    @Published var state: ModelState = .initialize {
        didSet {
            if state != oldValue {
                performStateTransition(from: oldValue, to: state)
            }
        }
    }
    
    var session: ARSession? = nil
    var arView: ARView? = nil
    var arConfiguration: ARConfiguration? = nil
    var cancellables = Set<AnyCancellable>()
    let datasetWriter: DatasetWriter
    
    init(datasetWriter: DatasetWriter) {
        self.datasetWriter = datasetWriter
        super.init()
        self.setupObservers()
        
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            print("ARWorldTrackingConfiguration: support depth!")
            self.appState.supportsDepth = true
        }
        
        startMotionDetection()
        
        let totalCount = 40
        for i in 0..<totalCount {
            self.checkpoints[i] = .initialized
        }
    }
    
    @Published var captureMode: CaptureMode = .manual
    

    @Published var anchorPosition: SIMD3<Float>? = nil // anchor position
    @Published var cameraPosition: SIMD3<Float>? = nil // camera position
    @Published var cameraDirection: SIMD3<Float>? = nil // camera facing direction
    
    @Published var originAnchor: AnchorEntity? = nil  // position of boundung box
    
    @Published var captureTrack: CaptureTrack? = nil  // captureTrack class: hemisphere, checkpoints
    @Published var closestPoint: Int? = nil
    @Published var checkpoints: [Int: PointStatus] = [:]  // state of each checkpoint
                                                          // e.g 2: .initialized
    
    @Published var captureError: CaptureErrorLog = .capturing // reason why cannot capture
    
    @Published var longestSide: Float = 0  // longest side of bounding box
    @Published var numOfCaptureTrack: Int = 2
    @Published var numOfCheckpoints: Int = 20
//    @Published var numOfCaptureTrack: Int = 2 {
//        didSet {
//            Task {
//                await createCaptureTrack()
//            }
//            
//        }
//    }
//    @Published var numOfCheckpoints: Int = 20 {
//        didSet {
//            Task {
//                await createCaptureTrack()
//            }
//        }
//    }
//    
    
    /// motion detection
    var motionDetection = MotionDetection()
    var lastAcceleration: CMAcceleration?

    func startMotionDetection() {
        motionDetection.startAccelerometerUpdates { [weak self] data, error in
            guard let strongSelf = self, let accelerationData = data else {
                print("Error reading accelerometer data: \(error?.localizedDescription ?? "No error info")")
                return
            }
            strongSelf.lastAcceleration = accelerationData.acceleration
            //let totalAcceleration = sqrt(pow(accelerationData.acceleration.x, 2) + pow(accelerationData.acceleration.y, 2) + pow(accelerationData.acceleration.z, 2))
            //print("Total acceleration: \(totalAcceleration - 1)") // minus the gravity
            //print("Accelerometer data: x: \(accelerationData.acceleration.x), y: \(accelerationData.acceleration.y), z: \(accelerationData.acceleration.z)")
        }
    }
    
    func stopMonitoringAcceleration() {
        print("Stop Monitoring Acceleration.")
        motionDetection.stopAccelerometerUpdates()
    }

    func getAcceleration() -> Double? {
        guard let acceleration = lastAcceleration else {
            print("No acceleration data available.")
            return nil
        }
        let totalAcceleration = sqrt(pow(acceleration.x, 2) + pow(acceleration.y, 2) + pow(acceleration.z, 2))
        return totalAcceleration - 1 // minus the gravity
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
        guard let curAcceleration = getAcceleration(), curAcceleration < 0.05 else {
            print("Acceleration too high: \(getAcceleration() ?? 0), cannot capture frame.")
            return
        }
        
        session?.captureHighResolutionFrame { [weak self] frame, error in
            guard let self = self, let frame = frame, let closestPointIndex = self.closestPoint else {
                print("Error capturing high-resolution frame: \(error?.localizedDescription ?? "Closest Point Error")")
                return
            }
            let width = CVPixelBufferGetWidth(frame.capturedImage)
            let height = CVPixelBufferGetHeight(frame.capturedImage)
            print("Received frame with dimensions: \(width) x \(height)")
            
            print("Captured frame with closest point index: \(closestPointIndex)")
            self.checkpoints[closestPointIndex] = .captured
//            print("Status after update: \(self.checkpoints[closestPointIndex])")
            
            self.datasetWriter.writeFrameToDisk(frame: frame, viewModel: self)
            
        }
    }
    
    func setupObservers() {
        datasetWriter.$writerState.sink {x in self.appState.writerState = x} .store(in: &cancellables)
        datasetWriter.$currentFrameCounter.sink { x in self.appState.numFrames = x }.store(in: &cancellables)
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
        self.arConfiguration = config
        session?.run(config, options: [.resetTracking])
    }
    
    func updateCaptureSettings(numOfCheckpoints: Int, numOfCaptureTrack: Int) {
        Task {
            self.numOfCheckpoints = numOfCheckpoints
            self.numOfCaptureTrack = numOfCaptureTrack
            await createCaptureTrack()
        }
    }
    
    
    func createCaptureTrack() async {
        guard let originAnchor = self.originAnchor, let anchorPosition = self.anchorPosition else {
            logger.error("originAnchor or anchorPosition is nil")
            return
        }
        
        if let existingTrack = self.captureTrack {
            await self.originAnchor?.removeChild(existingTrack)
            logger.log("Old CaptureTrack removed from originAnchor")
        }
        
        let boundingBoxSize = await calculateBoundingBoxSize()
        if(self.longestSide == 0) {  // only needs to calculate once
            self.longestSide = max(boundingBoxSize.x, boundingBoxSize.y, boundingBoxSize.z)
        }
        
        let scaleFactor: Float = 0.2
        let radiusFactor: Float = 2
        print("createCaptureTrack: Scaling size of hemisphere = \(longestSide * scaleFactor)")
        print("createCaptureTrack: checkpoint radius = \(longestSide * radiusFactor)")

        let captureTrack = await CaptureTrack(anchorPosition: anchorPosition,
                                        originAnchor: originAnchor,
                                        scale: longestSide * scaleFactor,
                                        radius: longestSide * radiusFactor,
                                        model: self)
        await captureTrack.setup()
        
        await MainActor.run {
           captureTrack.name = "CaptureTrack"
           originAnchor.addChild(captureTrack)
           self.captureTrack = captureTrack
           print("CaptureTrack created and added to originAnchor")
           print("Children of originAnchor: \(originAnchor.children.map { $0.name })")
       }
    }
    
    // MARK: - ARSession
    // 每幀 ARframe 更新都會呼叫
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let cameraTransform = frame.camera.transform
        self.cameraPosition = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        
        let forward = SIMD3<Float>(-cameraTransform.columns.2.x, -cameraTransform.columns.2.y, -cameraTransform.columns.2.z)
        self.cameraDirection = normalize(forward)
    
        if self.state == .capturing1 {
            // 每幀都要尋找當下最近的 checkpoint
            if let track = captureTrack {
                self.closestPoint = track.findNearestPoint(cameraPosition: cameraPosition!, cameraDirection: cameraDirection!, anchorPosition: anchorPosition!, count: self.numOfCheckpoints)
                track.updatePoints(pointIndex: self.closestPoint!)
            }
        }

    }
    
    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        self.appState.trackingState = trackingStateToString(camera.trackingState)
    }
    
    func pauseARSession() {
        logger.log("Pause AR session")
        self.arView?.session.pause()
    }
    
    func resumeARSession() {
        logger.log("Resume AR Session")
        self.arView?.session.run(self.arConfiguration!)
    }
    
    private func performStateTransition(from fromState: ModelState, to toState: ModelState) {
        if fromState == .failed {
            print("Error to failed state.")
        }

        switch toState {
        case .notSet:
            logger.info("Set ModelState to notSet")
        case .initialize:
            logger.info("Set ModelState to initialize")
        
        case .detecting:
            logger.info("Set ModelState to detecting")
            if let originAnchor = originAnchor {
                if let entity = originAnchor.children.first(where: {$0.name == "CaptureTrack"}) {
                    // print("Remove CaptureTrack")
                    entity.removeFromParent()
                }
                
                removeAllChildren(of: originAnchor)
                print("All children of originAnchor have been removed.")
                print("Children of originAnchor: \(originAnchor.children.map { $0.name })")
            } else {
                print("originAnchor is nil, cannot remove children.")
            }
            
        case .positioning:
            logger.info("Set ModelState to positioning")

        case .capturing1:
            logger.info("Set ModelState to capturing")
            
            Task { @MainActor in
                if let originAnchor = self.originAnchor {
                    print("Children of originAnchor: \(originAnchor.children.map { $0.name })")
                }
                
                // create capture track based on size of bounding box
                if (originAnchor?.children.first(where: { $0.name == "CaptureTrack"})) != nil {
                    print("captureTrack is existed")
                } else {
                    logger.log("Create captureTrack")
                    await createCaptureTrack()
                }
                
                // remove bounding from AR scene
                if let boundingBox = originAnchor?.children.first(where: { $0.name == "BoundingBox" }) {
                    logger.log("BoundingBox found, removing all children")
                    boundingBox.children.removeAll() // 移除 BoundingBox 底下的所有 children
                } else {
                    print("BoundingBox not found")
                }
            }
            
            
        case .training:
            logger.info("Set ModelState to training")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in  // transfer to .feedback state after 3 seconds
                self?.state = .feedback
            }
        case .feedback:
            logger.info("Set ModelState to feedback")
            
        case .readyToRecapture:
            logger.info("Set ModelState to readyToRecapture")


        case .failed:
            // Shows error screen.
            logger.info("App failed state error")
        default:
            break
        }
    }
    
    
    func updateAnchorPosition(_ anchorPosition: SIMD3<Float>, originAnchor: AnchorEntity) {
        self.anchorPosition = anchorPosition
        self.originAnchor = originAnchor
        print("update origin anchor in viewModel: \(originAnchor.position)")
    }
    
    func removeAllChildren(of entity: Entity) {
        for child in entity.children {
            print("removing: \(child.name)")
            removeAllChildren(of: child)
            entity.removeChild(child)
        }
    }

    func calculateBoundingBoxSize() async -> SIMD3<Float> {
//        print("Children of originAnchor: \(await String(describing: self.originAnchor?.children.map { $0.name }))")

        guard let lineXEntity = await self.originAnchor?.findEntity(named: "line2") as? ModelEntity,
            let lineYEntity = await self.originAnchor?.findEntity(named: "line3") as? ModelEntity,
            let lineZEntity = await self.originAnchor?.findEntity(named: "line5") as? ModelEntity,
              let meshX = await lineXEntity.components[ModelComponent.self]?.mesh,
              let meshY = await lineYEntity.components[ModelComponent.self]?.mesh,
              let meshZ = await lineZEntity.components[ModelComponent.self]?.mesh else {
            logger.error("One or more entities are missing or do not have a ModelComponent.")
            return SIMD3<Float>(0, 0, 0)
        }

        let lengthX = await meshX.bounds.max.x - meshX.bounds.min.x
        let lengthY = await meshY.bounds.max.y - meshY.bounds.min.y
        let lengthZ = await meshZ.bounds.max.z - meshZ.bounds.min.z

        return SIMD3<Float>(lengthX, lengthY, lengthZ)
    }
    

    
    // MARK: - New Framework
    @Published var alreadySetup: Bool = false
    @Published var isUploading: Bool = false
    
    /// Reference to the most recently captured image and its metadata (for thumbnail)
    @Published var lastCapture: Capture? = nil
    
    @Published var captureFolderState: CaptureFolderState?
    
    var captureDir: URL? {
        return captureFolderState?.captureDir
    }
    
    
    func requestNewCaptureFolder() {
        print("Requesting new capture folder...")
        
        DispatchQueue.main.async {
            self.lastCapture = nil
        }
        
        sessionQueue.async {
            do {
                let newCaptureFolder = try ARViewModel.createNewCaptureFolder()
                print("Created new capture folder: \"\(String(describing: self.captureDir))\"")
                DispatchQueue.main.async {
                    print("Publishing new capture folder: \"\(String(describing: self.captureDir))\"")
                    self.captureFolderState = newCaptureFolder
                }
            } catch {
                print("Can't create new capture folder!")
            }
        }
    }
    
    private let sessionQueue = DispatchQueue(label: "ARViewModel: sessionQueue")
    
    private static func createNewCaptureFolder() throws -> CaptureFolderState {
        guard let newCaptureDir = CaptureFolderState.initializeProject() else {
            throw SetupError.failed(msg: "Can't create capture directory!")
        }
        return CaptureFolderState(url: newCaptureDir)
    }
    
    private enum SetupError: Error {
        case failed(msg: String)
    }
}



//struct ContentView1: View {
//    @StateObject private var viewModel = ARViewModel(datasetWriter: DatasetWriter())
//
//    var body: some View {
//        Text("Current state: \(viewModel.state.rawValue)")
//            .foregroundColor(.blue)
//            .padding()
//    }
//}
//
//struct ContentView_Previews2: PreviewProvider {
//    static var previews: some View {
//        ContentView1()
//    }
//}
