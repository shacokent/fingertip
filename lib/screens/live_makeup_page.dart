import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../services/photo_makeup.dart';
import '../widgets/makeup_catalog_picker.dart';
import '../widgets/makeup_style_illustration.dart';
import 'camera_page.dart';
import 'photo_makeup_page.dart';

class LiveMakeupPage extends StatefulWidget {
  const LiveMakeupPage({
    super.key,
    this.cameraChannel = const MethodChannel('yuying/beauty'),
    this.cameraEvents,
    this.previewBuilder,
  });

  final MethodChannel cameraChannel;
  final Stream<dynamic>? cameraEvents;
  final Widget Function(BuildContext, PlatformViewCreatedCallback)?
  previewBuilder;

  @override
  State<LiveMakeupPage> createState() => _LiveMakeupPageState();
}

enum _MakeupSection {
  looks('妆造', []),
  lashes('美睫', [MakeupPart.lashes]),
  eyes('眼妆', [MakeupPart.shadow, MakeupPart.liner, MakeupPart.brows]),
  lips('唇妆', [MakeupPart.lipstick]),
  skin('底妆', [MakeupPart.foundation, MakeupPart.concealer, MakeupPart.powder]),
  cheeks('面部', [MakeupPart.blush, MakeupPart.contour, MakeupPart.highlight]),
  shape('眼形', [MakeupPart.doubleLid]);

  const _MakeupSection(this.label, this.parts);

  final String label;
  final List<MakeupPart> parts;
}

class _TrackedMakeupFrame {
  const _TrackedMakeupFrame(this.geometry, this.size, this.timestamp);

  final MakeupFaceGeometry geometry;
  final Size size;
  final int timestamp;
}

class _LiveMakeupPageState extends State<LiveMakeupPage>
    with WidgetsBindingObserver {
  static const _events = EventChannel('yuying/beauty_events');
  static const _viewType = 'yuying/beauty_preview';
  static Future<void> _nativeQueue = Future<void>.value();
  static int _nextSession = 10000;

  final _tracking = ValueNotifier<_TrackedMakeupFrame?>(null);
  StreamSubscription<dynamic>? _subscription;
  Timer? _faceExpiry;
  Timer? _focusExpiry;
  Completer<void>? _abortStart;
  MakeupDesign _design = const MakeupDesign();
  MakeupLook? _look;
  _MakeupSection _section = _MakeupSection.looks;
  MakeupPart _part = MakeupPart.lashes;
  int _session = 0, _lastTimestamp = -1;
  bool _front = true, _mirrored = false, _viewReady = false;
  bool _opening = false, _ready = false, _foreground = true;
  bool _flipping = false, _busy = false, _covered = false, _closing = false;
  bool _allowPop = false, _orientationLocked = false, _compare = false;
  String? _error;
  String _notice = '请保持单人入镜';
  Offset? _focus;

  MethodChannel get _channel => widget.cameraChannel;
  bool get _supported =>
      widget.previewBuilder != null || Platform.isAndroid || Platform.isIOS;
  bool get _cameraAction => _ready && !_busy && !_closing && !_flipping;
  bool get _hasMakeup =>
      MakeupPart.values.any((part) => _design.layer(part).amount > 0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_supported) {
      _subscription = (widget.cameraEvents ?? _events.receiveBroadcastStream())
          .listen(_receiveEvent, onError: (Object _) => _clearFace('暂时无法定位五官'));
    }
  }

  Future<void> _serial(Future<void> Function() work) {
    final next = _nativeQueue.then((_) => work());
    _nativeQueue = next.catchError((Object _) {});
    return next;
  }

  bool _current(int session) =>
      mounted && !_closing && !_covered && _foreground && _session == session;

  void _cancelStart() {
    final abort = _abortStart;
    if (abort != null && !abort.isCompleted) abort.complete();
  }

  Future<void> _nativeStop() async {
    try {
      await _channel
          .invokeMethod<void>('stop')
          .timeout(const Duration(seconds: 3));
    } on Exception {
      // The platform view also releases the camera when its route is removed.
    }
  }

  void _viewCreated(int _) {
    _viewReady = true;
    _open();
  }

  void _open() {
    if (!_supported ||
        !_viewReady ||
        !_foreground ||
        _busy ||
        _covered ||
        _closing) {
      return;
    }
    _cancelStart();
    final abort = _abortStart = Completer<void>();
    final session = _session = ++_nextSession;
    final lens = _front ? 'front' : 'rear';
    _resetTracking();
    setState(() {
      _opening = true;
      _ready = false;
      _flipping = false;
      _error = null;
    });
    unawaited(
      _serial(() async {
        if (!_current(session)) return;
        try {
          await CameraPage.waitForCameraRelease();
          if (!_current(session)) return;
          _orientationLocked = true;
          await SystemChrome.setPreferredOrientations([
            DeviceOrientation.portraitUp,
          ]);
          await _nativeStop();
          if (!_current(session)) return;
          final started = await Future.any<Map<Object?, Object?>?>([
            _channel
                .invokeMapMethod<Object?, Object?>('startMakeup', {
                  'sessionId': session,
                  'lens': lens,
                })
                .timeout(const Duration(seconds: 12)),
            abort.future.then((_) => null),
          ]);
          if (!_current(session)) return;
          if (started == null) {
            throw const FormatException('Camera start was not confirmed.');
          }
          setState(() {
            _mirrored = started['mirrored'] as bool? ?? _front;
            _ready = true;
          });
        } on PlatformException catch (error) {
          if (_current(session)) {
            setState(
              () => _error =
                  error.code.contains('PERMISSION') ||
                      error.code.contains('DENIED')
                  ? '请在系统设置中允许煜莹使用相机。'
                  : '所选镜头暂时无法打开，可切换镜头重试。',
            );
          }
        } on Exception {
          if (_current(session)) {
            setState(() => _error = '所选镜头暂时无法打开，可切换镜头重试。');
            await _nativeStop();
          }
        } finally {
          if (_current(session)) setState(() => _opening = false);
        }
      }),
    );
  }

  void _resetTracking() {
    _faceExpiry?.cancel();
    _focusExpiry?.cancel();
    _tracking.value = null;
    _lastTimestamp = -1;
    _notice = '请保持单人入镜';
    _focus = null;
  }

  void _clearFace(String notice) {
    _faceExpiry?.cancel();
    if (!mounted || _closing) return;
    _tracking.value = null;
    if (_notice != notice) setState(() => _notice = notice);
  }

  void _receiveEvent(dynamic event) {
    if (event is! Map<Object?, Object?> ||
        event['sessionId'] != _session ||
        !_current(_session)) {
      return;
    }
    if (event['type'] == 'status') {
      switch (event['status']) {
        case 'paused':
          unawaited(_recoverInterruptedPreview());
        case 'error':
        case 'cameraDenied':
          _clearFace('暂时无法定位五官');
          final message = event['message'];
          setState(() {
            _ready = false;
            _error = message is String ? message : '相机暂时不可用，请重试。';
          });
      }
      return;
    }
    if (!_ready ||
        event['type'] != 'frame' ||
        _flipping ||
        event['mirrored'] != _mirrored) {
      return;
    }
    final timestamp = event['timestampMs'];
    if (timestamp is! int || timestamp <= _lastTimestamp) return;
    _lastTimestamp = timestamp;
    final width = event['width'];
    final height = event['height'];
    final geometry = makeupFaceGeometryFromNative(event);
    if (geometry == null ||
        width is! int ||
        height is! int ||
        width <= 0 ||
        height <= 0) {
      final count = event['faceCount'];
      _clearFace(count is num && count > 1 ? '检测到多张脸，请单人试妆' : '请正对镜头，露出五官');
      return;
    }
    final size = Size(width.toDouble(), height.toDouble());
    final previous = _tracking.value;
    final elapsed = previous == null
        ? 0.0
        : (timestamp - previous.timestamp) / 1000;
    _tracking.value = _TrackedMakeupFrame(
      previous != null && previous.size == size && elapsed > 0 && elapsed < .35
          ? previous.geometry.smoothToward(geometry, elapsedSeconds: elapsed)
          : geometry,
      size,
      timestamp,
    );
    _faceExpiry?.cancel();
    final session = _session;
    _faceExpiry = Timer(const Duration(milliseconds: 450), () {
      if (_current(session)) _clearFace('请正对镜头，露出五官');
    });
  }

  void _switchLens() {
    if (_busy || _closing) return;
    setState(() => _front = !_front);
    _open();
  }

  Future<void> _flipPreview() async {
    if (!_cameraAction) return;
    final session = _session;
    _resetTracking();
    setState(() => _flipping = true);
    try {
      final value = await _channel
          .invokeMethod<bool>('setPhotoPreviewDirection', {
            'sessionId': session,
            'mirrored': !_mirrored,
          })
          .timeout(const Duration(seconds: 3));
      if (_current(session) && value != null) setState(() => _mirrored = value);
    } on Exception {
      if (_current(session)) _message('暂时无法切换取景方向，请重试。');
    } finally {
      if (_current(session)) setState(() => _flipping = false);
    }
  }

  void _focusAt(Offset offset, Size size) {
    if (!_cameraAction || size.isEmpty) return;
    final frame = _tracking.value;
    if (frame != null && !_previewRect(frame.size, size).contains(offset)) {
      return;
    }
    setState(() => _focus = offset);
    _focusExpiry?.cancel();
    _focusExpiry = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _focus = null);
    });
    unawaited(
      _channel
          .invokeMethod<void>('focusPhoto', {
            'sessionId': _session,
            'x': offset.dx / size.width,
            'y': offset.dy / size.height,
          })
          .catchError((Object _) {}),
    );
  }

  Future<void> _pause() {
    _cancelStart();
    _session = 0;
    _resetTracking();
    setState(() {
      _opening = false;
      _ready = false;
      _flipping = false;
    });
    return _supported ? _serial(_nativeStop) : Future<void>.value();
  }

  Future<void> _recoverInterruptedPreview() async {
    // CameraX may finish sending its pause status after Flutter has resumed.
    // Only the application lifecycle owns the foreground state.
    await _pause();
    final state = WidgetsBinding.instance.lifecycleState;
    if (_current(0) && (state == null || state == AppLifecycleState.resumed)) {
      _open();
    }
  }

  Future<void> _restoreOrientation() async {
    if (!_orientationLocked) return;
    _orientationLocked = false;
    await SystemChrome.setPreferredOrientations([]);
  }

  Future<void> _deleteCapture(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      await File(path).delete();
    } on FileSystemException {
      // A failed or cancelled native capture can already have removed its file.
    }
  }

  Future<void> _editPhoto({required bool capture}) async {
    if (_busy ||
        _closing ||
        (capture && (!_cameraAction || _tracking.value == null))) {
      return;
    }
    final session = _session;
    final design = _design;
    final look = _look;
    setState(() => _busy = true);
    String? path;
    try {
      if (capture) {
        final pending = _channel.invokeMethod<String>('capturePhoto', {
          'sessionId': session,
        });
        path = await pending.timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            unawaited(pending.then(_deleteCapture).catchError((Object _) {}));
            throw TimeoutException('Camera did not return a photograph.');
          },
        );
        if (!_current(session)) return;
        if (path == null || path.isEmpty) throw StateError('No photograph.');
      }
      _covered = true;
      await _pause();
      if (!mounted) return;
      if (!capture) {
        final chosen = await ImagePicker().pickImage(
          source: ImageSource.gallery,
          maxWidth: 2400,
          maxHeight: 2400,
          requestFullMetadata: false,
        );
        path = chosen?.path;
      }
      if (!mounted || path == null) return;
      final photoPath = path;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => PhotoMakeupPage(
            initialPath: photoPath,
            initialDesign: design,
            initialLook: look,
          ),
        ),
      );
    } catch (_) {
      if (mounted) _message(capture ? '这次没有拍摄成功，请重试。' : '无法打开相册，请重试。');
    } finally {
      if (capture) await _deleteCapture(path);
      if (mounted) {
        _covered = false;
        setState(() => _busy = false);
        if (!_ready) _open();
      }
    }
  }

  void _message(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _close() async {
    if (_closing || _busy) return;
    setState(() => _closing = true);
    await _pause();
    await _restoreOrientation();
    if (!mounted) return;
    setState(() => _allowPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final needsPreview = !_foreground || (_session == 0 && !_ready);
      _foreground = true;
      if (needsPreview) _open();
    } else if (_foreground &&
        (state == AppLifecycleState.hidden ||
            state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached)) {
      _foreground = false;
      if (!_closing && _session != 0) unawaited(_pause());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelStart();
    _faceExpiry?.cancel();
    _focusExpiry?.cancel();
    unawaited(_subscription?.cancel());
    _tracking.dispose();
    if (_supported && !_closing) {
      unawaited(
        _serial(() async {
          await _nativeStop();
          await _restoreOrientation();
        }),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: _allowPop,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_close());
    },
    child: Scaffold(
      appBar: AppBar(
        title: const Text('实时试妆'),
        actions: [
          if (_supported) ...[
            IconButton(
              tooltip: '左右翻转取景',
              onPressed: _cameraAction ? _flipPreview : null,
              isSelected: _mirrored,
              icon: const Icon(Icons.flip),
            ),
            IconButton(
              tooltip: _front ? '切换后摄' : '切换前摄',
              onPressed: _busy || _closing ? null : _switchLens,
              icon: const Icon(Icons.cameraswitch_outlined),
            ),
          ],
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (_, constraints) => Column(
            children: [
              Expanded(child: _preview()),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: constraints.maxHeight * .42,
                ),
                child: SingleChildScrollView(child: _controls()),
              ),
              _captureBar(),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _preview() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: LayoutBuilder(
        builder: (_, constraints) => Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Color(0xFF171418)),
            if (widget.previewBuilder case final buildPreview?)
              buildPreview(context, _viewCreated)
            else if (Platform.isAndroid)
              AndroidView(
                viewType: _viewType,
                onPlatformViewCreated: _viewCreated,
              )
            else if (Platform.isIOS)
              UiKitView(
                viewType: _viewType,
                onPlatformViewCreated: _viewCreated,
              ),
            if (_ready) ...[
              IgnorePointer(
                child: CustomPaint(
                  painter: _LiveMakeupPainter(
                    _tracking,
                    _design,
                    _mirrored,
                    _compare,
                  ),
                ),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (event) =>
                    _focusAt(event.localPosition, constraints.biggest),
              ),
              Positioned(
                left: 10,
                top: 10,
                right: 10,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: ValueListenableBuilder<_TrackedMakeupFrame?>(
                    valueListenable: _tracking,
                    builder: (_, frame, _) => _previewLabel(
                      frame == null
                          ? _notice
                          : _compare
                          ? '原肤对比'
                          : _hasMakeup
                          ? '实时妆效'
                          : '原肤 · 选择妆造开始',
                    ),
                  ),
                ),
              ),
            ],
            if (_focus case final focus?)
              Positioned(
                left: focus.dx - 19,
                top: focus.dy - 19,
                width: 38,
                height: 38,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white, width: 1.4),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              ),
            if (!_supported || _error != null)
              ColoredBox(
                color: const Color(0xFF171418),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.photo_camera_outlined,
                          color: Colors.white70,
                        ),
                        const SizedBox(height: 9),
                        Text(
                          _error ?? '此设备无法打开实时相机，可从相册试妆。',
                          style: const TextStyle(color: Colors.white),
                          textAlign: TextAlign.center,
                        ),
                        if (_supported)
                          if (_front)
                            FilledButton.icon(
                              onPressed: _busy || _closing ? null : _switchLens,
                              icon: const Icon(Icons.cameraswitch_outlined),
                              label: const Text('切换后摄'),
                            ),
                        if (_supported)
                          TextButton(
                            onPressed: _busy || _closing ? null : _open,
                            child: const Text('重试相机'),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            if (_supported && (_opening || !_viewReady || _closing))
              const Center(child: CircularProgressIndicator()),
          ],
        ),
      ),
    ),
  );

  Widget _previewLabel(String label) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0x99000000),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(
        label,
        style: const TextStyle(color: Colors.white, fontSize: 12),
      ),
    ),
  );

  Widget _captureBar() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        IconButton.outlined(
          tooltip: '从相册选择',
          onPressed: _busy || _closing
              ? null
              : () => _editPhoto(capture: false),
          icon: const Icon(Icons.photo_library_outlined),
        ),
        ValueListenableBuilder<_TrackedMakeupFrame?>(
          valueListenable: _tracking,
          builder: (_, frame, _) => FilledButton.icon(
            onPressed: _cameraAction && frame != null
                ? () => _editPhoto(capture: true)
                : null,
            icon: const Icon(Icons.camera_alt_outlined),
            label: Text(_busy ? '正在处理' : '拍照'),
          ),
        ),
        OutlinedButton.icon(
          onPressed: !_hasMakeup || _busy || _closing
              ? null
              : () => setState(() => _compare = !_compare),
          icon: const Icon(Icons.compare_outlined),
          label: Text(_compare ? '查看妆效' : '对比原肤'),
        ),
      ],
    ),
  );

  void _apply(MakeupDesign design, {MakeupLook? look}) => setState(() {
    _design = design;
    _look = look;
    _compare = false;
  });

  void _setLayer(MakeupLayer layer) => _apply(_design.setLayer(_part, layer));

  Widget _strip(Iterable<Widget> children) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Row(
      children: [
        for (final child in children)
          Padding(padding: const EdgeInsets.only(right: 7), child: child),
      ],
    ),
  );

  Widget _controls() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _strip(
        _MakeupSection.values.map(
          (section) => ChoiceChip(
            label: Text(section.label),
            selected: _section == section,
            onSelected: _busy || _closing
                ? null
                : (_) => setState(() {
                    _section = section;
                    if (section.parts.isNotEmpty) _part = section.parts.first;
                  }),
          ),
        ),
      ),
      if (_section == _MakeupSection.looks) _looks() else _parts(),
    ],
  );

  Widget _looks() {
    final look = _look;
    return MakeupLookPicker(
      selectedLook: look,
      hasMakeup: _hasMakeup,
      strength: look?.strengthIn(_design) ?? 1,
      enabled: !_busy && !_closing,
      onSelect: (next) =>
          _apply(next?.design ?? const MakeupDesign(), look: next),
      onStrengthChanged: (amount) {
        if (look != null) _apply(look.atStrength(amount), look: look);
      },
    );
  }

  Widget _card(
    String label,
    bool selected,
    Widget illustration,
    VoidCallback onTap,
  ) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: selected ? colors.primaryContainer : colors.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? colors.primary : colors.outlineVariant,
        ),
      ),
      child: Semantics(
        selected: selected,
        button: true,
        child: InkWell(
          onTap: _busy || _closing ? null : onTap,
          child: SizedBox(
            width: 78,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    height: 37,
                    child: illustration,
                  ),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _parts() {
    final effect = _design.layer(_part);
    final styles = _part.styleNames;
    final shape = _section == _MakeupSection.shape;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_section.parts.length > 1)
          _strip(
            _section.parts.map(
              (part) => ChoiceChip(
                label: Text(part.label),
                selected: _part == part,
                onSelected: _busy || _closing
                    ? null
                    : (_) => setState(() => _part = part),
              ),
            ),
          ),
        if (shape)
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 2, 12, 4),
            child: Text('双眼皮妆'),
          ),
        if (_part == MakeupPart.lashes)
          _strip(
            styles.indexed.map(
              (item) => _card(
                item.$2,
                effect.amount > 0 && effect.style == item.$1,
                MakeupStyleIllustration(lashStyle: item.$1, lashesOnly: true),
                () => _setLayer(
                  effect.copyWith(
                    style: item.$1,
                    amount: effect.amount > 0 ? effect.amount : .5,
                  ),
                ),
              ),
            ),
          )
        else if (styles.length > 1)
          _strip(
            styles.indexed.map(
              (item) => ChoiceChip(
                label: Text(item.$2),
                selected: effect.amount > 0 && effect.style == item.$1,
                onSelected: _busy || _closing
                    ? null
                    : (_) => _setLayer(
                        effect.copyWith(
                          style: item.$1,
                          amount: effect.amount > 0 ? effect.amount : .38,
                        ),
                      ),
              ),
            ),
          ),
        if (!shape && _part.palette.length > 1)
          MakeupShadePicker(
            part: _part,
            selectedColor: effect.amount > 0 ? effect.color : null,
            onSelect: _busy || _closing
                ? null
                : (color) => _setLayer(
                    effect.copyWith(
                      color: color,
                      amount: effect.amount > 0 ? effect.amount : .38,
                    ),
                  ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Text(shape ? '幅度' : '薄厚'),
              Expanded(
                child: Slider(
                  value: effect.amount,
                  onChanged: _busy || _closing
                      ? null
                      : (amount) => _setLayer(effect.copyWith(amount: amount)),
                ),
              ),
              Text('${(effect.amount * 100).round()}%'),
              if (effect.amount > 0)
                IconButton(
                  tooltip: '卸除${_part.label}',
                  onPressed: _busy || _closing
                      ? null
                      : () => _setLayer(effect.copyWith(amount: 0)),
                  icon: const Icon(Icons.remove_circle_outline, size: 19),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

Rect _previewRect(Size source, Size bounds) => Alignment.center.inscribe(
  applyBoxFit(BoxFit.contain, source, bounds).destination,
  Offset.zero & bounds,
);

class _LiveMakeupPainter extends CustomPainter {
  _LiveMakeupPainter(this.frames, this.design, this.mirrored, this.compare)
    : super(repaint: frames);

  final ValueNotifier<_TrackedMakeupFrame?> frames;
  final MakeupDesign design;
  final bool mirrored, compare;

  @override
  void paint(Canvas canvas, Size size) {
    final frame = frames.value;
    if (frame == null || compare || size.isEmpty) return;
    final rect = _previewRect(frame.size, size);
    canvas.save();
    canvas.clipRect(rect);
    paintLiveMakeup(canvas, rect, frame.geometry, design, mirrored: mirrored);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LiveMakeupPainter oldDelegate) =>
      oldDelegate.frames != frames ||
      oldDelegate.design != design ||
      oldDelegate.mirrored != mirrored ||
      oldDelegate.compare != compare;
}
