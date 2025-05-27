//
//  ContentView.swift
//  firstArProject
//
//  Created by Armaan Zeyad on 28/05/25.
//

import SwiftUI
import RealityKit

struct ContentView : View {

    var body: some View {
        RealityView { content in

            // Create a cube model
            let model = Entity()
            let mesh = MeshResource.generateBox(size: 0.1, cornerRadius: 0.005)
            let material = SimpleMaterial(color: .gray, roughness: 0.15, isMetallic: true)
            model.components.set(ModelComponent(mesh: mesh, materials: [material]))
            model.position = [0, 0.05, 0]
            
            // Add collision and input components to make cube movable
            model.components.set(CollisionComponent(shapes: [.generateBox(size: [0.1, 0.1, 0.1])]))
            model.components.set(InputTargetComponent())

            // Create horizontal plane anchor for the content
            let anchor = AnchorEntity(.plane(.horizontal, classification: .any, minimumBounds: SIMD2<Float>(0.2, 0.2)))
            anchor.addChild(model)

            // Add the horizontal plane anchor to the scene
            content.add(anchor)

            // Configure camera properly for AR
            content.camera = .spatialTracking
        }
        .gesture(
            DragGesture()
                .targetedToAnyEntity()
                .onChanged { value in
                    value.entity.position = value.entity.position + SIMD3<Float>(
                        Float(value.translation.width * 0.0001),
                        0,
                        Float(value.translation.height * 0.0001)
                    )
                }
        )
        .ignoresSafeArea()
    }

}

#Preview {
    ContentView()
}
