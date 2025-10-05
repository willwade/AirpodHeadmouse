//
//  ContentView.swift
//  AirpodHeadMouse
//
//  Created by AX North on 05/10/2025.
//

import SwiftUI
import CoreMotion
import CoreGraphics
import Combine // ADDED: Required for @Published properties and ObservableObject conformance
import AppKit // ADDED: Required for NSScreen access

// MARK: - Motion Manager
// This class handles the connection to the AirPods and translates motion data into cursor commands.
class HeadMouseManager: NSObject, ObservableObject, CMHeadphoneMotionManagerDelegate {
    
    // Published properties for UI updates
    @Published var motionData: CMDeviceMotion?
    @Published var status: String = "Initializing..."
    @Published var isRunning: Bool = false
    
    // Core Motion properties
    private let manager = CMHeadphoneMotionManager()
    private var referenceAttitude: CMAttitude? // Stores the head orientation when calibrated
    
    // Control constants
    private let sensitivity: Double = 300.0 // Multiplier for motion-to-cursor speed
    
    override init() {
        super.init()
        manager.delegate = self
        // Check for device motion availability immediately
        checkAvailability()
    }
    
    private func checkAvailability() {
        if manager.isDeviceMotionAvailable {
            status = "Ready. Tap 'Start Tracking'."
        } else {
            status = "Error: Headphone motion not available."
        }
    }
    
    // MARK: - Public Control Methods
    
    /// Starts the motion tracking updates from the connected headphones.
    func startTracking() {
        guard manager.isDeviceMotionAvailable else {
            status = "Motion unavailable."
            return
        }
        
        // Use a continuous update handler on the main queue
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self = self else { return }
            
            if let error = error {
                self.status = "Error: \(error.localizedDescription)"
                self.stopTracking()
                return
            }
            
            guard let motion = motion else { return }
            
            // Update UI data
            self.motionData = motion
            self.status = self.isRunning ? "Tracking Active" : "Tracking Paused"
            
            // If tracking is active and we have a reference, move the mouse
            if self.isRunning, let reference = self.referenceAttitude {
                self.moveCursor(currentMotion: motion, reference: reference)
            }
        }
        self.isRunning = true
        // Set the initial reference point when starting
        self.calibrate()
    }
    
    /// Stops the motion tracking.
    func stopTracking() {
        manager.stopDeviceMotionUpdates()
        isRunning = false
        status = "Tracking Stopped."
    }
    
    /// Sets the current head attitude as the neutral (zero) reference point.
    func calibrate() {
        guard let currentMotion = motionData else {
            status = "Waiting for initial motion data to calibrate..."
            return
        }
        referenceAttitude = currentMotion.attitude
        status = "Calibrated. Tracking Head Mouse..."
    }
    
    // MARK: - CMHeadphoneMotionManagerDelegate
    
    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        status = "Headphones Connected. Ready."
        if !isRunning {
            // Automatically start tracking upon connection
            startTracking()
        }
    }
    
    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        status = "Headphones Disconnected. Stop Tracking."
        stopTracking()
        referenceAttitude = nil
    }
    
    // MARK: - Cursor Control Logic
    
    private func moveCursor(currentMotion: CMDeviceMotion, reference: CMAttitude) {
        
        // The previous lines that caused errors related to attitude difference have been removed.
        // The rotation rate (angular velocity) provides continuous movement feedback,
        // which is ideal for a mouse emulator.
        
        // Calculate the movement delta (rate of change * sensitivity)
        // Yaw (rotationRate.y) maps to horizontal (X-axis) movement
        let dx = currentMotion.rotationRate.y * sensitivity
        
        // Pitch (rotationRate.x) maps to vertical (Y-axis) movement. Invert Y for natural scroll direction.
        let dy = currentMotion.rotationRate.x * sensitivity * -1.0

        // Get the current cursor position (Fixed: event is optional, location is not)
        guard let event = CGEvent(source: nil) else { return }
        let currentMouseLocation = event.location
        
        // Calculate the new position
        var newX = currentMouseLocation.x + CGFloat(dx)
        var newY = currentMouseLocation.y + CGFloat(dy)
        
        // Clamp the position to the screen boundaries
        if let screen = NSScreen.main {
            let frame = screen.frame
            newX = min(max(newX, frame.minX), frame.maxX)
            newY = min(max(newY, frame.minY), frame.maxY)
        }
        
        // Warp the mouse cursor position
        CGWarpMouseCursorPosition(CGPoint(x: newX, y: newY))
    }
}

// MARK: - SwiftUI View
struct ContentView: View {
    @StateObject private var motionManager = HeadMouseManager()
    
    var body: some View {
        VStack(spacing: 16) {
            Text("AirPods Head Mouse")
                .font(.largeTitle.bold())
                .foregroundColor(.accentColor)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Status:")
                    .font(.headline)
                Text(motionManager.status)
                    .font(.body)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(motionManager.isRunning ? Color.green.opacity(0.1) : Color.gray.opacity(0.1))
                    )
            }
            .padding(.horizontal)
            
            // Live Motion Data Display
            if let motion = motionManager.motionData {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Live Rotation Rate (rad/s):")
                        .font(.headline)
                    Group {
                        Text("Pitch (X-axis): \(motion.rotationRate.x, specifier: "%.3f")")
                        Text("Yaw (Y-axis): \(motion.rotationRate.y, specifier: "%.3f")")
                        Text("Roll (Z-axis): \(motion.rotationRate.z, specifier: "%.3f")")
                    }
                    .font(.system(.body, design: .monospaced))
                    .padding(.leading)
                }
                .padding()
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(10)
            }
            
            HStack(spacing: 15) {
                // Start/Stop Button
                Button {
                    motionManager.isRunning ? motionManager.stopTracking() : motionManager.startTracking()
                } label: {
                    Text(motionManager.isRunning ? "Stop Head Mouse" : "Start Head Mouse")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(motionManager.isRunning ? .cancelAction : .defaultAction)
                .controlSize(.large)
                .tint(motionManager.isRunning ? .red : .accentColor)
                
                // Calibrate Button
                Button {
                    motionManager.calibrate()
                } label: {
                    Text("Calibrate")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut("r", modifiers: .command) // Command+R to re-calibrate
                .controlSize(.large)
                .tint(.blue)
                .disabled(!motionManager.isRunning)
            }
            .padding([.top, .horizontal])
            
            Text("Tip: Calibrate when looking straight ahead. Head rotation speed determines cursor speed.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)
        }
        .padding()
        .frame(minWidth: 400, minHeight: 450)
    }
}

// MARK: - App Entry Point
@main
struct HeadMouseApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
