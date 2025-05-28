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

// MARK: - Todo Task Model
struct TodoTask: Codable, Identifiable, Equatable {
    let id = UUID()
    var text: String
    var position: SIMD3<Float> = SIMD3<Float>(0, 0.1, -1.0)
    var isCompleted: Bool = false
    
    init(text: String, position: SIMD3<Float> = SIMD3<Float>(0, 0.1, -1.0)) {
        self.text = text
        self.position = position
    }
}

struct ContentView: View {
    @State private var todoTasks: [TodoTask] = []
    @State private var newTaskText = ""
    @State private var showingAddTask = false
    @AppStorage("savedTodos") private var savedTodosData: Data = Data()
    
    var body: some View {
        ZStack {
            ARViewContainer(todoTasks: $todoTasks)
                .ignoresSafeArea()
            
            // Overlay UI
            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        showingAddTask = true
                    }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title)
                            .foregroundColor(.white)
                            .background(Color.blue.opacity(0.8))
                            .clipShape(Circle())
                    }
                    .padding()
                }
                Spacer()
            }
        }
        .onAppear {
            loadTodos()
        }
        .onChange(of: todoTasks) {
            saveTodos()
        }
        .onReceive(NotificationCenter.default.publisher(for: .todoPositionUpdated)) { notification in
            if let updatedTasks = notification.object as? [TodoTask] {
                todoTasks = updatedTasks
            }
        }
        .alert("Add Todo Task", isPresented: $showingAddTask) {
            TextField("Enter task", text: $newTaskText)
            Button("Add") {
                if !newTaskText.isEmpty {
                    let newTask = TodoTask(text: newTaskText)
                    todoTasks.append(newTask)
                    newTaskText = ""
                }
            }
            Button("Cancel", role: .cancel) {
                newTaskText = ""
            }
        }
    }
    
    private func saveTodos() {
        if let encoded = try? JSONEncoder().encode(todoTasks) {
            savedTodosData = encoded
        }
        // Make the tasks appear by posting notification to update AR scene
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .todoTasksUpdated, object: todoTasks)
        }
    }
    
    private func loadTodos() {
        if let decoded = try? JSONDecoder().decode([TodoTask].self, from: savedTodosData) {
            todoTasks = decoded
        }
    }
}

struct ARViewContainer: UIViewRepresentable {
    @Binding var todoTasks: [TodoTask]
    
func makeUIView(context: Context) -> ARView {
    let arView = ARView(frame: .zero)

    // Create hand tracking coordinator
    let coordinator = HandTrackingCoordinator(arView: arView)
    arView.handTrackingCoordinator = coordinator

    // Set up the scene
    setupScene(arView)

    // 🛠 Delay update until anchorEntity is ready
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        coordinator.updateTodoTasks(todoTasks)
    }

    return arView
}
    
func updateUIView(_ uiView: ARView, context: Context) {
    // Only update if the anchor is ready
    if uiView.handTrackingCoordinator?.anchorEntity != nil {
        uiView.handTrackingCoordinator?.updateTodoTasks(todoTasks)
    }
}
    
    private func setupScene(_ arView: ARView) {
        // Create anchor entity
        let anchorEntity = AnchorEntity(world: .zero)
        // Add to scene
        arView.scene.addAnchor(anchorEntity)
        
        // Store reference to anchor for todo tasks
        arView.handTrackingCoordinator?.anchorEntity = anchorEntity
        
        // Add touch gestures
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
    var anchorEntity: AnchorEntity?
    private var todoEntities: [UUID: ModelEntity] = [:]
    private var todoTasks: [TodoTask] = []
    private var isPinching = false
    private var lastPinchPosition: SIMD3<Float>?
    private var selectedEntity: ModelEntity?
    private var selectedTaskId: UUID?
    
    // Vision framework for hand tracking
    private let handPoseRequest = VNDetectHumanHandPoseRequest()
    private let sequenceHandler = VNSequenceRequestHandler()
    
    init(arView: ARView) {
        self.arView = arView
        super.init()
        setupHandTracking()
        setupHandPoseRequest()
    }
    
    func updateTodoTasks(_ tasks: [TodoTask]) {
        // Remove entities for tasks that no longer exist
        let currentTaskIds = Set(tasks.map { $0.id })
        let entitiesToRemove = todoEntities.keys.filter { !currentTaskIds.contains($0) }
        
        for taskId in entitiesToRemove {
            if let entity = todoEntities[taskId] {
                entity.removeFromParent()
                todoEntities.removeValue(forKey: taskId)
            }
        }
        
        // Add or update entities for existing tasks
        for task in tasks {
            if todoEntities[task.id] == nil {
                createTodoEntity(for: task)
            } else {
                updateTodoEntity(for: task)
            }
        }
        
        todoTasks = tasks
    }
    
    private func createTodoEntity(for task: TodoTask) {
        guard let anchorEntity = anchorEntity else { return }
        
        // Create a sphere for the todo task
        let todoEntity = ModelEntity(
            mesh: .generateSphere(radius: 0.07),
            materials: [SimpleMaterial(color: task.isCompleted ? .green : .orange, roughness: 0.15, isMetallic: true)]
        )
        
        todoEntity.position = task.position
        todoEntity.name = "todo_\(task.id.uuidString)"
        
        // Add collision and input components
        todoEntity.collision = CollisionComponent(shapes: [.generateSphere(radius: 0.07)])
        todoEntity.components.set(InputTargetComponent())
        
        // Add text label (simple approach using a colored box above the sphere)
        let labelEntity = ModelEntity(
            mesh: .generateBox(size: [0.15, 0.025, 0.01]),
            materials: [SimpleMaterial(color: .white, isMetallic: false)]
        )
        labelEntity.position = [0, 0.1, 0]
        todoEntity.addChild(labelEntity)
        
        anchorEntity.addChild(todoEntity)
        todoEntities[task.id] = todoEntity
        print("Created todo entity at position: \(task.position)")
    }
    
    private func updateTodoEntity(for task: TodoTask) {
        guard let entity = todoEntities[task.id] else { return }
        
        entity.position = task.position
        entity.model?.materials = [SimpleMaterial(color: task.isCompleted ? .green : .orange, roughness: 0.15, isMetallic: true)]
    }
    
    private func updateTaskPosition(taskId: UUID, position: SIMD3<Float>) {
        if let index = todoTasks.firstIndex(where: { $0.id == taskId }) {
            todoTasks[index].position = position
            // Notify the view to save changes
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .todoPositionUpdated, object: self.todoTasks)
            }
        }
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
    
    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: arView)
        
        if let entity = arView.entity(at: location) as? ModelEntity,
           entity.name.hasPrefix("todo_") {  // Use entity.name directly, no 'let' binding
            
            selectedEntity = entity
            let taskIdString = String(entity.name.dropFirst(5)) // Use entity.name directly
            selectedTaskId = UUID(uuidString: taskIdString)
            
            // Visual feedback for selection
            entity.model?.materials = [SimpleMaterial(color: .blue, roughness: 0.15, isMetallic: true)]
        } else {
            // Deselect
            if let selected = selectedEntity, let taskId = selectedTaskId {
                let task = todoTasks.first { $0.id == taskId }
                let color: UIColor = task?.isCompleted == true ? .green : .orange
                selected.model?.materials = [SimpleMaterial(color: color, roughness: 0.15, isMetallic: true)]
            }
            selectedEntity = nil
            selectedTaskId = nil
        }
    }
    
    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let entity = selectedEntity, let taskId = selectedTaskId else { return }
        
        let translation = gesture.translation(in: arView)
        
        // Convert screen movement to world movement
        let newPosition = entity.position + SIMD3<Float>(
            Float(translation.x * 0.0001),
            0,
            Float(translation.y * 0.0001)
        )
        
        entity.position = newPosition
        updateTaskPosition(taskId: taskId, position: newPosition)
        
        gesture.setTranslation(.zero, in: arView)
    }
    
    // MARK: - Hand Tracking
    private func processHandTracking(_ frame: ARFrame) {
        let pixelBuffer = frame.capturedImage
        
        do {
            try sequenceHandler.perform([handPoseRequest], on: pixelBuffer, orientation: .up)
            
            guard let observation = handPoseRequest.results?.first else {
                if isPinching {
                    isPinching = false
                    resetSelectedEntityColor()
                }
                return
            }
            
            processHandObservation(observation, in: frame)
            
        } catch {
            print("Hand pose detection failed: \(error)")
        }
    }
    
    private func processHandObservation(_ observation: VNHumanHandPoseObservation, in frame: ARFrame) {
        do {
            let thumbTip = try observation.recognizedPoint(.thumbTip)
            let indexTip = try observation.recognizedPoint(.indexTip)
            
            guard thumbTip.confidence > 0.5, indexTip.confidence > 0.5 else {
                if isPinching {
                    isPinching = false
                    resetSelectedEntityColor()
                }
                return
            }
            
            let thumbLocation = thumbTip.location
            let indexLocation = indexTip.location
            let distance = sqrt(pow(thumbLocation.x - indexLocation.x, 2) + pow(thumbLocation.y - indexLocation.y, 2))
            
            let pinchThreshold: CGFloat = 0.05
            
            if distance < pinchThreshold {
                handlePinchGesture(thumbLocation: thumbLocation, indexLocation: indexLocation, frame: frame)
            } else {
                if isPinching {
                    isPinching = false
                    resetSelectedEntityColor()
                    selectedEntity = nil
                    selectedTaskId = nil
                }
                lastPinchPosition = nil
            }
            
        } catch {
            print("Error processing hand observation: \(error)")
        }
    }
    
    private func handlePinchGesture(thumbLocation: CGPoint, indexLocation: CGPoint, frame: ARFrame) {
        let midPoint = CGPoint(
            x: (thumbLocation.x + indexLocation.x) / 2,
            y: 1.0 - (thumbLocation.y + indexLocation.y) / 2
        )
        
        let viewSize = arView.bounds.size
        let screenPoint = CGPoint(
            x: midPoint.x * viewSize.width,
            y: midPoint.y * viewSize.height
        )
        
        if !isPinching {
            // Start pinching - select entity at hand position
            if let entity = arView.entity(at: screenPoint) as? ModelEntity,
                entity.name.hasPrefix("todo_") {
                
                isPinching = true
                selectedEntity = entity
                let taskIdString = String(entity.name.dropFirst(5))
                selectedTaskId = UUID(uuidString: taskIdString)
                
                entity.model?.materials = [SimpleMaterial(color: .blue, roughness: 0.15, isMetallic: true)]
                
                if let raycastResult = arView.raycast(from: screenPoint, allowing: .existingPlaneInfinite, alignment: .horizontal).first {
                    lastPinchPosition = raycastResult.worldTransform.translation
                }
            }
        } else if let entity = selectedEntity, let taskId = selectedTaskId {
            // Continue pinching - move entity
            if let raycastResult = arView.raycast(from: screenPoint, allowing: .existingPlaneInfinite, alignment: .horizontal).first {
                let newPosition = raycastResult.worldTransform.translation
                
                if let lastPos = lastPinchPosition {
                    let movement = newPosition - lastPos
                    let updatedPosition = entity.position + movement
                    entity.position = updatedPosition
                    updateTaskPosition(taskId: taskId, position: updatedPosition)
                }
                
                lastPinchPosition = newPosition
            }
        }
    }
    
    private func resetSelectedEntityColor() {
        if let entity = selectedEntity, let taskId = selectedTaskId {
            let task = todoTasks.first { $0.id == taskId }
            let color: UIColor = task?.isCompleted == true ? .green : .orange
            entity.model?.materials = [SimpleMaterial(color: color, roughness: 0.15, isMetallic: true)]
        }
    }
    
    // MARK: - ARSessionDelegate
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        processHandTracking(frame)
    }
    
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        // Handle new anchors
    }
}

// Notification for position updates
extension Notification.Name {
    static let todoPositionUpdated = Notification.Name("todoPositionUpdated")
    static let todoTasksUpdated = Notification.Name("todoTasksUpdated")
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
