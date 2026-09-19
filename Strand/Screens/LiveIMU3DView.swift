import SwiftUI
import SceneKit
import simd

#if os(iOS)
private typealias IMUSceneColor = UIColor
#else
private typealias IMUSceneColor = NSColor
#endif

struct LiveIMU3DView: View {
    let model: LiveIMUVisualizationModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var live: LiveState
    @StateObject private var scene = LiveIMUScene()
    @State private var showAcceleration = true
    @State private var showGyroscope = true

    var body: some View {
        NavigationStack {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: scenePhase != .active)) { context in
                let sample = model.presentation(at: context.date)
                let fresh = live.connected && sample.map { context.date.timeIntervalSince($0.receivedAt) < 5 } == true
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Label(fresh ? "Live IMU" : "Waiting for live IMU", systemImage: fresh ? "dot.radiowaves.left.and.right" : "pause.circle")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(fresh ? .green : .secondary)
                            Spacer()
                            Button("Zero rotation") { model.zeroRotation(at: context.date) }
                                .buttonStyle(.bordered).disabled(sample == nil)
                        }
                        IMUSceneSurface(scene: scene, sample: sample,
                            showAcceleration: showAcceleration, showGyroscope: showGyroscope)
                            .frame(height: 340)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .accessibilityLabel("3D sensor orientation with acceleration and angular velocity arrows. Numeric equivalents below.")
                        Text("Drag to orbit · pinch to zoom · X red / Y green / Z blue")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Toggle("Acceleration", isOn: $showAcceleration).tint(.cyan)
                            Toggle("Rotation rate", isOn: $showGyroscope).tint(.orange)
                        }
                        .font(.caption)
                        if let sample {
                            Text("100 Hz samples · 30 fps view · sample age \(max(0, context.date.timeIntervalSince1970 - sample.pose.sensorTimestamp), specifier: "%.1f")s")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            if !fresh {
                                Text("Last received \(max(0, Int(context.date.timeIntervalSince(sample.receivedAt))))s ago. Holding the last sample.")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            vectorCard("Relative rotation", values: sample.eulerDegrees,
                                labels: ["Roll", "Pitch", "Yaw"], unit: "°", color: .primary)
                            vectorCard("Acceleration · includes gravity", values: sample.pose.acceleration,
                                unit: "g", color: .cyan)
                            vectorCard("Gyroscope · rotation rate", values: sample.pose.angularVelocity,
                                unit: "°/s", color: .orange)
                            vectorCard("Linear acceleration · estimate", values: sample.pose.linearAcceleration,
                                unit: "g", color: .secondary)
                        } else {
                            Text("Move your WHOOP while live IMU collection is enabled. Only fresh Bluetooth IMU packets drive this view; backfill is excluded.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text("Rotation is estimated from the gyroscope with gravity correction. Yaw has no compass reference and may drift. Zero rotation sets a new relative reference. Sensor axes are shown, not anatomical wrist angles; position is not tracked.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("The strap sends one-second packets, played at sample cadence here. Arrows show direction and scaled magnitude; long arrows are capped to fit the scene.")
                            .font(.caption).foregroundStyle(.secondary)
                        if model.gapResets > 0 {
                            Text("Orientation restarted after \(model.gapResets) data gap(s).")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("IMU in 3D")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear { model.activate() }
        .onDisappear { model.deactivate() }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 740)
        #endif
    }

    private func vectorCard(_ title: String, values: SIMD3<Float>, labels: [String] = ["X", "Y", "Z"],
                            unit: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(color)
            HStack {
                ForEach(0..<3) { index in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(labels[index]).font(.caption).foregroundStyle(.secondary)
                        Text("\(values[index], specifier: "%.2f") \(unit)")
                            .font(.system(.body, design: .monospaced)).minimumScaleFactor(0.7).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

@MainActor
final class LiveIMUScene: ObservableObject {
    let scene = SCNScene()
    let camera = SCNNode()
    private let sensor = SCNNode()
    private let acceleration: SCNNode
    private let gyro: SCNNode

    init() {
        acceleration = Self.arrow(color: .cyan, radius: 0.025)
        gyro = Self.arrow(color: .orange, radius: 0.025)
        scene.background.contents = IMUSceneColor(white: 0.045, alpha: 1)
        camera.camera = SCNCamera()
        camera.camera?.zNear = 0.01
        camera.camera?.zFar = 100
        camera.camera?.fieldOfView = 50
        camera.position = SCNVector3(3.0, -4.5, 2.8)
        camera.look(at: SCNVector3Zero, up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
        scene.rootNode.addChildNode(camera)
        let ambient = SCNNode()
        ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 450
        scene.rootNode.addChildNode(ambient)
        let key = SCNNode()
        key.light = SCNLight(); key.light?.type = .omni; key.light?.intensity = 1100
        key.position = SCNVector3(2, -3, 5)
        scene.rootNode.addChildNode(key)

        let body = SCNBox(width: 1.0, height: 1.6, length: 0.28, chamferRadius: 0.12)
        body.firstMaterial?.diffuse.contents = IMUSceneColor(white: 0.28, alpha: 1)
        body.firstMaterial?.lightingModel = .physicallyBased
        body.firstMaterial?.metalness.contents = 0.5
        body.firstMaterial?.roughness.contents = 0.35
        sensor.addChildNode(SCNNode(geometry: body))
        // A contrasting face makes front/back and rotation visually distinguishable.
        let face = SCNNode(geometry: SCNBox(width: 0.76, height: 1.14, length: 0.02, chamferRadius: 0.06))
        face.geometry?.firstMaterial?.diffuse.contents = IMUSceneColor(white: 0.06, alpha: 1)
        face.position.z = 0.15
        sensor.addChildNode(face)
        let axes: [(SIMD3<Float>, IMUSceneColor, String)] = [
            (SIMD3(1, 0, 0), .systemRed, "X"), (SIMD3(0, 1, 0), .systemGreen, "Y"),
            (SIMD3(0, 0, 1), .systemBlue, "Z")]
        for (direction, color, name) in axes {
            let axis = Self.arrow(color: color, radius: 0.009)
            Self.point(axis, along: direction, gain: 1.15)
            sensor.addChildNode(axis)
            let text = SCNText(string: name, extrusionDepth: 0)
            text.font = .systemFont(ofSize: 18, weight: .bold)
            text.firstMaterial?.diffuse.contents = color
            text.firstMaterial?.lightingModel = .constant
            let label = SCNNode(geometry: text)
            let bounds = text.boundingBox
            label.pivot = SCNMatrix4MakeTranslation((bounds.min.x + bounds.max.x) / 2,
                (bounds.min.y + bounds.max.y) / 2, 0)
            label.simdScale = SIMD3(repeating: 0.01)
            label.simdPosition = direction * 1.28
            label.constraints = [SCNBillboardConstraint()]
            sensor.addChildNode(label)
        }
        sensor.addChildNode(acceleration); sensor.addChildNode(gyro)
        sensor.isHidden = true
        scene.rootNode.addChildNode(sensor)
        var grid: [SCNVector3] = []
        for i in -5...5 {
            let v = Float(i) * 0.5
            grid += [SCNVector3(v, -2.5, -1), SCNVector3(v, 2.5, -1),
                     SCNVector3(-2.5, v, -1), SCNVector3(2.5, v, -1)]
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: grid)],
            elements: [SCNGeometryElement(indices: grid.indices.map(Int32.init), primitiveType: .line)])
        geometry.firstMaterial?.diffuse.contents = IMUSceneColor(white: 0.22, alpha: 1)
        geometry.firstMaterial?.lightingModel = .constant
        scene.rootNode.addChildNode(SCNNode(geometry: geometry))
    }

    func makeView() -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = scene; view.pointOfView = camera
        view.allowsCameraControl = true
        view.cameraControlConfiguration.allowsTranslation = false
        view.defaultCameraController.worldUp = SCNVector3(0, 0, 1)
        view.defaultCameraController.target = SCNVector3Zero
        view.preferredFramesPerSecond = 30
        view.antialiasingMode = .multisampling4X
        return view
    }

    func update(_ sample: LiveIMUVisualizationModel.Presentation?, acceleration showAcceleration: Bool, gyro showGyro: Bool) {
        sensor.isHidden = sample == nil
        guard let sample else { return }
        SCNTransaction.begin(); SCNTransaction.animationDuration = 0
        sensor.simdOrientation = sample.relativeOrientation
        Self.point(acceleration, along: sample.pose.acceleration, gain: 1.5)
        Self.point(gyro, along: sample.pose.angularVelocity, gain: 0.01)
        acceleration.isHidden = !showAcceleration || simd_length(sample.pose.acceleration) < 0.001
        gyro.isHidden = !showGyro || simd_length(sample.pose.angularVelocity) < 0.1
        SCNTransaction.commit()
    }

    private static func arrow(color: IMUSceneColor, radius: CGFloat) -> SCNNode {
        let root = SCNNode()
        let shaft = SCNNode(geometry: SCNCylinder(radius: radius, height: 0.84))
        shaft.position.y = 0.42
        let tip = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: radius * 3, height: 0.16))
        tip.position.y = 0.92
        for node in [shaft, tip] {
            node.geometry?.firstMaterial?.diffuse.contents = color
            node.geometry?.firstMaterial?.lightingModel = .constant
            root.addChildNode(node)
        }
        return root
    }

    private static func point(_ arrow: SCNNode, along vector: SIMD3<Float>, gain: Float) {
        let magnitude = simd_length(vector)
        guard magnitude > 0.000001 else { arrow.isHidden = true; return }
        arrow.isHidden = false
        arrow.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: vector / magnitude)
        arrow.simdScale = SIMD3(1, min(2.5, magnitude * gain), 1)
    }
}

#if os(iOS)
private struct IMUSceneSurface: UIViewRepresentable {
    let scene: LiveIMUScene
    let sample: LiveIMUVisualizationModel.Presentation?
    let showAcceleration: Bool
    let showGyroscope: Bool
    func makeUIView(context: Context) -> SCNView { scene.makeView() }
    func updateUIView(_ view: SCNView, context: Context) {
        scene.update(sample, acceleration: showAcceleration, gyro: showGyroscope)
    }
}
#else
private struct IMUSceneSurface: NSViewRepresentable {
    let scene: LiveIMUScene
    let sample: LiveIMUVisualizationModel.Presentation?
    let showAcceleration: Bool
    let showGyroscope: Bool
    func makeNSView(context: Context) -> SCNView { scene.makeView() }
    func updateNSView(_ view: SCNView, context: Context) {
        scene.update(sample, acceleration: showAcceleration, gyro: showGyroscope)
    }
}
#endif
