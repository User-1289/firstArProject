//
//  ContentView.swift
//  firstArProject
//
//  Created by Armaan Zeyad on 28/05/25.
//

import SwiftUI
import RealityKit
import ARKit
import Vision

struct ContentView: View {
    var body: some View {
        ARViewContainer()
            .ignoresSafeArea()
    }
}

struct ARViewContainer: UIViewRepresentable {
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        
        // Create hand tracking coordinator
        let coordinator = HandTrackingCoordinator(arView: arView)
        arView.handTrackingCoordinator = coordinator
        
        // Set up the scene
        setupScene(arView)
        
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {
        // Updates can be handled here if needed
    }
    
    private func setupScene(_ arView: ARView) {
        // Create a cube model
        let cubeEntity = ModelEntity(
            mesh: .generateBox(size: 0.1, cornerRadius: 0.005),
            materials: [SimpleMaterial(color: .gray, roughness: 0.15, isMetallic: true)]
        )
        cubeEntity.position = [0, 0.05, 0]
        cubeEntity.name = "cube"
        
        // Add collision and input components
        cubeEntity.collision = CollisionComponent(shapes: [.generateBox(size: [0.1, 0.1, 0.1])])
        cubeEntity.components.set(InputTargetComponent())
        
        // Create anchor entity
        let anchorEntity = AnchorEntity(.plane(.horizontal, classification: .any, minimumBounds: [0.2, 0.2]))
        anchorEntity.addChild(cubeEntity)
        
        // Add to scene
        arView.scene.addAnchor(anchorEntity)
        
        // Store reference to cube for hand tracking
        arView.handTrackingCoordinator?.cubeEntity = cubeEntity
        
        // Add touch gesture (your original feature)
        arView.addGestureRecognizer(
            UITapGestureRecognizer(target: arView.handTrackingCoordinator!, action: #selector(HandTrackingCoordinator.handleTap(_:)))
        )
        
        let panGesture = UIPanGestureRecognizer(target: arView.handTrackingCoordinator!, action: #selector(HandTrackingCoordinator.handlePan(_:)))
        arView.addGestureRecognizer(panGesture)
    }
}

// Extension to store coordinator reference
extension ARView {
    private struct AssociatedKeys {
        static var handTrackingCoordinator = "handTrackingCoordinator"
    }
    
    var handTrackingCoordinator: HandTrackingCoordinator? {
        get {
            return objc_getAssociatedObject(self, &AssociatedKeys.handTrackingCoordinator) as? HandTrackingCoordinator
        }
        set {
            objc_setAssociatedObject(self, &AssociatedKeys.handTrackingCoordinator, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

class HandTrackingCoordinator: NSObject, ARSessionDelegate {
    private let arView: ARView
    var cubeEntity: ModelEntity?
    private var isPinching = false
    private var lastPinchPosition: SIMD3<Float>?
    private var selectedEntity: ModelEntity?
    
    // Vision framework for hand tracking
    private let handPoseRequest = VNDetectHumanHandPoseRequest()
    private let sequenceHandler = VNSequenceRequestHandler()
    
    init(arView: ARView) {
        self.arView = arView
        super.init()
        setupHandTracking()
        setupHandPoseRequest()
    }
    
    private func setupHandPoseRequest() {
        handPoseRequest.maximumHandCount = 1
        handPoseRequest.revision = VNDetectHumanHandPoseRequestRevision1
    }
    
    private func setupHandTracking() {
        // Configure AR session for world tracking
        let configuration = ARWorldTrackingConfiguration()
        
        // Enable plane detection
        configuration.planeDetection = [.horizontal]
        
        // Enable people occlusion if available (iOS 13+)
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentation) {
            configuration.frameSemantics.insert(.personSegmentation)
        }
        
        arView.session.delegate = self
        arView.session.run(configuration)
        
        print("AR session configured and running")
    }
    
    private func requestHandTrackingAuthorization() {
        // Check if AR World Tracking is supported
        guard ARWorldTrackingConfiguration.isSupported else {
            print("AR World Tracking not supported on this device")
            return
        }
        
        // AR permissions are handled automatically when session runs
        print("AR session will request camera permission when needed")
    }
    
    // MARK: - Touch Gestures (Original Feature)
    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: arView)
        
        if let entity = arView.entity(at: location) as? ModelEntity {
            selectedEntity = entity
            // Visual feedback for selection
            entity.model?.materials = [SimpleMaterial(color: .blue, roughness: 0.15, isMetallic: true)]
        } else {
            selectedEntity?.model?.materials = [SimpleMaterial(color: .gray, roughness: 0.15, isMetallic: true)]
            selectedEntity = nil
        }
    }
    
    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let entity = selectedEntity else { return }
        
        let translation = gesture.translation(in: arView)
        
        // Convert screen movement to world movement
        entity.position += SIMD3<Float>(
            Float(translation.x * 0.0001),
            0,
            Float(translation.y * 0.0001)
        )
        
        gesture.setTranslation(.zero, in: arView)
    }
    
    // MARK: - Hand Tracking (New Feature)
    private func processHandTracking(_ frame: ARFrame) {
        // Convert ARFrame to CVPixelBuffer for Vision
        let pixelBuffer = frame.capturedImage
        
        // Perform hand pose detection
        do {
            try sequenceHandler.perform([handPoseRequest], on: pixelBuffer, orientation: .up)
            
            guard let observation = handPoseRequest.results?.first else {
                // No hand detected
                if isPinching {
                    isPinching = false
                    resetCubeColor()
                }
                return
            }
            
            // Process the hand observation
            processHandObservation(observation, in: frame)
            
        } catch {
            print("Hand pose detection failed: \(error)")
        }
    }
    
    private func processHandObservation(_ observation: VNHumanHandPoseObservation, in frame: ARFrame) {
        guard let cubeEntity = cubeEntity else { return }
        
        do {
            // Get thumb tip and index finger tip points
            let allPoints = try observation.recognizedPoints(.all)
            let thumbTip = try observation.recognizedPoint(.thumbTip)
            let indexTip = try observation.recognizedPoint(.indexTip)
            // Use the correct joint names - these are the actual available joints in Vision framework
            guard thumbTip.confidence > 0.5, indexTip.confidence > 0.5 else {
                if isPinching {
                    isPinching = false
                    resetCubeColor()
                }
                return
            }
            
            // Calculate distance between thumb and index finger (in normalized coordinates)
            let thumbLocation = thumbTip.location
            let indexLocation = indexTip.location
            let distance = sqrt(pow(thumbLocation.x - indexLocation.x, 2) + pow(thumbLocation.y - indexLocation.y, 2))
            
            // Pinch threshold (adjust as needed)
            let pinchThreshold: CGFloat = 0.05
            
            if distance < pinchThreshold {
                // Pinching detected
                if !isPinching {
                    isPinching = true
                    setCubeSelectedColor()
                    
                    // Convert screen point to world position
                    let midPoint = CGPoint(
                        x: (thumbLocation.x + indexLocation.x) / 2,
                        y: 1.0 - (thumbLocation.y + indexLocation.y) / 2 // Flip Y coordinate
                    )
                    
                    // Convert to view coordinates
                    let viewSize = arView.bounds.size
                    let screenPoint = CGPoint(
                        x: midPoint.x * viewSize.width,
                        y: midPoint.y * viewSize.height
                    )
                    
                    // Raycast from camera through hand position
                    if let raycastResult = arView.raycast(from: screenPoint, allowing: .existingPlaneInfinite, alignment: .horizontal).first {
                        lastPinchPosition = raycastResult.worldTransform.translation
                    }
                } else {
                    // Continue pinching - move cube
                    let midPoint = CGPoint(
                        x: (thumbLocation.x + indexLocation.x) / 2,
                        y: 1.0 - (thumbLocation.y + indexLocation.y) / 2
                    )
                    
                    let viewSize = arView.bounds.size
                    let screenPoint = CGPoint(
                        x: midPoint.x * viewSize.width,
                        y: midPoint.y * viewSize.height
                    )
                    
                    if let raycastResult = arView.raycast(from: screenPoint, allowing: .existingPlaneInfinite, alignment: .horizontal).first {
                        let newPosition = raycastResult.worldTransform.translation
                        
                        if let lastPos = lastPinchPosition {
                            let movement = newPosition - lastPos
                            cubeEntity.position += movement
                        }
                        
                        lastPinchPosition = newPosition
                    }
                }
            } else {
                // Not pinching
                if isPinching {
                    isPinching = false
                    resetCubeColor()
                }
                lastPinchPosition = nil
            }
            
        } catch {
            print("Error processing hand observation: \(error)")
        }
    }
    
    private func setCubeSelectedColor() {
        cubeEntity?.model?.materials = [SimpleMaterial(color: .green, roughness: 0.15, isMetallic: true)]
    }
    
    private func resetCubeColor() {
        cubeEntity?.model?.materials = [SimpleMaterial(color: .gray, roughness: 0.15, isMetallic: true)]
    }
    
    private func detectPinchGesture(in frame: ARFrame) {
        // This method is replaced by processHandObservation above
    }
    
    // MARK: - ARSessionDelegate
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Process hand tracking on each frame
        processHandTracking(frame)
    }
    
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        // Handle new anchors
    }
}

// Extension to get translation from matrix
extension simd_float4x4 {
    var translation: SIMD3<Float> {
        return SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }
}

#Preview {
    ContentView()
}
