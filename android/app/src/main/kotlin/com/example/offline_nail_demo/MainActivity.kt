package com.example.offline_nail_demo

import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarker
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/** The supplied photo must already have EXIF rotation/mirroring baked into its pixels. */
class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var detector: HandLandmarker? = null
    private var channel: MethodChannel? = null
    private var appInfoChannel: MethodChannel? = null
    private var beauty: OfflineBeautyPlugin? = null
    @Volatile private var disposed = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        worker.execute { retireHairModelCache() }
        beauty = OfflineBeautyPlugin(this, flutterEngine)
        appInfoChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "offline_nail/app_info")
        appInfoChannel!!.setMethodCallHandler { call, result ->
            if (call.method == "getVersion") {
                @Suppress("DEPRECATION")
                val info = packageManager.getPackageInfo(packageName, 0)
                result.success(info.versionName)
            } else {
                result.notImplemented()
            }
        }
        val loader = io.flutter.FlutterInjector.instance().flutterLoader()
        val assetPath = loader.getLookupKeyForAsset("assets/models/hand_landmarker.task")
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "offline_nail/hand_landmarker")
        channel!!.setMethodCallHandler { call, result ->
            if (call.method != "detectImage") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val path = call.argument<String>("path")
            if (path.isNullOrBlank()) {
                result.error("INVALID_ARGUMENT", "A canonical image file path is required.", null)
                return@setMethodCallHandler
            }
            worker.execute {
                try {
                    require(File(path).isFile) { "The selected image is no longer available." }
                    val started = SystemClock.elapsedRealtime()
                    if (detector == null) {
                        val baseOptions = BaseOptions.builder().setModelAssetPath(assetPath).build()
                        val options = HandLandmarker.HandLandmarkerOptions.builder()
                            .setBaseOptions(baseOptions)
                            .setRunningMode(RunningMode.IMAGE)
                            .setNumHands(2)
                            .setMinHandDetectionConfidence(0.45f)
                            .setMinHandPresenceConfidence(0.45f)
                            .setMinTrackingConfidence(0.5f)
                            .build()
                        detector = HandLandmarker.createFromOptions(applicationContext, options)
                    }
                    val bitmap = BitmapFactory.decodeFile(path)
                        ?: throw IllegalArgumentException("The image cannot be decoded.")
                    try {
                        val image = BitmapImageBuilder(bitmap).build()
                        try {
                            val detection = detector!!.detect(image)
                            val hands = detection.landmarks().mapIndexed { index, landmarks ->
                                val classification = detection.handedness().getOrNull(index)?.firstOrNull()
                                mapOf(
                                    "landmarks" to landmarks.map { point ->
                                        mapOf("x" to point.x().toDouble(), "y" to point.y().toDouble(), "z" to point.z().toDouble())
                                    },
                                    "handedness" to (classification?.categoryName() ?: "Unknown"),
                                    "score" to (classification?.score()?.toDouble() ?: 0.0)
                                )
                            }
                            val payload = mapOf(
                                "hands" to hands,
                                "width" to bitmap.width,
                                "height" to bitmap.height,
                                "elapsedMs" to (SystemClock.elapsedRealtime() - started),
                                "backend" to "MediaPipe CPU"
                            )
                            main.post { if (!disposed) result.success(payload) }
                        } finally {
                            image.close()
                        }
                    } finally {
                        bitmap.recycle()
                    }
                } catch (error: Throwable) {
                    // Keep diagnosis local and omit the user's image path/content.
                    val safeMessage = generateSequence(error) { it.cause }.take(6)
                        .joinToString(" <- ") { cause ->
                            "${cause.javaClass.simpleName}: ${cause.message ?: "(no message)"}"
                        }
                        .replace(path, "<local-image>")
                        .take(2400)
                    Log.e("OfflineNailHand", safeMessage)
                    main.post {
                        if (!disposed) result.error("HAND_DETECTION_FAILED", error.message ?: "Local hand analysis failed.", null)
                    }
                }
            }
        }
    }

    private fun retireHairModelCache() {
        // Previous versions copied bundled weights here for mmap. Only remove
        // their immutable cache artifacts. Finished photos live elsewhere.
        runCatching {
            val directory = File(filesDir.canonicalFile, "hair_models")
            if (directory.canonicalFile != directory || !directory.isDirectory) return@runCatching
            val names = setOf(
                "sd15-inpaint-q4_0.gguf",
                "lcm-lora-sdv1-5.safetensors",
                "validated-v1.json"
            )
            val partial = Regex(
                """^\.(sd15-inpaint-q4_0\.gguf|lcm-lora-sdv1-5\.safetensors|validated)\.[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\.tmp$"""
            )
            directory.listFiles()?.forEach { file ->
                if (file.isFile && file.canonicalFile == file &&
                    (file.name in names || partial.matches(file.name))
                ) {
                    file.delete()
                }
            }
            directory.delete() // Only succeeds when no unrecognized files remain.
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (beauty?.onRequestPermissionsResult(requestCode, grantResults) == true) return
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onPause() {
        beauty?.onHostPause()
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        beauty?.onHostResume()
    }

    override fun onDestroy() {
        beauty?.dispose()
        beauty = null
        disposed = true
        channel?.setMethodCallHandler(null)
        appInfoChannel?.setMethodCallHandler(null)
        worker.execute { detector?.close(); detector = null }
        worker.shutdown()
        super.onDestroy()
    }
}
