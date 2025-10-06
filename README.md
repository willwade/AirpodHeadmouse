## AirPods Head Mouse (macOS)

A SwiftUI application for macOS that transforms compatible Apple headphones (AirPods Pro, AirPods Max, or AirPods 3rd Gen) into a head-tracking mouse input device. This project uses Apple's proprietary Core Motion framework to read head rotation data and translates those movements into cursor control on the screen. Warning: Its flaky!



https://github.com/user-attachments/assets/52accb63-d78a-4bb4-9b01-d1c07ce11c7e



## Requirements
### Hardware

Mac: Any Mac computer running a modern version of macOS (required for SwiftUI, Core Motion, and CGWarpMouseCursorPosition).

Headphones: AirPods Pro (any generation), AirPods Max, AirPods 3rd Generation, or Beats Fit Pro.


##  Accessibility Access (System Settings)

The app needs permission to programmatically move the cursor (CGWarpMouseCursorPosition).

Run the app once.

Go to System Settings > Privacy & Security > Accessibility.

Click the lock to make changes and add your compiled application (e.g., HeadMouse) to the list of applications allowed to control your computer. The Head Mouse will not work until this step is completed.

## Usage
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

