# Offline inference and SDK statistics

The app bundles its hand and face models. Camera frames remain in native memory;
only normalized face position/pose and camera state cross the Flutter bridge.
A temporary JPEG is created only after the user presses the shutter.

`com.google.mediapipe:tasks-vision` is pinned to `0.10.35`. Its transitive
`TasksStatsLoggerFactory` normally creates a proto statistics logger. The app's
`OfflineTasksStatsVisitorFactory` build transform replaces that factory method
with the SDK's own `TasksStatsDummyLogger.create(...)`, a no-op implementation.
The transform applies to all build variants and both hand and face tasks. It
fails the build if the reviewed factory signature changes. This is app-owned
build code; the upstream SDK binaries and model licences are retained unchanged.

The release manifest separately removes `INTERNET` and `ACCESS_NETWORK_STATE`,
including permissions introduced by transitive libraries. No analytics, remote
model loader, or cloud processing service is added. The iOS counterpart uses
system Vision and AVFoundation and does not add MediaPipe Tasks.

Validation must inspect the instrumented factory bytecode, verify the final APK
permissions, exercise the real bundled face model, and regress the existing hand
task. A camera preview frame rate is not inferred from model documentation.

MediaPipe SDK: Apache-2.0, see `assets/models/MEDIAPIPE_LICENSE.txt`.
CameraX libraries: Apache-2.0.
