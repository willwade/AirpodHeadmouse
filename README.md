🎧 AirPods Head Mouse (macOS)
A SwiftUI application for macOS that transforms compatible Apple headphones (AirPods Pro, AirPods Max, or AirPods 3rd Gen) into a head-tracking mouse input device. This project leverages Apple's proprietary Core Motion framework to read head rotation data and translates those movements into cursor control on the screen.

✨ Features
Real-time Head Tracking: Uses the gyroscope and accelerometer data streamed from the connected AirPods via CMHeadphoneMotionManager.

Rotational Control: Yaw (side-to-side rotation) controls the X-axis, and Pitch (up-and-down rotation) controls the Y-axis.

Calibration: A dedicated Calibrate button (or ⌘ + R shortcut) sets the user's current facing direction as the neutral zero point.

Sensitivity Control: Cursor speed is driven by the rotation rate (angular velocity), allowing for precise or rapid movement based on head motion speed.

Connection Status: Displays real-time status of the headphone connection and tracking activity.

🛠️ Requirements
Hardware

Mac: Any Mac computer running a modern version of macOS (required for SwiftUI, Core Motion, and CGWarpMouseCursorPosition).

Headphones: AirPods Pro (any generation), AirPods Max, AirPods 3rd Generation, or Beats Fit Pro.

Software

Xcode: Latest version installed.

macOS: Version compatible with CMHeadphoneMotionManager (macOS 14.0+ / Ventura or later recommended).

🚀 Setup and Installation
Create Project: In Xcode, create a new project. Choose macOS > App, and select SwiftUI for the Interface and Swift for the Language.

Replace Code: Delete the default [ProjectName]App.swift and ContentView.swift files. Copy the entire contents of the HeadMouse.swift file from the Canvas into a new file named HeadMouse.swift.

Add Frameworks (If necessary): Ensure the CoreMotion.framework is linked in your target's Frameworks, Libraries, and Embedded Content under the General tab.

Crucial: Set Permissions (MUST READ)

This application requires two levels of permission from the operating system:

A. Motion Usage (Info.plist Key)

The app must declare why it needs to access sensor data.

Go to your project target's Info tab.

Add a new row with the key: Privacy - Motion Usage Description

Set the value to: "The application uses headphone motion data (pitch and yaw) to control the mouse cursor, enabling head tracking functionality."

B. Accessibility Access (System Settings)

The app needs permission to programmatically move the cursor (CGWarpMouseCursorPosition).

Run the app once.

Go to System Settings > Privacy & Security > Accessibility.

Click the lock to make changes and add your compiled application (e.g., HeadMouse) to the list of applications allowed to control your computer. The Head Mouse will not work until this step is completed.

🕹️ Usage
Ensure your compatible AirPods are connected to your Mac.

Click Start Head Mouse in the application window.

Look directly at the center of your screen and click the Calibrate button (⌘ + R). This sets your neutral orientation.

Move your head slightly:

Rotate your head left/right to move the cursor horizontally.

Tilt your head up/down (nod) to move the cursor vertically.

💡 Potential Enhancements
Clicking Mechanism: Implement a way to simulate a click, such as a sharp, rapid head nod (detected via user acceleration) or a Dwell Click feature.

Sensitivity Slider: Add a user-adjustable slider in the UI to change the sensitivity constant (300.0) dynamically.

Visual Feedback: Add an on-screen visual indicator (like a small target) to show the user's current head orientation relative to the calibration point.

