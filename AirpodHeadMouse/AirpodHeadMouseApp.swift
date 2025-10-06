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
    @Published var isGestureEnabled: Bool = false
    
    // NEW: Reliable Control Key Override State
    @Published var isControlKeyPaused: Bool = false
    
    @Published var currentMode: MouseMode = .tracking
    @Published var gestureSteps: [HeadMouseGesture] = []
    
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
    
    // AppKit Polling for Control Key
    private var modifierCheckTimer: Timer?
    
    // Audio Feedback
    private var audioPlayer: AVAudioPlayer?
    
    override init() {
        super.init()
        self.manager.delegate = self
        self.checkAvailability()
        self.setupAudioFeedback()
        self.setupControlKeyMonitoring() // Start monitoring Control key state
    }
    
    // NEW: Function to monitor the Control key state using AppKit
    private func setupControlKeyMonitoring() {
        // Polls the modifier flags every 0.1 seconds to detect the Control key state
        self.modifierCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            // Check if the Control key is currently held down
            let isControlDown = NSEvent.modifierFlags.contains(.control)
            
            // Only update the pause state if tracking is running
            if self.isRunning {
                self.isControlKeyPaused = isControlDown
            } else if self.isControlKeyPaused {
                // If tracking stops while key is held, reset the pause state
                self.isControlKeyPaused = false
            }
        }
        // Add to the common run loop to ensure it runs reliably
        RunLoop.current.add(self.modifierCheckTimer!, forMode: .common)
    }
    
    // MARK: - Initialization and Connection
    
    private func checkAvailability() {
        if self.manager.isDeviceMotionAvailable {
            self.status = "Ready. Tap 'Start Tracking'."
        } else {
            self.status = "Error: Headphone motion not available."
        }
    }
    
    private func setupAudioFeedback() {
        // Implementation placeholder for future custom sound.
    }
    
    // MARK: - Public Control Methods
    
    func startTracking() {
        guard self.manager.isDeviceMotionAvailable else {
            self.status = "Motion unavailable."
            return
        }
        
        self.dampedDx = 0.0
        self.dampedDy = 0.0
        
        self.manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
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
        self.manager.stopDeviceMotionUpdates()
        self.isRunning = false
        self.currentMode = .tracking
        self.status = "Tracking Stopped."
        self.scrollReadyTimer?.invalidate()
        self.scrollReadyTimer = nil
        self.isControlKeyPaused = false // Reset keyboard pause
    }
    
    func calibrate() {
        // FIX: Calibrate button is enabled as long as motionData is present.
        guard let currentMotion = self.motionData else {
            self.status = "Waiting for motion data to calibrate."
            return
        }
        self.referenceAttitude = currentMotion.attitude
        self.status = self.isRunning ? "Calibrated. Tracking Head Mouse..." : "Calibrated (Start Tracking)."
        self.isHeadStill = false
        self.gestureSteps = []
    }
    
    // MARK: - CMHeadphoneMotionManagerDelegate
    
    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        self.status = "Headphones Connected. Ready."
        if !self.isRunning {
            self.startTracking()
        }
    }
    
    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        self.status = "Headphones Disconnected. Stop Tracking."
        self.stopTracking()
        self.referenceAttitude = nil
    }
    
    // MARK: - Main Motion Processing Loop
    
    private func processMotionUpdate(motion: CMDeviceMotion) {
        
        let xFactor = self.invertXAxis ? -1.0 : 1.0
        let yFactor = self.invertYAxis ? -1.0 : 1.0
        
        // Corrects X-axis direction (Yaw rotation on Y-axis)
        let rawDx = motion.rotationRate.y * self.trackingSensitivity * -1.0 * xFactor
        
        // Corrects Y-axis direction (Pitch rotation on X-axis)
        let rawDy = motion.rotationRate.x * self.trackingSensitivity * yFactor
        
        // Apply smoothing filter
        let alpha = 1.0 - self.dampingFactor
        
        // Exponential Moving Average (EMA) for Smoothing
        self.dampedDx = (alpha * rawDx) + ((1.0 - alpha) * self.dampedDx)
        self.dampedDy = (alpha * rawDy) + ((1.0 - alpha) * self.dampedDy)
        
        
        if self.isRunning && !self.isControlKeyPaused {
            switch self.currentMode {
            case .tracking:
                self.moveCursor(dx: self.dampedDx, dy: self.dampedDy)
            case .scrolling:
                self.scrollWindow(motion: motion, sensitivity: self.scrollSensitivity)
            case .paused, .scrollReady, .centering:
                break
            case .gestureMode:
                break
            }
        }
        
        if self.isGestureEnabled {
            self.processGestures(motion: motion)
        }
        
        // Update status display
        if self.isControlKeyPaused {
            self.status = "KEYBOARD PAUSED (Control Key Held)"
        } else if self.currentMode == .paused {
            self.status = "Paused Mode Active (Exit: Still 1s → R → L)"
        } else if self.currentMode == .scrollReady {
            self.status = "Scroll Ready (5s to position mouse)..."
        } else if self.currentMode == .scrolling {
            self.status = "Scrolling Mode Active (Exit: Still 1s → R → L)"
        } else if self.currentMode == .gestureMode && !self.gestureSteps.isEmpty {
            self.status = "Gesture: Step \(self.gestureSteps.count + 1). Last: \(self.gestureSteps.last!)"
        } else if self.currentMode == .tracking {
            self.status = "Tracking Active"
        } else if !self.isRunning {
            self.status = "Tracking Stopped."
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
        let scrollX = Int32(motion.rotationRate.y * sensitivity)
        let scrollY = Int32(motion.rotationRate.x * sensitivity * -1.0)
        
        // Using the 'scrollWheelEvent2Source' constructor for maximum compatibility
        guard let scrollEvent = CGEvent(scrollWheelEvent2Source: nil,
                                        units: .line,
                                        wheelCount: 2,
                                        wheel1: scrollY, // Vertical scroll
                                        wheel2: scrollX, // Horizontal scroll
                                        wheel3: 0)
        else { return }
        
        scrollEvent.post(tap: CGEventTapLocation.cghidEventTap)
    }
    
    private func centerCursor() {
        self.currentMode = .centering
        if let screen = NSScreen.main {
            let frame = screen.frame
            let centerPoint = CGPoint(x: frame.midX, y: frame.midY)
            CGWarpMouseCursorPosition(centerPoint)
        }
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
        if maxRate < self.stillnessThreshold {
            if !self.isHeadStill {
                self.lastMovementTime = Date()
                self.isHeadStill = true
            }
            if self.currentMode != .gestureMode && Date().timeIntervalSince(self.lastMovementTime) > self.stillnessDuration {
                self.currentMode = .gestureMode
                self.gestureSteps = []
                print("Gesture Start Beep")
                return
            }
        } else {
            self.isHeadStill = false
        }
        
        // 2. Accumulate Movements (Only when in gesture mode/tracking)
        guard self.currentMode == .gestureMode || self.currentMode == .tracking else { return }
        
        if maxRate > self.movementThreshold {
            let currentMove: HeadMouseGesture
            
            if yawRate > pitchRate {
                currentMove = motion.rotationRate.y > 0 ? .right : .left
            } else {
                currentMove = motion.rotationRate.x > 0 ? .down : .up
            }
            
            if currentMove != self.lastDirection {
                self.gestureSteps.append(currentMove)
                self.lastDirection = currentMove
                print("Gesture Step Beep: \(currentMove)")
                
                self.checkPatternMatch()
                
                self.currentMode = .tracking
                self.lastMovementTime = Date()
                self.isHeadStill = false
            }
        }
    }
    
    private func checkPatternMatch() {
        let sequence = self.gestureSteps
        let maxSteps = 4
        
        guard sequence.count > 0 && sequence.count <= maxSteps else { return }
        
        let targetSequences: [String: [HeadMouseGesture]] = [
            "Exit": [.right, .left],
            "Pause": [.right, .left, .right, .left],
            "Scroll": [.up, .down, .up, .down],
            "Center": [.right, .left, .up, .down]
        ]
        
        if sequence.count == 2 {
            if sequence == targetSequences["Exit"] {
                self.currentMode = .tracking
                self.status = "Exit Gesture Confirmed. Tracking."
                self.gestureSteps = []
                return
            }
        }
        
        if sequence.count == 4 {
            if sequence == targetSequences["Pause"] {
                self.currentMode = .paused
                self.status = "Pause Gesture Confirmed. Paused Mode Active."
                self.gestureSteps = []
                return
            } else if sequence == targetSequences["Scroll"] {
                self.startScrollReadyMode()
                self.gestureSteps = []
                return
            } else if sequence == targetSequences["Center"] {
                self.centerCursor()
                self.status = "Center Gesture Confirmed. Centering Cursor."
                self.gestureSteps = []
                return
            }
        }
        
        if self.currentMode == .tracking {
            self.gestureSteps = []
        }
    }
    
    private func startScrollReadyMode() {
        self.currentMode = .scrollReady
        self.status = "Scroll Ready. Move cursor over target window (5s)."
        print("Scroll Ready Beep")
        
        self.scrollReadyTimer?.invalidate()
        self.scrollReadyTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
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
                Text(motionManager.isControlKeyPaused ? "KEYBOARD PAUSED" : "\(modeDescription(motionManager.currentMode))")
                    .font(.body)
                    .padding(6)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(backgroundColor(motionManager.isControlKeyPaused ? .paused : motionManager.currentMode))
                    )
                    .foregroundColor(motionManager.isControlKeyPaused ? .white : (motionManager.currentMode == .paused ? .white : .primary))
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
                
                // Calibrate button is enabled as long as motionData is present
                Button("Calibrate") {
                    motionManager.calibrate()
                }
                .controlSize(.large)
                .tint(.blue)
                .disabled(motionManager.motionData == nil)
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
        // NOTE: AppKit polling handles the pause, so we don't need onKeyPress here.
        .focused($isFocused)
        .onAppear {
            isFocused = true
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
        .windowResizability(.contentSize)
    }
}
