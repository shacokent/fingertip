package com.example.offline_nail_demo

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Matrix
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Rational
import android.util.Size
import android.view.Surface
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
import android.widget.FrameLayout
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.CameraState
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.UseCaseGroup
import androidx.camera.core.ViewPort
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.Observer
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.components.containers.NormalizedLandmark
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.facelandmarker.FaceLandmarker
import com.google.mediapipe.tasks.vision.facelandmarker.FaceLandmarkerResult
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * One camera owner for local face tracking and still photography. Makeup
 * landmarks use the same upright sensor crop as the viewfinder. Reflection
 * is a display choice independent of the saved photograph.
 */
class OfflineBeautyPlugin(private val activity: Activity, engine: FlutterEngine) {
    companion object {
        private const val CAMERA_PERMISSION = 43127
        private const val MIN_ANALYSIS_INTERVAL_MS = 65L
        private const val MAX_MAKEUP_FRAME_AGE_MS = 240L
    }

    private class CameraLifecycle : LifecycleOwner {
        val registry = LifecycleRegistry(this)
        override val lifecycle: Lifecycle get() = registry
    }

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val cameraLifecycle = CameraLifecycle()
    private val photoPreviewPreferences = activity.getSharedPreferences(
        "beauty_photo_preview", Context.MODE_PRIVATE
    )
    private val methods = MethodChannel(engine.dartExecutor.binaryMessenger, "yuying/beauty")
    private val events = EventChannel(engine.dartExecutor.binaryMessenger, "yuying/beauty_events")
    private val assetPath = io.flutter.FlutterInjector.instance().flutterLoader()
        .getLookupKeyForAsset("assets/models/face_landmarker.task")
    private var sink: EventChannel.EventSink? = null
    private var previewView: PreviewView? = null
    private var cameraProvider: ProcessCameraProvider? = null
    private var preview: Preview? = null
    private var analysis: ImageAnalysis? = null
    private var stillCapture: ImageCapture? = null
    private var stillMode = false
    private var makeupMode = false
    private var frontLens = true
    private var mirrorPreview = true
    private var camera: Camera? = null
    private var pendingStart: MethodChannel.Result? = null
    private var releasing = false
    private val releaseWaiters = mutableListOf<MethodChannel.Result>()
    private var pendingPermissionGeneration = -1L
    private var bindingGeneration = -1L
    private var hostResumed = true
    private var ownsMakeupScreenFlag = false
    @Volatile private var generation = 0L
    @Volatile private var active = false
    @Volatile private var disposed = false
    @Volatile private var sessionId = 0L
    @Volatile private var frameWidth = 480
    @Volatile private var frameHeight = 640
    @Volatile private var lastFaceCount = 0
    @Volatile private var lastElapsedMs = 0L
    private val receivedFrames = AtomicLong()
    private val analyzedFrames = AtomicLong()
    // Worker-only state, including detector access and bitmap ownership.
    private var videoDetector: FaceLandmarker? = null
    private var imageDetector: FaceLandmarker? = null
    private var lastFrame: Bitmap? = null
    private var lastFrameAt = 0L
    private var lastFace: Map<String, Double>? = null
    private var lastAnalysisAt = 0L
    private var lastVideoTimestamp = 0L
    private var lastReportedErrorAt = 0L

    init {
        cameraLifecycle.registry.currentState = Lifecycle.State.CREATED
        engine.platformViewsController.registry.registerViewFactory(
            "yuying/beauty_preview",
            object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
                override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
                    val view = PreviewView(context).apply {
                        setBackgroundColor(Color.BLACK)
                        implementationMode = PreviewView.ImplementationMode.COMPATIBLE
                        scaleType = PreviewView.ScaleType.FIT_CENTER
                    }
                    val container = FrameLayout(context).apply {
                        addView(view, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
                    }
                    previewView = view
                    applyPreviewDirection(view)
                    preview?.setSurfaceProvider(view.surfaceProvider)
                    return object : PlatformView {
                        override fun getView(): View = container
                        override fun dispose() {
                            if (previewView === view) {
                                previewView = null
                                stop(null)
                            }
                        }
                    }
                }
            }
        )
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
                sink = eventSink
            }
            override fun onCancel(arguments: Any?) { sink = null }
        })
        methods.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> start(call, result)
                "startPhoto" -> start(call, result, still = true)
                "startMakeup" -> start(call, result, still = true, makeup = true)
                "stop", "dispose" -> stop(result)
                "capture" -> capture(call, result)
                "capturePhoto" -> capturePhoto(call, result)
                "setPhotoPreviewDirection" -> setPhotoPreviewDirection(call, result)
                "focusPhoto" -> focusPhoto(call, result)
                "analyzeImage" -> analyzeImage(call, result)
                "getDiagnostics" -> result.success(mapOf(
                    "sessionId" to sessionId,
                    "active" to active,
                    "receivedFrames" to receivedFrames.get(),
                    "analyzedFrames" to analyzedFrames.get(),
                    "lastFaceCount" to lastFaceCount,
                    "lastInferenceMs" to lastElapsedMs,
                    "width" to frameWidth,
                    "height" to frameHeight,
                    "mirrored" to mirrorPreview,
                    "backend" to "MediaPipe 0.10.35 CPU (local model)",
                    "statisticsLogger" to "TasksStatsDummyLogger"
                ))
                else -> result.notImplemented()
            }
        }
    }

    private fun start(
        call: MethodCall, result: MethodChannel.Result,
        still: Boolean = false, makeup: Boolean = false
    ) {
        if (disposed) {
            result.error("DISPOSED", "美妆相机已关闭。", null)
            return
        }
        if (active || pendingStart != null || releasing) {
            result.error("CAMERA_BUSY", "请先关闭上一段自拍预览。", null)
            return
        }
        generation++
        stillMode = still
        makeupMode = makeup
        frontLens = !still || call.argument<String>("lens") != "rear"
        mirrorPreview = if (still) {
            call.argument<Boolean>("mirrored")
                ?: (if (frontLens) call.argument<Boolean>("followsSelf") else null)
                ?: photoPreviewPreferences.getBoolean(photoPreviewPreferenceKey, frontLens)
        } else true
        sessionId = (call.argument<Number>("sessionId")?.toLong() ?: generation)
        receivedFrames.set(0)
        analyzedFrames.set(0)
        lastFaceCount = 0
        pendingStart = result
        pendingPermissionGeneration = generation
        status("starting", if (frontLens) "正在打开前置相机" else "正在打开后置相机")
        if (ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED) {
            activity.requestPermissions(arrayOf(Manifest.permission.CAMERA), CAMERA_PERMISSION)
            return
        }
        if (hostResumed) bindCamera(generation)
    }

    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != CAMERA_PERMISSION) return false
        if (disposed || pendingPermissionGeneration != generation || pendingStart == null) return true
        if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            if (hostResumed) bindCamera(generation)
        } else {
            status("cameraDenied", "请在系统设置中允许相机权限。")
            pendingStart?.error("CAMERA_PERMISSION", "未获得相机权限。", null)
            pendingStart = null
        }
        return true
    }

    private fun bindCamera(ticket: Long) {
        if (bindingGeneration == ticket) return
        bindingGeneration = ticket
        val future = ProcessCameraProvider.getInstance(activity.applicationContext)
        future.addListener({
            if (ticket != generation || disposed || pendingStart == null) return@addListener
            try {
                val provider = future.get()
                val lens = if (frontLens) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
                if (!provider.hasCamera(lens)) {
                    throw IllegalStateException("这台设备没有可用的所选镜头。")
                }
                fun resolution(width: Int, height: Int) = ResolutionSelector.Builder()
                    .setAspectRatioStrategy(AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY)
                    .setResolutionStrategy(ResolutionStrategy(
                        Size(width, height), ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER
                    ))
                    .build()
                val selector = resolution(960, 720)
                val tracksMakeup = makeupMode
                val newPreview = Preview.Builder()
                    .setResolutionSelector(selector)
                    .setTargetRotation(Surface.ROTATION_0)
                    .build()
                val newAnalysis = if (stillMode && !tracksMakeup) null else ImageAnalysis.Builder()
                    .setResolutionSelector(if (tracksMakeup) resolution(640, 480) else selector)
                    .setTargetRotation(Surface.ROTATION_0)
                    .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()
                val newStillCapture = if (!stillMode) null else ImageCapture.Builder()
                    .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
                    .setTargetRotation(Surface.ROTATION_0)
                    .setJpegQuality(96)
                    .build()
                // Flutter overlays require TextureView-compatible composition.
                val view = previewView ?: PreviewView(activity).apply {
                    implementationMode = PreviewView.ImplementationMode.COMPATIBLE
                    scaleType = PreviewView.ScaleType.FIT_CENTER
                }.also { previewView = it }
                applyPreviewDirection(view)
                newPreview.setSurfaceProvider(view.surfaceProvider)
                newAnalysis?.setAnalyzer(worker) { image ->
                    analyzeCameraFrame(image, ticket, tracksMakeup)
                }
                cameraLifecycle.registry.currentState = Lifecycle.State.RESUMED
                val useCases = listOfNotNull(newPreview, newAnalysis, newStillCapture)
                val newCamera = if (tracksMakeup) {
                    // A shared sensor crop prevents the analysis from seeing
                    // different framing when CameraX chooses a fallback size.
                    val group = UseCaseGroup.Builder().setViewPort(
                        ViewPort.Builder(Rational(3, 4), Surface.ROTATION_0)
                            .setScaleType(ViewPort.FILL_CENTER)
                            .build()
                    )
                    useCases.forEach { group.addUseCase(it) }
                    provider.bindToLifecycle(cameraLifecycle, lens, group.build())
                } else {
                    provider.bindToLifecycle(cameraLifecycle, lens, *useCases.toTypedArray())
                }
                cameraProvider = provider
                preview = newPreview
                analysis = newAnalysis
                stillCapture = newStillCapture
                camera = newCamera
                active = true
                if (tracksMakeup) keepMakeupScreenOn()
                pendingStart?.success(mapOf("width" to 480, "height" to 640, "mirrored" to mirrorPreview))
                pendingStart = null
                status("ready", "相机已打开")
            } catch (error: Throwable) {
                active = false
                releaseMakeupScreenOn()
                cameraLifecycle.registry.currentState = Lifecycle.State.CREATED
                status("error", "所选相机暂时无法打开，可切换镜头后重试。")
                pendingStart?.error("CAMERA_START_FAILED", "所选相机暂时无法打开。", null)
                pendingStart = null
            }
        }, ContextCompat.getMainExecutor(activity))
    }

    private fun analyzeCameraFrame(image: ImageProxy, ticket: Long, makeup: Boolean) {
        try {
            if (!active || ticket != generation || disposed) return
            receivedFrames.incrementAndGet()
            val now = SystemClock.elapsedRealtime()
            if (now - lastAnalysisAt < MIN_ANALYSIS_INTERVAL_MS) return
            lastAnalysisAt = now
            val upright = uprightBitmap(image, cropToViewport = makeup, mirrored = !makeup)
            try {
                val started = SystemClock.elapsedRealtime()
                val detector = detector(video = true)
                val mpImage = BitmapImageBuilder(upright).build()
                try {
                    val timestamp = max(now, lastVideoTimestamp + 1)
                    lastVideoTimestamp = timestamp
                    val detection = detector.detectForVideo(mpImage, timestamp)
                    val face = faceGeometry(detection, upright.width, upright.height)
                    if (!active || ticket != generation || disposed) return
                    val faces = detection.faceLandmarks()
                    val faceCount = faces.size
                    lastFaceCount = faceCount
                    lastElapsedMs = SystemClock.elapsedRealtime() - started
                    analyzedFrames.incrementAndGet()
                    frameWidth = upright.width
                    frameHeight = upright.height
                    if (!makeup) {
                        lastFrame?.recycle()
                        lastFrame = upright.copy(Bitmap.Config.ARGB_8888, false)
                        lastFrameAt = now
                        lastFace = face
                    }
                    val payload = mutableMapOf<String, Any?>(
                        "type" to "frame", "sessionId" to sessionId,
                        "timestampMs" to now, "width" to upright.width,
                        "height" to upright.height, "face" to face,
                        "faceCount" to faceCount, "elapsedMs" to lastElapsedMs
                    )
                    if (makeup && face != null && faces.size == 1) {
                        val points = faces.single()
                        payload["makeupMesh"] = makeupMesh(points)
                        skinSample(upright, face, points)?.let { payload["skinSample"] = it }
                    }
                    main.post {
                        if (active && ticket == generation && !disposed) {
                            if (makeup) {
                                payload["mirrored"] = mirrorPreview
                                // A stalled inference or busy UI must not paint old
                                // landmarks over a viewfinder that kept advancing.
                                if (SystemClock.elapsedRealtime() - now > MAX_MAKEUP_FRAME_AGE_MS) {
                                    payload["face"] = null
                                    payload["faceCount"] = 0
                                    payload.remove("makeupMesh")
                                    payload.remove("skinSample")
                                }
                            }
                            sink?.success(payload)
                            if (!makeup && faceCount > 1) {
                                status("singleFace", "请保持画面中只有一个人。")
                            }
                        }
                    }
                } finally { mpImage.close() }
            } finally { if (!upright.isRecycled) upright.recycle() }
        } catch (error: Throwable) {
            // Do not log pixels, file paths, landmarks, or exception contents.
            val now = SystemClock.elapsedRealtime()
            if (makeup) {
                main.post {
                    if (active && ticket == generation && !disposed) {
                        sink?.success(mapOf(
                            "type" to "frame", "sessionId" to sessionId,
                            "timestampMs" to now, "width" to frameWidth,
                            "height" to frameHeight, "face" to null,
                            "faceCount" to 0, "mirrored" to mirrorPreview
                        ))
                    }
                }
                return
            }
            if (now - lastReportedErrorAt > 2000 && active && ticket == generation) {
                lastReportedErrorAt = now
                main.post {
                    if (active && ticket == generation) {
                        status("error", "本地人脸定位暂时不可用，请退出后重试。")
                    }
                }
            }
        } finally { image.close() }
    }

    private fun uprightBitmap(image: ImageProxy, cropToViewport: Boolean, mirrored: Boolean): Bitmap {
        val plane = image.planes[0]
        val crop = if (cropToViewport) image.cropRect else null
        val width = crop?.width() ?: image.width
        val height = crop?.height() ?: image.height
        val left = crop?.left ?: 0
        val top = crop?.top ?: 0
        val packed = plane.pixelStride == 4 && plane.rowStride == image.width * 4
        val raw = if (packed) {
            // CameraX's packed conversion copies the plane in one operation.
            image.toBitmap()
        } else {
            val buffer = plane.buffer.duplicate()
            val pixels = IntArray(width * height)
            for (y in 0 until height) {
                var offset = (top + y) * plane.rowStride + left * plane.pixelStride
                for (x in 0 until width) {
                    val red = buffer.get(offset).toInt() and 255
                    val green = buffer.get(offset + 1).toInt() and 255
                    val blue = buffer.get(offset + 2).toInt() and 255
                    pixels[y * width + x] = Color.rgb(red, green, blue)
                    offset += plane.pixelStride
                }
            }
            Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888)
        }
        val rotation = Matrix().apply { postRotate(image.imageInfo.rotationDegrees.toFloat()) }
        val upright = Bitmap.createBitmap(
            raw, if (packed) left else 0, if (packed) top else 0, width, height, rotation, true
        )
        if (upright !== raw) raw.recycle()
        if (!mirrored) return upright
        val reflection = Matrix().apply { setScale(-1f, 1f) }
        val reflected = Bitmap.createBitmap(upright, 0, 0, upright.width, upright.height, reflection, true)
        if (reflected !== upright) upright.recycle()
        return reflected
    }

    private fun makeupMesh(points: List<NormalizedLandmark>): List<List<Double>> =
        points.map { point -> listOf(point.x().toDouble(), point.y().toDouble()) }

    private data class Cheek(
        val red: Double, val green: Double, val blue: Double,
        val luma: Double, val quality: Double
    )

    /** Tiny cheek patches from the existing local buffer. Only aggregates leave this method. */
    private fun skinSample(
        bitmap: Bitmap, face: Map<String, Double>, points: List<NormalizedLandmark>
    ): Map<String, Double>? {
        if (points.size <= 14 || abs(face["yaw"] ?: return null) > .46) return null
        val width = bitmap.width
        val height = bitmap.height
        val lx = (face["leftEyeX"] ?: return null) * width
        val ly = (face["leftEyeY"] ?: return null) * height
        val rx = (face["rightEyeX"] ?: return null) * width
        val ry = (face["rightEyeY"] ?: return null) * height
        val ex = rx - lx
        val ey = ry - ly
        val span = hypot(ex, ey)
        if (!span.isFinite() || span < max(4.0, width * .035)) return null
        val mx = (points[13].x() + points[14].x()) * .5 * width
        val my = (points[13].y() + points[14].y()) * .5 * height
        val depth = ((mx - (lx + rx) * .5) * -ey + (my - (ly + ry) * .5) * ex) / (span * span) * .52
        if (!depth.isFinite() || depth !in .23..0.78) return null

        fun cheek(x: Double, y: Double, side: Int): Cheek? {
            val channels = Array(4) { ArrayList<Double>(9) }
            for (row in -1..1) for (column in -1..1) {
                val horizontal = side * .12 + column * .07
                val vertical = depth + row * .065
                val px = (x + ex * horizontal - ey * vertical).toInt()
                val py = (y + ey * horizontal + ex * vertical).toInt()
                if (px !in 0 until width || py !in 0 until height) continue
                val color = bitmap.getPixel(px, py)
                val red = Color.red(color) / 255.0
                val green = Color.green(color) / 255.0
                val blue = Color.blue(color) / 255.0
                val luma = .2126 * red + .7152 * green + .0722 * blue
                if (luma !in .075..0.94 || maxOf(red, green, blue) >= .995) continue
                channels[0].add(red); channels[1].add(green); channels[2].add(blue); channels[3].add(luma)
            }
            val count = channels[3].size
            if (count < 7) return null
            channels.forEach { it.sort() }
            val spread = channels[3][count * 3 / 4] - channels[3][count / 4]
            val exposure = ((channels[3][count / 2] - .075) / .14).coerceIn(0.0, 1.0)
            val quality = (1 - spread / .22).coerceIn(0.0, 1.0) * count / 9.0 * exposure
            return Cheek(
                channels[0][count / 2], channels[1][count / 2],
                channels[2][count / 2], channels[3][count / 2], quality
            )
        }
        val left = cheek(lx, ly, -1) ?: return null
        val right = cheek(rx, ry, 1) ?: return null
        val confidence = min(left.quality, right.quality) *
            (1 - abs(left.luma - right.luma) / .42).coerceIn(0.0, 1.0)
        if (confidence < .18) return null
        return mapOf(
            "r" to (left.red + right.red) * .5, "g" to (left.green + right.green) * .5,
            "b" to (left.blue + right.blue) * .5, "confidence" to confidence
        )
    }

    private fun detector(video: Boolean): FaceLandmarker {
        val cached = if (video) videoDetector else imageDetector
        if (cached != null) return cached
        val options = FaceLandmarker.FaceLandmarkerOptions.builder()
            .setBaseOptions(BaseOptions.builder().setModelAssetPath(assetPath).build())
            .setRunningMode(if (video) RunningMode.VIDEO else RunningMode.IMAGE)
            // Detect two so the UI can reject ambiguous multi-person selfies.
            .setNumFaces(2)
            .setMinFaceDetectionConfidence(0.55f)
            .setMinFacePresenceConfidence(0.55f)
            .setMinTrackingConfidence(0.5f)
            .setOutputFaceBlendshapes(false)
            .setOutputFacialTransformationMatrixes(false)
            .build()
        val created = FaceLandmarker.createFromOptions(activity.applicationContext, options)
        if (video) videoDetector = created else imageDetector = created
        return created
    }

    private fun faceGeometry(
        result: FaceLandmarkerResult, width: Int, height: Int
    ): Map<String, Double>? {
        if (result.faceLandmarks().size != 1) return null
        val points = result.faceLandmarks()[0]
        if (points.size < 468) return null
        fun point(index: Int) = Pair(points[index].x().toDouble() * width, points[index].y().toDouble() * height)
        fun eyeCenter(first: Int, second: Int): Pair<Double, Double> {
            val p = point(first); val q = point(second)
            return Pair((p.first + q.first) / 2, (p.second + q.second) / 2)
        }
        val a = eyeCenter(33, 133)
        val b = eyeCenter(362, 263)
        val left = if (a.first < b.first) a else b
        val right = if (a.first < b.first) b else a
        val roll = atan2(right.second - left.second, right.first - left.first)
        val c = cos(roll)
        val s = sin(roll)
        var lowU = Double.POSITIVE_INFINITY
        var highU = Double.NEGATIVE_INFINITY
        var lowV = Double.POSITIVE_INFINITY
        var highV = Double.NEGATIVE_INFINITY
        for (p: NormalizedLandmark in points.take(468)) {
            val x = p.x().toDouble() * width
            val y = p.y().toDouble() * height
            val u = x * c + y * s
            val v = -x * s + y * c
            lowU = min(lowU, u); highU = max(highU, u)
            lowV = min(lowV, v); highV = max(highV, v)
        }
        val faceWidth = highU - lowU
        val faceHeight = highV - lowV
        if (faceWidth < width * 0.06 || faceHeight < height * 0.06) return null
        val midU = (lowU + highU) / 2
        val midV = (lowV + highV) / 2
        val nose = point(1)
        val noseU = nose.first * c + nose.second * s
        val eyeMidU = ((left.first + right.first) * c + (left.second + right.second) * s) / 2
        val eyeDistance = hypot(right.first - left.first, right.second - left.second)
        val yaw = atan2(noseU - eyeMidU, eyeDistance * 0.8)
        return mapOf(
            "cx" to (midU * c - midV * s) / width,
            "cy" to (midU * s + midV * c) / height,
            "width" to faceWidth / width, "height" to faceHeight / height,
            "roll" to roll, "yaw" to yaw,
            "leftEyeX" to left.first / width, "leftEyeY" to left.second / height,
            "rightEyeX" to right.first / width, "rightEyeY" to right.second / height,
            // Presence passed the configured thresholds; not a calibrated score.
            "score" to 1.0
        )
    }

    private fun capture(call: MethodCall, result: MethodChannel.Result) {
        val requestedSession = call.argument<Number>("sessionId")?.toLong()
        val ticket = generation
        if (!active || (requestedSession != null && requestedSession != sessionId)) {
            result.error("CAMERA_NOT_READY", "请先打开自拍预览。", null)
            return
        }
        worker.execute {
            try {
                val frame = lastFrame
                if (!active || ticket != generation || frame == null || lastFace == null ||
                    SystemClock.elapsedRealtime() - lastFrameAt > 500) {
                    throw IllegalStateException("请保持人脸清晰后重新拍照。")
                }
                // The cached geometry and pixels originate from exactly one frame.
                val directory = File(activity.cacheDir, "beauty_captures").apply { mkdirs() }
                val file = File(directory, "beauty_capture_${UUID.randomUUID()}.jpg")
                file.outputStream().use { output ->
                    check(frame.compress(Bitmap.CompressFormat.JPEG, 95, output))
                }
                val payload = mapOf("path" to file.absolutePath, "width" to frame.width,
                    "height" to frame.height, "face" to lastFace)
                main.post {
                    if (active && ticket == generation && !disposed) result.success(payload)
                    else {
                        file.delete()
                        result.error("CAPTURE_CANCELLED", "拍照已取消。", null)
                    }
                }
            } catch (error: Throwable) {
                main.post { result.error("CAPTURE_FAILED", "请保持人脸清晰后重新拍照。", null) }
            }
        }
    }

    private val photoPreviewPreferenceKey: String
        get() = if (frontLens) "front_mirrored" else "rear_mirrored"

    private fun applyPreviewDirection(view: PreviewView) {
        // CameraX already mirrors its front PreviewView. Apply the extra
        // reflection only when the requested direction differs from that base.
        view.scaleX = if (frontLens != mirrorPreview) -1f else 1f
    }

    private fun setPhotoPreviewDirection(call: MethodCall, result: MethodChannel.Result) {
        val view = previewView
        val mirrored = call.argument<Boolean>("mirrored") ?: call.argument<Boolean>("followsSelf")
        if (!active || !stillMode || view == null || mirrored == null ||
            call.argument<Number>("sessionId")?.toLong() != sessionId) {
            result.error("CAMERA_NOT_READY", "相机尚未准备好。", null)
            return
        }
        mirrorPreview = mirrored
        applyPreviewDirection(view)
        photoPreviewPreferences.edit().putBoolean(photoPreviewPreferenceKey, mirrored).apply()
        result.success(mirrorPreview)
    }

    private fun capturePhoto(call: MethodCall, result: MethodChannel.Result) {
        val capture = stillCapture
        if (!active || capture == null || call.argument<Number>("sessionId")?.toLong() != sessionId) {
            result.error("CAMERA_NOT_READY", "相机尚未准备好，请稍后再拍。", null)
            return
        }
        val ticket = generation
        val directory = File(activity.cacheDir, "beauty_captures").apply { mkdirs() }
        val file = try {
            File.createTempFile("beauty_photo_", ".jpg", directory)
        } catch (_: Exception) {
            result.error("CAPTURE_FAILED", "照片暂时无法保存。", null)
            return
        }
        // CameraX may otherwise mirror a front-lens JPEG. Set this explicitly
        // for this still output, independent of the viewfinder's reflection.
        val metadata = ImageCapture.Metadata().apply { isReversedHorizontal = false }
        val options = ImageCapture.OutputFileOptions.Builder(file).setMetadata(metadata).build()
        capture.takePicture(options, ContextCompat.getMainExecutor(activity),
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(outputFileResults: ImageCapture.OutputFileResults) {
                    if (active && ticket == generation && !disposed) {
                        result.success(file.absolutePath)
                    } else {
                        file.delete()
                        result.error("CAPTURE_CANCELLED", "拍照已取消。", null)
                    }
                }

                override fun onError(exception: ImageCaptureException) {
                    file.delete()
                    result.error("CAPTURE_FAILED", "拍照失败，可切换镜头后重试。", null)
                }
            })
    }

    private fun focusPhoto(call: MethodCall, result: MethodChannel.Result) {
        val view = previewView
        val control = camera?.cameraControl
        val x = call.argument<Number>("x")?.toFloat()
        val y = call.argument<Number>("y")?.toFloat()
        if (stillCapture == null || view == null || control == null ||
            x == null || y == null || x !in 0f..1f || y !in 0f..1f ||
            call.argument<Number>("sessionId")?.toLong() != sessionId) {
            result.success(null)
            return
        }
        // The metering factory expects the PreviewView's pre-transform point.
        val viewX = if (view.scaleX < 0f) 1f - x else x
        val point = view.meteringPointFactory.createPoint(viewX * view.width, y * view.height)
        control.startFocusAndMetering(FocusMeteringAction.Builder(point).build())
        result.success(null)
    }

    private fun analyzeImage(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val includeMakeup = call.argument<Boolean>("includeMakeup") == true
        if (path.isNullOrBlank() || disposed) {
            result.error("INVALID_ARGUMENT", "需要本机图片路径。", null)
            return
        }
        worker.execute {
            try {
                val file = File(path).canonicalFile
                val privateRoot = File(activity.applicationInfo.dataDir).canonicalFile.path + File.separator
                require(file.path.startsWith(privateRoot) && file.isFile)
                val options = BitmapFactory.Options().apply { inPreferredConfig = Bitmap.Config.ARGB_8888 }
                val bitmap = BitmapFactory.decodeFile(file.path, options) ?: error("Cannot decode local fixture")
                try {
                    val width = bitmap.width
                    val height = bitmap.height
                    val image = BitmapImageBuilder(bitmap).build()
                    val detection = try { detector(video = false).detect(image) } finally { image.close() }
                    val faces = detection.faceLandmarks()
                    val face = faceGeometry(detection, width, height)
                    val payload = mutableMapOf<String, Any?>("width" to width, "height" to height,
                        "face" to face,
                        "faceCount" to faces.size,
                        "backend" to "MediaPipe 0.10.35 CPU (local model)")
                    if (includeMakeup && faces.size == 1) {
                        val points = faces.single()
                        payload["makeupMesh"] = makeupMesh(points)
                        if (face != null) skinSample(bitmap, face, points)?.let { payload["skinSample"] = it }
                    }
                    main.post { result.success(payload) }
                } finally { if (!bitmap.isRecycled) bitmap.recycle() }
            } catch (error: Throwable) {
                main.post { result.error("FACE_ANALYSIS_FAILED", "本机图片无法完成脸部定位。", null) }
            }
        }
    }

    private fun status(value: String, message: String) {
        if (!disposed) sink?.success(mapOf("type" to "status", "sessionId" to sessionId,
            "status" to value, "message" to message))
    }

    private fun keepMakeupScreenOn() {
        val window = activity.window
        if ((window.attributes.flags and FLAG_KEEP_SCREEN_ON) == 0) {
            window.addFlags(FLAG_KEEP_SCREEN_ON)
            ownsMakeupScreenFlag = true
        }
    }

    private fun releaseMakeupScreenOn() {
        if (!ownsMakeupScreenFlag) return
        ownsMakeupScreenFlag = false
        activity.window.clearFlags(FLAG_KEEP_SCREEN_ON)
    }

    private fun stop(result: MethodChannel.Result?) {
        releaseMakeupScreenOn()
        if (disposed || worker.isShutdown) { result?.success(null); return }
        if (releasing) { result?.let { releaseWaiters.add(it) }; return }
        if (!active && pendingStart == null && camera == null && preview == null) {
            result?.success(null)
            return
        }
        releasing = true
        result?.let { releaseWaiters.add(it) }
        generation++
        active = false
        pendingStart?.error("START_CANCELLED", "自拍预览已取消。", null)
        pendingStart = null
        pendingPermissionGeneration = -1
        val oldCamera = camera
        analysis?.clearAnalyzer()
        val owned = listOfNotNull(preview, analysis, stillCapture)
        if (owned.isNotEmpty()) cameraProvider?.unbind(*owned.toTypedArray())
        preview = null
        analysis = null
        stillCapture = null
        camera = null
        cameraLifecycle.registry.currentState = Lifecycle.State.CREATED
        var workerReleased = false
        var cameraReleased = oldCamera == null ||
            oldCamera.cameraInfo.cameraState.value?.type == CameraState.Type.CLOSED
        var finished = false
        var observer: Observer<CameraState>? = null
        fun finishIfReady() {
            if (finished || !workerReleased || !cameraReleased) return
            finished = true
            releasing = false
            observer?.let { oldCamera?.cameraInfo?.cameraState?.removeObserver(it) }
            val waiters = releaseWaiters.toList()
            releaseWaiters.clear()
            waiters.forEach { it.success(null) }
        }
        if (!cameraReleased && oldCamera != null) {
            observer = Observer { state ->
                if (state.type == CameraState.Type.CLOSED) {
                    cameraReleased = true
                    finishIfReady()
                }
            }
            oldCamera.cameraInfo.cameraState.observeForever(observer)
        }
        worker.execute {
            lastFrame?.recycle(); lastFrame = null; lastFace = null
            lastFrameAt = 0; lastAnalysisAt = 0
            // A tracker must not carry a previous lens's ROI into a new session.
            videoDetector?.close()
            videoDetector = null
            main.post { workerReleased = true; finishIfReady() }
        }
        main.postDelayed({
            if (!finished) {
                finished = true
                releasing = false
                observer?.let { oldCamera?.cameraInfo?.cameraState?.removeObserver(it) }
                val waiters = releaseWaiters.toList()
                releaseWaiters.clear()
                waiters.forEach { it.error("CAMERA_RELEASE_TIMEOUT", "相机仍在释放，请稍后重试。", null) }
            }
        }, 2500)
    }

    fun onHostPause() {
        hostResumed = false
        // Android's own permission dialog may pause the host. Keep that pending
        // request alive; the answer is handled after the dialog returns.
        val permissionGranted = ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
        if (active || (pendingStart != null && permissionGranted)) {
            status("paused", "自拍预览已暂停")
            stop(null)
        }
    }

    fun onHostResume() {
        hostResumed = true
        if (!disposed && pendingStart != null && pendingPermissionGeneration == generation &&
            ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            bindCamera(generation)
        }
    }

    fun dispose() {
        if (disposed) return
        stop(null)
        disposed = true
        sink = null
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        worker.execute {
            videoDetector?.close(); videoDetector = null
            imageDetector?.close(); imageDetector = null
        }
        worker.shutdown()
    }
}
