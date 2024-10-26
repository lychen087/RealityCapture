//
//  CaptureTrack.swift
//  RealityCapture
//
//  Created by lychen on 2024/7/15.
//

import Foundation
import os
import ARKit
import RealityKit
import SwiftUI
import Combine

var DEBUG = false  // if true, logger will print capture infomation in every frame

private let logger = Logger(subsystem: "com.lychen.CaptureSample", category: "CaptureTrack")

class CaptureTrack: Entity, HasAnchoring {
    
    @ObservedObject var model: ARViewModel
    var originAnchor: AnchorEntity
    var anchorPosition: SIMD3<Float>
    
    var hemisphereSize: SIMD3<Float>
    
    var points: [ModelEntity] = []
    var index: Int = 0 // index of checkpoint

    // var count: Int = 20
    var radius: Float = 0.21  // according to the size of bounding box
    var scale: Float = 0.02   // according to the size of bounding box
    
    var firstHeight: Float = 0  // 第一圈高度
    var secondHeight: Float = 0 // 第二圈高度

    private var cancellable: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()
    
    init(anchorPosition: SIMD3<Float>, originAnchor: AnchorEntity, scale: Float, radius: Float, model: ARViewModel) {
        self.model = model
        self.originAnchor = originAnchor
        self.anchorPosition = anchorPosition
        self.scale = scale
        self.radius = radius 
        self.hemisphereSize = SIMD3<Float>(0, 0, 0)
        
        super.init()
        
        let numOfCheckpoints = model.numOfCheckpoints
        let numOfCaptureTrack = model.numOfCaptureTrack
        
        self.name = "CaptureTrack"
        
        let discMesh = MeshResource.generatePlane(width: 0.2, depth: 0.2, cornerRadius: 0.1)
        let material = SimpleMaterial(color: .red, isMetallic: false)
        let discEntity = ModelEntity(mesh: discMesh, materials: [material])
        discEntity.position = anchorPosition + SIMD3<Float>(0, 0.01, 0)
        
        logger.log("Init CaptureTrack")
//        Task {
//            logger.log("Init CaptureTrack:")
//        }
    }
    
    required init() {
        fatalError("init Has Not Been Implemented")
    }
    
    public func setup() async {
        logger.log("asyncLoadModelEntity: Load hemisphere")
        await asyncLoadModelEntity(scale: self.scale);  // load hemiSphere.usdz
        
        firstHeight = anchorPosition.y + 0.035
        secondHeight = anchorPosition.y + self.hemisphereSize.y * 0.5
        //logger.log("hemisphereSize.y = \(self.hemisphereSize.y)")
        //logger.log("secondHeight = \(self.secondHeight)")

        logger.log("createCheckPoints: Load checkpoints")
        createCheckPoints(center: anchorPosition, count: model.numOfCheckpoints, height: firstHeight, radiusScale: 1.0)
        if (model.numOfCaptureTrack == 2) {
            createCheckPoints(center: anchorPosition, count: model.numOfCheckpoints, height: secondHeight, radiusScale: 0.866)
        }
    }
    
    public func findNearestPoint(cameraPosition: SIMD3<Float>, cameraDirection: SIMD3<Float>, anchorPosition: SIMD3<Float>, count: Int) -> Int {
        let angleThreshold: Float = 15.0   // 仰角不能超過30度
        let distanceThreshold: Float = 0.4
        let directionThreshold: Float = 10.0  // 相機朝向和checkpoint角度差
        
        let interval = 360.0 / Float(count)
        
        var currentCircle: Int = -1   // current locate circle: 1, 2
        var closestPointIndex:Int = -1
        
        
        // in which height
        if abs(cameraPosition.y - firstHeight) < abs(cameraPosition.y - secondHeight) {
            currentCircle = 1
        } else {
            currentCircle = 2
        }
        
        
        // translate to relative position
        let cameraPos = cameraPosition - anchorPosition
        var cameraAngle = atan2(cameraPos.z, cameraPos.x) * 180 / Float.pi
        if cameraAngle < 0 { cameraAngle += 360 }
        
        // distance
        let distance = length(cameraPos)
        if distance > distanceThreshold {
            self.model.captureError = .distance
            if(DEBUG) { print("Camera is too far, ignoring closest point.") }
            return -1
        }
        
        // camera direction
        func isDirectionAligned(pointDirection: SIMD3<Float>, cameraDirection: SIMD3<Float>, threshold: Float) -> Bool {
            let normalizedPointDir = normalize(pointDirection)
            let normalizedCamDir = normalize(cameraDirection)
            let dotProduct = dot(normalizedPointDir, normalizedCamDir)
            
            // angle between point direction and camera direction
            let angle = acos(dotProduct) * 180 / Float.pi
            return abs(angle) <= threshold
        }

        
        if (points.count >= 40) {

            switch currentCircle {
            case 1:
                // vertical angle
                let baseIndex = Int(round(cameraAngle / interval)) % count
                let pointPosition = points[baseIndex].position - anchorPosition
                let horizonDist = sqrt(cameraPos.z * cameraPos.z + cameraPos.x * cameraPos.x)
                let elevationAngle = atan2(cameraPos.y - pointPosition.y, horizonDist) * 180 / Float.pi
                if abs(elevationAngle) <= angleThreshold {
                    if(DEBUG) { print("first height point: \(closestPointIndex)") }
                } else {
                    self.model.captureError = .height
                    if(DEBUG) { print("Camera is too high/low at first height.") }
                    return -1
                }
                
                // camera facing direction
                let pointDirection = normalize(anchorPosition - pointPosition)
                if isDirectionAligned(pointDirection: pointDirection, cameraDirection: cameraDirection, threshold: directionThreshold) {
                    closestPointIndex = baseIndex
                } else {
                    self.model.captureError = .notAlign
                    if(DEBUG) { print("Camera direction does not align with point.") }
                    return -1
                }
                
                
            case 2:
                let baseIndex = Int(round(cameraAngle / interval)) % count
                let pointPosition = points[baseIndex + count].position - anchorPosition
                let horizonDist = sqrt(cameraPos.z * cameraPos.z + cameraPos.x * cameraPos.x)
                let elevationAngle = atan2(cameraPos.y - pointPosition.y, horizonDist) * 180 / Float.pi
                
                if abs(elevationAngle) <= angleThreshold {
                    closestPointIndex = baseIndex + count
                    if(DEBUG) { print("second height point: \(closestPointIndex)") }
                }
                else {
                    self.model.captureError = .height
                    if(DEBUG) { print("second height: Camera is too high/low at second height.") }
                    return -1
                }
            default:
                closestPointIndex = -1
            }
        }
        
        if(DEBUG) { print("closest point is \(closestPointIndex)") }
    
        self.model.captureError = .capturing
        return Int(closestPointIndex)
    }
    
    public func updatePoints(pointIndex: Int) {
        DispatchQueue.main.async {
            for (index, entity) in self.points.enumerated() {
                let status = self.model.checkpoints[index]
                
                let color: UIColor
                if status == .captured {
                    color = .green   // captured point set to green
                } else {
                    let isPointed = (index == pointIndex)
                    color = (isPointed ? .yellow : .red)
                }
                
                let material = SimpleMaterial(color: color.withAlphaComponent(0.7), isMetallic: false)
                (entity as? ModelEntity)?.model?.materials = [material]
                
                if status != .captured {
                    self.model.checkpoints[index] = (index == pointIndex) ? .pointed : .initialized
                }
            }
        }
    }
    
    // Load hemisphere
    private func asyncLoadModelEntity(scale: Float) async {
        let filename = "hemisphere.usdz"

        await withCheckedContinuation { continuation in
            self.cancellable = ModelEntity.loadModelAsync(named: filename)
                .sink (receiveCompletion: { loadCompletion in
                    // error handle
                    switch loadCompletion {
                    case .failure(let error):
                        print("Error loading \(filename) model: \(error.localizedDescription)")
                    case .finished:
                         print("\(filename) model loaded successfully.")
                    }
                }, receiveValue: { modelEntity in
                    var material = SimpleMaterial()
                    material.color = .init(tint: .green.withAlphaComponent(0.3))
                    modelEntity.model?.materials = [material]
                    
                    modelEntity.position = self.anchorPosition + SIMD3<Float>(0, 0.001, 0)
                    modelEntity.scale = SIMD3<Float>(scale, scale, scale)
                    modelEntity.name = filename
                    self.addChild(modelEntity)
                    print("Children of captureTrack: \(self.children.map { $0.name })")
                    
                    // Calculate the size of hemisphere in world space
                    if let meshBounds = modelEntity.model?.mesh.bounds {
                        let extents = meshBounds.extents
                        let actualSize = SIMD3<Float>(extents.x * modelEntity.scale.x,
                                                      extents.y * modelEntity.scale.y,
                                                      extents.z * modelEntity.scale.z)
                        self.hemisphereSize = actualSize
                        print("Model size in space: width = \(actualSize.x), height = \(actualSize.y), depth = \(actualSize.z)")
                        print("Model size in space: hemisphereSize.x = \(self.hemisphereSize.x), hemisphereSize.y = \(self.hemisphereSize.y), hemisphereSize.z = \(self.hemisphereSize.z)")
                        
                        continuation.resume()
                    } else {
                        print("Failed to calculate model size.")
                        continuation.resume()
                    }
                })
        }
    }
    
    private func asyncLoadCheckPointEntity(filename: String, position: SIMD3<Float>, name: String, direction: SIMD3<Float>) {
        let cancellable = ModelEntity.loadModelAsync(named: filename)
            .sink (receiveCompletion: { loadCompletion in
//                switch loadCompletion {
//                case .failure(let error):
//                    print("Error loading \(filename) model: \(error.localizedDescription)")
//                case .finished:
//                    // print("\(filename) model loaded successfully.")
//                }
            }, receiveValue: { [self] modelEntity in
                
                var material = SimpleMaterial()
                material.color = .init(tint: .red.withAlphaComponent(0.7))
                modelEntity.model?.materials = [material]

                modelEntity.position = position
                
                //let angle = atan2(direction.z, -direction.x)
                //modelEntity.orientation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
                
                // 水平旋轉
                let horizontalDirection = SIMD2<Float>(direction.x, direction.z)
                let horizontalAngle = atan2(horizontalDirection.y, -horizontalDirection.x)
                let horizontalRotation = simd_quatf(angle: horizontalAngle, axis: SIMD3<Float>(0, 1, 0))
                
                // 垂直旋轉 (仰角)
                let verticalDirection = normalize(direction)
                let verticalAngle = Float.pi / 2 - acos(verticalDirection.y)
                let verticalRotation = simd_quatf(angle: verticalAngle, axis: SIMD3<Float>(0, 0, -1))
                
                modelEntity.orientation = horizontalRotation * verticalRotation
                
                
                modelEntity.scale = SIMD3<Float>(scale, scale, scale)
                modelEntity.name = name
                self.points.append(modelEntity)
                self.addChild(modelEntity)
                
            })
        cancellable.store(in: &cancellables)
    }
    
    private func createCheckPoints(center: SIMD3<Float>, count: Int, height: Float, radiusScale: Float) {

        let fullCircle = Float.pi * 2
        let angleIncrement = fullCircle / Float(count)
        
        for i in 0..<count {
            let angle = angleIncrement * Float(i)
//            print("angle = \(angle)")
            
            let x = cos(angle) * radius * radiusScale
            let z = sin(angle) * radius * radiusScale
            let entityPosition = SIMD3<Float>(center.x + x, height, center.z + z)
            
            let direction = center - entityPosition  // face to center
//            let name = "Point\(i)"
            let name = "Point\(index + i)"
            
            print("\(name)'s direction: \(direction)")
            asyncLoadCheckPointEntity(filename: "checkpoint.usdz",
                                      position: entityPosition,
                                      name: name,
                                      direction: direction)
            
            model.checkpoints[i] = .initialized
        }
        index = index + count
    }
}
