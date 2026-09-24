import XCTest
import simd
import WhoopProtocol
import SceneKit
@testable import Strand

@MainActor
final class LiveIMUVisualizationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_002)
    private func frame(ts: Int = 1_800_000_000, accel: SIMD3<Double> = SIMD3(0, 0, 1),
                       gyro: SIMD3<Double> = .zero) -> Whoop5ImuFrame {
        let sample = RawImuSample(ax: accel.x, ay: accel.y, az: accel.z,
                                 gx: gyro.x, gy: gyro.y, gz: gyro.z)
        return Whoop5ImuFrame(baseTs: ts, sampleRateHz: 100, samples: Array(repeating: sample, count: 100))
    }

    func testStaticTiltHasZeroLinearAccelerationAndRelativeRotation() throws {
        let model = LiveIMUVisualizationModel()
        model.activate(at: now)
        let gravity = SIMD3<Double>(0, sin(.pi / 4), cos(.pi / 4))
        model.receive(frame(accel: gravity), at: now)
        let displayed = try XCTUnwrap(model.presentation(at: now.addingTimeInterval(0.99)))
        XCTAssertLessThan(simd_length(displayed.pose.linearAcceleration), 0.0001)
        XCTAssertLessThan(simd_length(displayed.eulerDegrees), 0.001)
        XCTAssertEqual(model.samplesProcessed, 100)
    }

    func testKnownYawIntegratesAllSamplesAndZeroSetsCurrentReference() throws {
        let model = LiveIMUVisualizationModel()
        model.activate(at: now)
        model.receive(frame(gyro: SIMD3(0, 0, 90)), at: now)
        let displayed = try XCTUnwrap(model.presentation(at: now.addingTimeInterval(1)))
        // t=0 establishes attitude; 99 subsequent 10-ms intervals at 90 degrees/second.
        XCTAssertEqual(displayed.eulerDegrees.z, 89.1, accuracy: 0.02)
        XCTAssertEqual(displayed.pose.angularVelocity.z, 90)
        model.zeroRotation(at: now.addingTimeInterval(1))
        XCTAssertLessThan(simd_length(try XCTUnwrap(model.presentation(at: now.addingTimeInterval(1))).eulerDegrees), 0.001)
    }

    func testPacketPlaybackUsesSensorCadenceAndHoldsOnSilence() throws {
        let model = LiveIMUVisualizationModel()
        model.activate(at: now)
        model.receive(frame(gyro: SIMD3(0, 0, 90)), at: now)
        let halfway = try XCTUnwrap(model.presentation(at: now.addingTimeInterval(0.5)))
        XCTAssertEqual(halfway.pose.sensorTimestamp, 1_800_000_000.5, accuracy: 0.0001)
        XCTAssertEqual(halfway.eulerDegrees.z, 45, accuracy: 0.02)
        let end = try XCTUnwrap(model.presentation(at: now.addingTimeInterval(1)))
        let silent = try XCTUnwrap(model.presentation(at: now.addingTimeInterval(30)))
        XCTAssertEqual(end.pose.sensorTimestamp, silent.pose.sensorTimestamp)
        XCTAssertEqual(end.eulerDegrees.z, silent.eulerDegrees.z)
    }

    func testDuplicatesAndReorderedPacketsDoNotRotateTwiceOrRefreshReceipt() {
        let model = LiveIMUVisualizationModel()
        model.activate(at: now)
        model.receive(frame(), at: now)
        model.receive(frame(gyro: SIMD3(0, 0, 180)), at: now.addingTimeInterval(1))
        model.receive(frame(ts: 1_799_999_999), at: now.addingTimeInterval(2))
        XCTAssertEqual(model.samplesProcessed, 100)
        XCTAssertEqual(model.lastReceivedAt, now)
    }

    func testGapStartsNewOrientationSegmentWithoutIntegratingMissingTime() throws {
        let model = LiveIMUVisualizationModel()
        model.activate(at: now)
        model.receive(frame(gyro: SIMD3(0, 0, 90)), at: now)
        model.receive(frame(ts: 1_800_000_010), at: now.addingTimeInterval(10))
        XCTAssertEqual(model.gapResets, 1)
        XCTAssertLessThan(simd_length(try XCTUnwrap(model.presentation(at: now.addingTimeInterval(11))).eulerDegrees), 0.001)
        model.reset()
        XCTAssertNil(model.presentation(at: now.addingTimeInterval(11)))
    }

    func testOnlyIntegratesWhileViewerIsOpenAndRejectsStaleCache() {
        let model = LiveIMUVisualizationModel()
        model.receive(frame(), at: now)
        XCTAssertEqual(model.samplesProcessed, 0)
        model.activate(at: now.addingTimeInterval(1))
        XCTAssertEqual(model.samplesProcessed, 100)
        model.deactivate()
        model.activate(at: now.addingTimeInterval(10))
        XCTAssertNil(model.presentation(at: now.addingTimeInterval(10)))
    }

    func testAccelerationDuringMotionIsNotTreatedAsPureGravity() throws {
        let model = LiveIMUVisualizationModel()
        model.activate(at: now)
        model.receive(frame(accel: SIMD3(2, 0, 1)), at: now)
        let sample = try XCTUnwrap(model.presentation(at: now.addingTimeInterval(1)))
        XCTAssertEqual(sample.pose.linearAcceleration.x, 2, accuracy: 0.0001)
        XCTAssertEqual(sample.pose.linearAcceleration.z, 0, accuracy: 0.0001)
        XCTAssertLessThan(simd_length(sample.eulerDegrees), 0.001)
    }

    #if os(macOS)
    func testSceneRendersSyntheticMotion() throws {
        let model = LiveIMUVisualizationModel()
        model.activate(at: now)
        model.receive(frame(gyro: SIMD3(25, 40, 65)), at: now)
        let scene = LiveIMUScene()
        scene.update(try XCTUnwrap(model.presentation(at: now.addingTimeInterval(0.6))), acceleration: true, gyro: true)
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scene.scene; renderer.pointOfView = scene.camera
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 1000, height: 700), antialiasingMode: .multisampling4X)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1000)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("noop-imu-3d-preview.png")
        try png.write(to: output)
        print("IMU_SCENE_PREVIEW=\(output.path)")
    }
    #endif
}
