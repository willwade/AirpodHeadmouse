import SwiftUI
import CoreMotion
import CoreGraphics
import Combine
import AppKit
import AVFoundation

// MARK: - Gesture Definition
enum HeadMouseGesture: Equatable {
    case right, left, up, down
}

enum MouseMode: Equatable {
    case tracking      // Default mode: Head motion moves cursor position
    case paused        // Cursor movement is disabled by gesture
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
    // FIX 3: Gestures off by default
    @Published var isGestureEnabled: Bool = false
    @Published var currentMode: MouseMode = .tracking
    @Published var gestureSteps: [HeadMouseGesture] = []
    
    // New: Keyboard Override State
    @Published var isSpacebarPaused: Bool = false
    
    // Direction Toggles for User Preference
    @Published var invertXAxis: Bool = false
    @Published var invertYAxis: Bool = false
    
    // Damping and Sensitivity Settings
    @Published var dampingFactor: Double = 0.8 // Lower value = Smoother/more damped
    private var dampedDx: Double = 0.0 // State for smoothed X velocity
    private var dampedDy: Double = 0.0 // State for smoothed Y velocity
    private let trackingSensitivity: Double = 300.0 // Multiplier for cursor speed
    private let scrollSensitivity: Double = 3.0 // Multiplier for scroll speed
    
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
    // NOTE: For simplicity, we use print statements as audio feedback (NSBeep is often problematic in sandboxed macOS apps).
    private var audioPlayer: AVAudioPlayer?
    
    override init() {
        super.init()
        manager.delegate = self
        checkAvailability()
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
        // Initialization for future custom sound implementation, currently uses print statements.
    }
    
    // MARK: - Public Control Methods
    
    func startTracking() {
        guard manager.isDeviceMotionAvailable else {
            status = "Motion unavailable."
            return
        }
        
        // Reset damping state when starting
        dampedDx = 0.0
        dampedDy = 0.0
        
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
        isSpacebarPaused = false // Reset keyboard pause
    }
    
    func calibrate() {
        // FIX 4: Only require motionData to be present for a non-running calibration.
        guard let currentMotion = motionData else {
            status = "Waiting for motion data to calibrate."
            return
        }
        // Calibration resets the zero point for relative tracking.
        referenceAttitude = currentMotion.attitude
        status = isRunning ? "Calibrated. Tracking Head Mouse..." : "Calibrated (Start Tracking)."
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
        
        let xFactor = invertXAxis ? -1.0 : 1.0
        let yFactor = invertYAxis ? -1.0 : 1.0
        
        // FIX: X-Axis Direction Swap
        // The * -1.0 factor here corrects the input direction.
        let rawDx = motion.rotationRate.y * trackingSensitivity * -1.0 * xFactor
        
        // FIX: Y-Axis Direction Fix
        // Pitch (X-axis rotation). Head down (positive pitch) should yield cursor down (positive Y).
        let rawDy = motion.rotationRate.x * trackingSensitivity * yFactor
        
        // Apply smoothing filter regardless of mode (except gesture)
        let alpha = 1.0 - dampingFactor // 0.2
        
        // Exponential Moving Average (EMA) for Smoothing
        dampedDx = (alpha * rawDx) + ((1.0 - alpha) * dampedDx)
        dampedDy = (alpha * rawDy) + ((1.0 - alpha) * dampedDy)
        
        
        if isRunning && !isSpacebarPaused { // Check keyboard override first
            switch currentMode {
            case .tracking:
                moveCursor(dx: dampedDx, dy: dampedDy)
            case .scrolling:
                scrollWindow(motion: motion, sensitivity: scrollSensitivity)
            case .paused, .scrollReady, .centering:
                // Do nothing, but allow gesture processing
                break
            case .gestureMode:
                // Stillness check needed for gesture mode, but no cursor movement
                break
            }
        }
        
        if isGestureEnabled {
            processGestures(motion: motion)
        }
        
        // Update status display for complex modes
        if isSpacebarPaused {
            status = "KEYBOARD PAUSED (Control Key Held)"
        } else if currentMode == .paused {
            status = "Paused Mode Active (Exit: Still 1s → R → L)"
        } else if currentMode == .scrollReady {
            status = "Scroll Ready (5s to position mouse)..."
        } else if currentMode == .scrolling {
            status = "Scrolling Mode Active (Exit: Still 1s → R → L)"
        } else if currentMode == .gestureMode && !gestureSteps.isEmpty {
            status = "Gesture: Step \(gestureSteps.count + 1). Last: \(gestureSteps.last!)"
        } else if currentMode == .tracking {
            status = "Tracking Active"
        } else if !isRunning {
            status = "Tracking Stopped."
        }
    }
    
    // MARK: - Cursor/Scroll Control Logic
    
    private func moveCursor(dx: Double, dy: Double) {
        
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
        let scrollX = Int32(motion.rotationRate.y * sensitivity)
        // Pitch (X-axis rotation) for vertical scroll (Invert Y for natural scroll)
        let scrollY = Int32(motion.rotationRate.x * sensitivity * -1.0)
        
        // Corrected initializer expected by the current SDK for the argument labels.
        guard let scrollEvent = CGEvent(scrollWheelEvent2Source: nil,
                                        units: .line,
                                        wheelCount: 2,
                                        wheel1: scrollY, // Vertical scroll
                                        wheel2: scrollX, // Horizontal scroll
                                        wheel3: 0)
        else { return }
        
        // Explicitly access the cghidEventTap member using the enum type.
        scrollEvent.post(tap: CGEventTapLocation.cghidEventTap)
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
                print("Gesture Start Beep")
                return
            }
        } else {
            isHeadStill = false
        }
        
        // 2. Accumulate Movements (Only when in gesture mode)
        // We temporarily exit gesture mode after a move is recorded to force stillness for the next step.
        guard currentMode == .gestureMode || currentMode == .tracking else { return }
        
        if maxRate > movementThreshold {
            let currentMove: HeadMouseGesture
            
            if yawRate > pitchRate { // Horizontal movement dominates
                currentMove = motion.rotationRate.y > 0 ? .right : .left
            } else { // Vertical movement dominates
                currentMove = motion.rotationRate.x > 0 ? .down : .up // Pitch > 0 means rotation down
            }
            
            // Only register a step if the direction is new (or is the first step)
            if currentMove != lastDirection {
                gestureSteps.append(currentMove)
                lastDirection = currentMove
                print("Gesture Step Beep: \(currentMove)")
                
                // Immediately check for pattern match after a step
                checkPatternMatch()
                
                // Transition back to tracking to require stillness for the NEXT step
                currentMode = .tracking
                lastMovementTime = Date()
                isHeadStill = false
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
                return
            }
        }
        
        if sequence.count == 4 {
            if sequence == targetSequences["Pause"] {
                currentMode = .paused
                status = "Pause Gesture Confirmed. Paused Mode Active."
                gestureSteps = []
                return
            } else if sequence == targetSequences["Scroll"] {
                startScrollReadyMode()
                gestureSteps = []
                return
            } else if sequence == targetSequences["Center"] {
                centerCursor()
                status = "Center Gesture Confirmed. Centering Cursor."
                gestureSteps = []
                return
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
        print("Scroll Ready Beep")
        
        // Start 5-second timer
        scrollReadyTimer?.invalidate()
        scrollReadyTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.currentMode = .scrolling
            self.status = "Scrolling Mode Active (Exit: Still 1s → R → L)"
            print("Scrolling Active Beep")
        }
    }
}

// MARK: - SwiftUI View
struct ContentView: View {
    @StateObject private var motionManager = HeadMouseManager()
    
    // FIX 2: Added @FocusState to manage and dismiss the focus ring
    @FocusState private var isFocused: Bool
    
    var body: some View {
        VStack(spacing: 16) {
            
            Text("AirPods Head Mouse")
                .font(.title2.bold())
                .foregroundColor(.accentColor)
            
            // Status and Mode Display
            VStack(alignment: .leading, spacing: 4) {
                Text("Current Mode:")
                    .font(.subheadline.weight(.semibold))
                
                // Display combined mode status
                Text(motionManager.isSpacebarPaused ? "KEYBOARD PAUSED" : "\(modeDescription(motionManager.currentMode))")
                    .font(.body)
                    .padding(6)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(backgroundColor(motionManager.isSpacebarPaused ? .paused : motionManager.currentMode))
                    )
                    .foregroundColor(motionManager.isSpacebarPaused ? .white : (motionManager.currentMode == .paused ? .white : .primary))
                    .lineLimit(1)
            }
            .padding(.horizontal)
            
            // Controls
            HStack(spacing: 10) {
                Button {
                    motionManager.isRunning ? motionManager.stopTracking() : motionManager.startTracking()
                } label: {
                    Text(motionManager.isRunning ? "Stop" : "Start")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .tint(motionManager.isRunning ? .red : .accentColor)
                
                // Calibrate button is enabled as long as motionData is present (FIX 4)
                Button("Calibrate") {
                    motionManager.calibrate()
                }
                .controlSize(.large)
                .tint(.blue)
                .disabled(motionManager.motionData == nil) // Enabled if we have data
            }
            .padding(.horizontal)
            
            // Direction Inversion Toggles
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Invert Horizontal (X)", isOn: $motionManager.invertXAxis)
                    .tint(.blue)
                Toggle("Invert Vertical (Y)", isOn: $motionManager.invertYAxis)
                    .tint(.blue)
            }
            .padding(.horizontal)
            
            // Damping Slider
            VStack(alignment: .leading) {
                Text("Damping (Smoothing): \(motionManager.dampingFactor, specifier: "%.2f")")
                    .font(.subheadline)
                Slider(value: $motionManager.dampingFactor, in: 0.05...0.95) {
                    Text("Damping")
                }
            }
            .padding(.horizontal)
            
            // Gesture Toggle & Help
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Enable Gestures", isOn: $motionManager.isGestureEnabled)
                    .tint(.purple)
                
                // Gesture Help Guide
                DisclosureGroup("Gesture Quick Reference") {
                    VStack(alignment: .leading, spacing: 6) {
                        GestureRow(name: "Pause Mouse", sequence: "Still 1s → R → L → R → L")
                        GestureRow(name: "Scroll Mode", sequence: "Still 1s → U → D → U → D")
                        GestureRow(name: "Center Cursor", sequence: "Still 1s → R → L → U → D")
                        GestureRow(name: "Exit Mode", sequence: "Still 1s → R → L")
                    }
                    .font(.caption)
                    .padding(.top, 4)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
                
            }
            .padding(.horizontal)
            
            Text("Tip: Hold **Control** to temporarily freeze the cursor.")
                .font(.caption2.bold())
                .foregroundColor(.secondary)
                .padding(.bottom, 4)
            
            Text("Tip: Check 'Privacy & Security' > 'Accessibility' for full control.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.bottom, 4)
        }
        .padding(8)
        .frame(width: 300) // Compact Window Width
        // MARK: - Keyboard Input Handler
        .focused($isFocused) // Link focus state to the view
        .onAppear {
            isFocused = true // Ensure the view has focus when it appears
        }
        // FIX: Use modifiers check for Control key
        .onKeyPress(phases: .down) { keyPress in
            guard motionManager.isRunning else { return .ignored }
            
            // Check if Control key is the ONLY key modifier pressed
            guard keyPress.modifiers.contains(.control) else { return .ignored }
            
            // Key Down: Pause the tracking
            motionManager.isSpacebarPaused = true
            return .handled
        }
        .onKeyPress(phases: .up) { keyPress in
            guard motionManager.isRunning else { return .ignored }
            
            // Check if Control key is the ONLY key modifier released
            guard keyPress.modifiers.contains(.control) else { return .ignored }

            // Key Up: Resume tracking
            motionManager.isSpacebarPaused = false
            return .handled
        }
    }
    
    // MARK: - Helper Views
    
    @ViewBuilder
    private func GestureRow(name: String, sequence: String) -> some View {
        HStack {
            Text(name + ":")
                .fontWeight(.bold)
            Spacer()
            Text(sequence)
        }
    }
    
    // MARK: - Helper Functions (Re-used)
    
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
        case .paused: return "PAUSED (Gesture)"
        case .scrolling: return "SCROLLING"
        case .scrollReady: return "SCROLL READY (5S TIMER)"
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
        // Force the window to fit the content size (300px wide)
        .windowResizability(.contentSize)
    }
}
