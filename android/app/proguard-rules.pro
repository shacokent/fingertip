# Preserve native entry points used by the bundled offline inference runtimes.
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}
-keep class com.google.mediapipe.** { *; }
-keep class ai.onnxruntime.** { *; }
# Flogger discovers the enclosing logger via its call stack. Obfuscating or
# inlining these frames breaks MediaPipe's static initializer in release mode.
-keep class com.google.common.flogger.** { *; }
-keepattributes SourceFile,LineNumberTable
# Protobuf-lite resolves message fields by their generated names (for example
# Any.typeUrl_). Preserve those names and reflective schemas for MediaPipe.
-keep class com.google.protobuf.** { *; }
-keepclassmembers class * extends com.google.protobuf.GeneratedMessageLite {
    <fields>;
}
# Optional full-graph profiling/template APIs are not shipped in tasks-vision
# and are not called by this app's HandLandmarker task. Keep this suppression
# limited to the two optional protobuf message types reported by R8.
-dontwarn com.google.mediapipe.proto.CalculatorProfileProto$CalculatorProfile
-dontwarn com.google.mediapipe.proto.GraphTemplateProto$CalculatorGraphTemplate
