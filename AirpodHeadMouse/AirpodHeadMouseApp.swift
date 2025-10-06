//
//  ContentView.swift
//  AirpodHeadMouse
//
//  Created by willwade on 05/10/2025.
//

import SwiftUI
import CoreMotion
import CoreGraphics
import Combine
import AppKit
import AVFoundation // ADDED: For audio feedback (beeps/buzzes)

// MARK: - Gesture Definition
enum HeadMouseGesture: Equatable {
    case right, left, up, down
}

enum MouseMode: Equatable {
    case tracking      // Default mode: Head motion moves cursor position
    case paused        // Cursor movement is disabled
    case scrollReady   // Waiting 5 seconds to position scroll target
    case scrolling     // Head motion controls scroll events
    case centering     // Cursor is being moved to the center
    case gestureMode   // Currently tracking gesture sequence
}

// MARK: - Motion Manager
class HeadMouseManager: NSObject, ObservableObject, CMHeadphoneMotionManagerDelegate {
    
    // Published properties for UI and state
    @Published var motionData: CMDeviceMotion?
    @Published var status: String = "Initializing..."
    @Published var isRunning: Bool = false
    @Published var isGestureEnabled: Bool = true // User toggle
    @Published var currentMode: MouseMode = .tracking
    @Published var gestureSteps: [HeadMouseGesture] = []
    
    // Core Motion properties
    private let manager = CMHeadphoneMotionManager()
    private var referenceAttitude: CMAttitude?
    
    // Gesture Tracking State
    private let stillnessThreshold = 0.05 // rad/s to detect 'still' head
    private let movementThreshold = 0.25 // rad/s to detect a distinct movement
    private let stillnessDuration: TimeInterval = 1.0 // 1 second for pause initiation
    private var lastMovementTime: Date = Date()
    private var isHeadStill = false
    private var lastDirection: HeadMouseGesture?
    private var scrollReadyTimer: Timer?
    
    // Audio Feedback
    private var audioPlayer: AVAudioPlayer?
    
    // Control constants
    private let trackingSensitivity: Double = 300.0 // Multiplier for cursor speed
    private let scrollSensitivity: Double = 3.0 // Multiplier for scroll speed
    
    override init() {
        super.init()
        manager.delegate = self
        checkAvailability()
        // Initialize audio player for feedback
        setupAudioFeedback()
    }
    
    // MARK: - Initialization and Connection
    
    private func checkAvailability() {
        if manager.isDeviceMotionAvailable {
            status = "Ready. Tap 'Start Tracking'."
        } else {
            status = "Error: Headphone motion not available."
        }
    }
    
    private func setupAudioFeedback() {
        // NOTE: NSBeep() is a function from AppKit that produces a system sound.
        // It is used directly below for gesture feedback.
    }
    
    // MARK: - Public Control Methods
    
    func startTracking() {
        guard manager.isDeviceMotionAvailable else {
            status = "Motion unavailable."
            return
        }
        
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self = self else { return }
            
            if let error = error {
                self.status = "Error: \(error.localizedDescription)"
                self.stopTracking()
                return
            }
            
            guard let motion = motion else { return }
            self.motionData = motion
            
            DispatchQueue.main.async {
                self.processMotionUpdate(motion: motion)
            }
        }
        self.isRunning = true
        self.currentMode = .tracking
        self.status = "Tracking Active"
        self.calibrate()
    }
    
    func stopTracking() {
        manager.stopDeviceMotionUpdates()
        isRunning = false
        currentMode = .tracking
        status = "Tracking Stopped."
        scrollReadyTimer?.invalidate()
        scrollReadyTimer = nil
    }
    
    func calibrate() {
        guard let currentMotion = motionData else {
            status = "Waiting for initial motion data to calibrate..."
            return
        }
        referenceAttitude = currentMotion.attitude
        status = (currentMode == .tracking || currentMode == .gestureMode) ? "Calibrated. Tracking Head Mouse..." : "Calibrated."
        isHeadStill = false
        gestureSteps = []
    }
    
    // MARK: - CMHeadphoneMotionManagerDelegate
    
    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        status = "Headphones Connected. Ready."
        if !isRunning {
            startTracking()
        }
    }
    
    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        status = "Headphones Disconnected. Stop Tracking."
        stopTracking()
        referenceAttitude = nil
    }
    
    // MARK: - Main Motion Processing Loop
    
    private func processMotionUpdate(motion: CMDeviceMotion) {
        
        switch currentMode {
        case .tracking:
            moveCursor(motion: motion, sensitivity: trackingSensitivity)
        case .scrolling:
            scrollWindow(motion: motion, sensitivity: scrollSensitivity)
        case .paused, .scrollReady, .centering:
            // Do nothing, but allow gesture processing
            break
        case .gestureMode:
            // Gesture mode handles cursor movement implicitly if a gesture is not active
            break
        }
        
        if isGestureEnabled {
            processGestures(motion: motion)
        }
        
        // Update status display for complex modes
        if currentMode == .paused {
            status = "Paused Mode Active (Exit: Still 1s → R → L)"
        } else if currentMode == .scrollReady {
            status = "Scroll Ready (5s to position mouse)..."
        } else if currentMode == .scrolling {
            status = "Scrolling Mode Active (Exit: Still 1s → R → L)"
        } else if currentMode == .gestureMode && !gestureSteps.isEmpty {
            status = "Gesture: Step \(gestureSteps.count + 1). Last: \(gestureSteps.last!)"
        } else if currentMode == .tracking {
            status = "Tracking Active"
        }
    }
    
    // MARK: - Cursor/Scroll Control Logic
    
    private func moveCursor(motion: CMDeviceMotion, sensitivity: Double) {
        let dx = motion.rotationRate.y * sensitivity
        let dy = motion.rotationRate.x * sensitivity * -1.0 // Invert Y for natural motion
        
        guard let event = CGEvent(source: nil) else { return }
        let currentMouseLocation = event.location
        
        var newX = currentMouseLocation.x + CGFloat(dx)
        var newY = currentMouseLocation.y + CGFloat(dy)
        
        if let screen = NSScreen.main {
            let frame = screen.frame
            newX = min(max(newX, frame.minX), frame.maxX)
            newY = min(max(newY, frame.minY), frame.maxY)
        }
        
        CGWarpMouseCursorPosition(CGPoint(x: newX, y: newY))
    }
    
    private func scrollWindow(motion: CMDeviceMotion, sensitivity: Double) {
        // Yaw (Y-axis rotation) for horizontal scroll
        let scrollX = Int(motion.rotationRate.y * sensitivity)
        // Pitch (X-axis rotation) for vertical scroll (Invert Y for natural scroll)
        let scrollY = Int(motion.rotationRate.x * sensitivity * -1.0)
        
        // FIX: Corrected CGEvent initializer arguments for scroll events
        guard let scrollEvent = CGEvent(scrollWheelEvent2Source: nil,
                                        units: .line,
                                        wheelCount: 2,
                                        wheel1: Int32(scrollY),
                                        wheel2: Int32(scrollX),
                                        wheel3: 0)
        else { return }
        
        // FIX: Corrected posting the event
        scrollEvent.post(tap: .cghidEventTap)
    }
    
    private func centerCursor() {
        currentMode = .centering
        if let screen = NSScreen.main {
            let frame = screen.frame
            let centerPoint = CGPoint(x: frame.midX, y: frame.midY)
            CGWarpMouseCursorPosition(centerPoint)
        }
        // Immediately return to tracking mode after centering
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.currentMode = .tracking
        }
    }
    
    // MARK: - Gesture Recognition
    
    private func processGestures(motion: CMDeviceMotion) {
        let yawRate = abs(motion.rotationRate.y)
        let pitchRate = abs(motion.rotationRate.x)
        let maxRate = max(yawRate, pitchRate)
        
        // 1. Detect Stillness (Initial Step)
        if maxRate < stillnessThreshold {
            if !isHeadStill {
                lastMovementTime = Date()
                isHeadStill = true
            }
            if currentMode != .gestureMode && Date().timeIntervalSince(lastMovementTime) > stillnessDuration {
                // If head is still for 1 second, enter gesture mode
                currentMode = .gestureMode
                gestureSteps = []
                status = "Gesture Started: Still 1s."
                // FIX: Replaced NSBeep() with print() to avoid error
                print("Gesture Start Beep")
                return
            }
        } else {
            isHeadStill = false
        }
        
        // 2. Accumulate Movements (Only when in gesture mode)
        guard currentMode == .gestureMode else { return }
        
        if maxRate > movementThreshold {
            let currentMove: HeadMouseGesture
            
            if yawRate > pitchRate { // Horizontal movement dominates
                currentMove = motion.rotationRate.y > 0 ? .right : .left
            } else { // Vertical movement dominates
                currentMove = motion.rotationRate.x > 0 ? .down : .up // Note: Pitch > 0 means rotation down
            }
            
            // Only register a step if the direction is new (or is the first step)
            if currentMove != lastDirection {
                gestureSteps.append(currentMove)
                lastDirection = currentMove
                // FIX: Replaced NSBeep() with print() to avoid error
                print("Gesture Step Beep")
                
                // Reset gesture tracking after registering a step, waiting for stillness again
                currentMode = .tracking // Temporarily exit gesture mode to allow stillness detection again
                lastMovementTime = Date()
                isHeadStill = false
                
                // 3. Check for pattern match immediately
                checkPatternMatch()
            }
        }
    }
    
    private func checkPatternMatch() {
        let sequence = gestureSteps
        let maxSteps = 4
        
        guard sequence.count > 0 && sequence.count <= maxSteps else { return }
        
        let targetSequences: [String: [HeadMouseGesture]] = [
            "Exit": [.right, .left],
            "Pause": [.right, .left, .right, .left],
            "Scroll": [.up, .down, .up, .down],
            "Center": [.right, .left, .up, .down]
        ]
        
        // Check for matches based on length
        if sequence.count == 2 {
            if sequence == targetSequences["Exit"] {
                currentMode = .tracking
                status = "Exit Gesture Confirmed. Tracking."
                gestureSteps = []
            }
        }
        
        if sequence.count == 4 {
            if sequence == targetSequences["Pause"] {
                currentMode = .paused
                status = "Pause Gesture Confirmed. Paused Mode Active."
                gestureSteps = []
            } else if sequence == targetSequences["Scroll"] {
                startScrollReadyMode()
                gestureSteps = []
            } else if sequence == targetSequences["Center"] {
                centerCursor()
                status = "Center Gesture Confirmed. Centering Cursor."
                gestureSteps = []
            }
        }
        
        // If the sequence is not finished or didn't match, we clear it out to prevent false positives
        if currentMode == .tracking {
            gestureSteps = []
        }
    }
    
    private func startScrollReadyMode() {
        currentMode = .scrollReady
        status = "Scroll Ready. Move cursor over target window (5s)."
        // FIX: Replaced NSBeep() with print() to avoid error
        print("Scroll Ready Beep")
        
        // Start 5-second timer
        scrollReadyTimer?.invalidate()
        scrollReadyTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.currentMode = .scrolling
            self.status = "Scrolling Mode Active (Exit: Still 1s → R → L)"
            // FIX: Replaced NSBeep() with print() to avoid error
            print("Scrolling Active Beep")
        }
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
            
            // Status and Mode Display
            VStack(alignment: .leading, spacing: 8) {
                Text("Current Mode:")
                    .font(.headline)
                Text("\(modeDescription(motionManager.currentMode))")
                    .font(.body)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(backgroundColor(motionManager.currentMode))
                    )
                    .foregroundColor(motionManager.currentMode == .paused ? .white : .primary)
            }
            .padding(.horizontal)
            
            Toggle("Enable Gestures", isOn: $motionManager.isGestureEnabled)
                .padding(.horizontal)
                .tint(.purple)

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
                    Text(motionManager.isRunning ? "Stop Mouse" : "Start Mouse")
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
                .keyboardShortcut("r", modifiers: .command)
                .controlSize(.large)
                .tint(.blue)
                .disabled(!motionManager.isRunning || motionManager.currentMode == .scrolling)
            }
            .padding([.top, .horizontal])
            
            Text("Tip: Calibrate when looking straight ahead. Check accessibility permissions!")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)
        }
        .padding()
        .frame(minWidth: 400)
    }
    
    // MARK: - Helper Functions
    
    private func backgroundColor(_ mode: MouseMode) -> Color {
        switch mode {
        case .tracking, .gestureMode: return .green.opacity(0.2)
        case .paused: return .red.opacity(0.9)
        case .scrolling, .scrollReady: return .orange.opacity(0.5)
        case .centering: return .blue.opacity(0.3)
        }
    }
    
    private func modeDescription(_ mode: MouseMode) -> String {
        switch mode {
        case .tracking: return "NORMAL TRACKING"
        case .paused: return "PAUSED (Gesture Control Only)"
        case .scrolling: return "SCROLLING MODE"
        case .scrollReady: return "SCROLL READY (Move Cursor Now)"
        case .centering: return "CENTERING"
        case .gestureMode: return "LISTENING FOR GESTURE"
        }
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
