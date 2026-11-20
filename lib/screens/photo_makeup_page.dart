import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../services/photo_makeup.dart';
import '../widgets/makeup_catalog_picker.dart';
import '../widgets/makeup_style_illustration.dart';
import '../widgets/photo_viewport.dart';

class PhotoMakeupPage extends StatefulWidget {
  const PhotoMakeupPage({
    super.key,
    this.initialPath,
    this.initialDesign = const MakeupDesign(),
    this.initialLook,
  });

  final String? initialPath;
  final MakeupDesign initialDesign;
  final MakeupLook? initialLook;

  @override
  State<PhotoMakeupPage> createState() => _PhotoMakeupPageState();
}

enum _Section {
  looks('妆造', []),
  lashes('美睫', [MakeupPart.lashes]),
  eyes('眼妆', [MakeupPart.shadow, MakeupPart.liner, MakeupPart.brows]),
  lips('唇妆', [MakeupPart.lipstick]),
  skin('底妆', [MakeupPart.foundation, MakeupPart.concealer, MakeupPart.powder]),
  cheeks('面部', [MakeupPart.blush, MakeupPart.contour, MakeupPart.highlight]),
  shape('眼形', [MakeupPart.eyeCorner, MakeupPart.doubleLid]);

  const _Section(this.label, this.parts);
  final String label;
  final List<MakeupPart> parts;
}

class _PhotoMakeupPageState extends State<PhotoMakeupPage> {
  final _viewport = TransformationController();
  final _shareAnchor = GlobalKey();
  final _preview = GlobalKey();
  final _undo = <(MakeupDesign, int?)>[];
  final _redo = <(MakeupDesign, int?)>[];
  MakeupPhoto? _photo;
  MakeupDesign _design = const MakeupDesign();
  _Section _section = _Section.looks;
  MakeupPart _part = MakeupPart.lashes;
  int? _selectedPreset, _activePoint;
  (MakeupDesign, int?)? _sliderStart;
  bool _busy = false, _saving = false, _original = false, _pointMode = false;
  String? _error;

  bool get _blocked => _busy || _saving;

  @override
  void initState() {
    super.initState();
    final path = widget.initialPath;
    if (path != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _pick(initialPath: path);
      });
    }
  }

  @override
  void dispose() {
    _photo?.dispose();
    _viewport.dispose();
    super.dispose();
  }

  Future<void> _pick({String? initialPath}) async {
    if (_blocked) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final path =
          initialPath ??
          (await ImagePicker().pickImage(
            source: ImageSource.gallery,
            maxWidth: 2400,
            maxHeight: 2400,
            requestFullMetadata: false,
          ))?.path;
      if (!mounted || path == null) return;
      final next = await prepareMakeupPhoto(path);
      if (!mounted) {
        next.dispose();
        return;
      }
      final previous = _photo;
      _viewport.value = Matrix4.identity();
      setState(() {
        _photo = next;
        _design = initialPath == null
            ? const MakeupDesign()
            : widget.initialDesign;
        _undo.clear();
        _redo.clear();
        _selectedPreset = initialPath == null
            ? null
            : widget.initialLook?.index;
        _pointMode = false;
        _original = false;
      });
      if (previous != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
      }
    } on PlatformException {
      if (mounted) {
        setState(() => _error = '无法打开照片，请从相册重新选择。');
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '照片未能读取，请换一张清晰的正面单人照。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _remember([(MakeupDesign, int?)? snapshot]) {
    _undo.add(snapshot ?? (_design, _selectedPreset));
    if (_undo.length > 32) _undo.removeAt(0);
    _redo.clear();
  }

  void _apply(MakeupDesign design, {int? preset}) {
    setState(() {
      _remember();
      _design = design;
      _selectedPreset = preset;
      _original = false;
    });
  }

  void _history(bool undo) {
    final from = undo ? _undo : _redo;
    final to = undo ? _redo : _undo;
    if (from.isEmpty || _blocked) return;
    setState(() {
      to.add((_design, _selectedPreset));
      final (design, preset) = from.removeLast();
      _design = design;
      _selectedPreset = preset;
      _original = false;
    });
  }

  Future<void> _save({bool share = false}) async {
    final photo = _photo;
    if (photo == null || _blocked) return;
    setState(() => _saving = true);
    try {
      final path = await saveMakeupPhoto(photo, _design);
      if (!mounted) return;
      if (share) {
        final box =
            _shareAnchor.currentContext?.findRenderObject() as RenderBox?;
        final origin = box == null
            ? const Rect.fromLTWH(0, 0, 1, 1)
            : box.localToGlobal(Offset.zero) & box.size;
        await SharePlus.instance.share(
          ShareParams(files: [XFile(path)], sharePositionOrigin: origin),
        );
      } else {
        _message('已保存到本机作品。');
      }
    } catch (_) {
      if (mounted) _message(share ? '暂时无法分享，请重试。' : '暂时无法保存，请重试。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _message(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('美妆 · 妆造'),
      actions: [
        if (_photo != null) ...[
          IconButton(
            tooltip: '撤销',
            onPressed: _blocked || _undo.isEmpty ? null : () => _history(true),
            icon: const Icon(Icons.undo_rounded),
          ),
          IconButton(
            tooltip: '重做',
            onPressed: _blocked || _redo.isEmpty ? null : () => _history(false),
            icon: const Icon(Icons.redo_rounded),
          ),
          IconButton(
            tooltip: '更换照片',
            onPressed: _blocked ? null : _pick,
            icon: const Icon(Icons.add_photo_alternate_outlined),
          ),
        ],
      ],
    ),
    body: SafeArea(
      top: false,
      child: _photo == null ? _empty() : _editor(_photo!),
    ),
  );

  Widget _empty() => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              Icons.face_retouching_natural_rounded,
              size: 68,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 18),
            Text(
              '为自己搭一套妆造',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              '选一张清晰的正面单人照，试试美睫、眼妆和唇色。'
              '\n照片在本机处理。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _blocked ? null : _pick,
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('从相册选择'),
            ),
            if (_busy) ...[
              const SizedBox(height: 20),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              const Text('正在定位五官', textAlign: TextAlign.center),
            ],
            if (_error case final error?) ...[
              const SizedBox(height: 12),
              Text(error, textAlign: TextAlign.center),
            ],
          ],
        ),
      ),
    ),
  );

  Widget _editor(MakeupPhoto photo) => LayoutBuilder(
    builder: (context, constraints) => Column(
      children: [
        Expanded(child: _photoView(photo)),
        if (_busy) const LinearProgressIndicator(),
        if (_error case final error?)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(error, textAlign: TextAlign.center),
          ),
        _strip(
          _Section.values.map(
            (section) => ChoiceChip(
              label: Text(section.label),
              selected: _section == section,
              onSelected: _blocked
                  ? null
                  : (_) => setState(() {
                      _section = section;
                      if (section.parts.isNotEmpty) _part = section.parts.first;
                      _pointMode = false;
                    }),
            ),
          ),
        ),
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: constraints.maxHeight * .37),
          child: SingleChildScrollView(
            key: ValueKey(_section),
            padding: const EdgeInsets.only(bottom: 4),
            child: _section == _Section.looks ? _looks() : _productControls(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _blocked ? null : _save,
                  icon: const Icon(Icons.download_outlined),
                  label: Text(_saving ? '正在保存' : '保存妆造'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.outlined(
                key: _shareAnchor,
                tooltip: '分享妆造',
                onPressed: _blocked ? null : () => _save(share: true),
                icon: const Icon(Icons.ios_share_outlined),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _photoView(MakeupPhoto photo) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: ColoredBox(
        color: const Color(0xFFEDE6E3),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest;
            final source = Size(
              photo.image.width.toDouble(),
              photo.image.height.toDouble(),
            );
            final rect = Alignment.center.inscribe(
              applyBoxFit(BoxFit.contain, source, size).destination,
              Offset.zero & size,
            );
            final editing =
                _pointMode && !_original && !_blocked && !rect.isEmpty;
            final points = editing
                ? makeupPoints(photo, _design, _part)
                : const <Offset>[];
            return Stack(
              key: _preview,
              fit: StackFit.expand,
              children: [
                Listener(
                  onPointerDown: !editing
                      ? null
                      : (event) {
                          _activePoint = _nearestPoint(
                            event.localPosition,
                            rect,
                            points,
                          );
                        },
                  onPointerUp: (_) => _activePoint = null,
                  onPointerCancel: (_) => _activePoint = null,
                  child: PhotoViewport(
                    controller: _viewport,
                    minScale: .65,
                    maxScale: 7,
                    interactionBounds: editing ? rect : null,
                    onSceneDragStart: !editing
                        ? null
                        : () {
                            if (_activePoint != null) setState(_remember);
                          },
                    onSceneDrag: !editing
                        ? null
                        : (delta) {
                            final index = _activePoint;
                            if (index == null || index >= points.length) return;
                            final current = makeupPoints(
                              photo,
                              _design,
                              _part,
                            )[index];
                            final position =
                                current +
                                Offset(
                                  delta.dx / rect.width,
                                  delta.dy / rect.height,
                                );
                            setState(
                              () => _design = _design.setPoint(
                                photo,
                                _part,
                                index,
                                position,
                              ),
                            );
                          },
                    child: CustomPaint(
                      painter: _MakeupPreviewPainter(
                        photo,
                        _original ? null : _design,
                        rect,
                      ),
                    ),
                  ),
                ),
                if (points.isNotEmpty)
                  IgnorePointer(
                    child: AnimatedBuilder(
                      animation: _viewport,
                      builder: (_, _) => CustomPaint(
                        painter: _MakeupPointPainter(
                          points
                              .map(
                                (p) => MatrixUtils.transformPoint(
                                  _viewport.value,
                                  Offset(
                                    rect.left + p.dx * rect.width,
                                    rect.top + p.dy * rect.height,
                                  ),
                                ),
                              )
                              .toList(growable: false),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  top: 8,
                  left: 8,
                  child: _previewLabel(
                    _original
                        ? '原图'
                        : editing
                        ? '${_part.label}调点'
                        : '妆造预览',
                  ),
                ),
                Positioned(
                  left: 6,
                  bottom: 6,
                  child: Material(
                    color: const Color(0xEEFFFFFF),
                    borderRadius: BorderRadius.circular(24),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '放大画面',
                          onPressed: _zoom,
                          icon: const Icon(Icons.zoom_in, size: 20),
                        ),
                        IconButton(
                          tooltip: '复位画面',
                          onPressed: () => _viewport.value = Matrix4.identity(),
                          icon: const Icon(Icons.fit_screen_outlined, size: 20),
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  bottom: 6,
                  right: 6,
                  child: FilledButton.tonalIcon(
                    onPressed: () => setState(() => _original = !_original),
                    icon: Icon(
                      _original ? Icons.auto_awesome : Icons.compare_outlined,
                    ),
                    label: Text(_original ? '查看妆效' : '对比原图'),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );

  void _zoom() {
    final box = _preview.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final previous = _viewport.value;
    final scale = math.sqrt(
      math.pow(previous.entry(0, 0), 2) + math.pow(previous.entry(1, 0), 2),
    );
    final factor = math.min(1.4, 7 / scale);
    final center = box.size.center(Offset.zero);
    _viewport.value = Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(factor, factor, 1, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1)
      ..multiply(previous);
  }

  int? _nearestPoint(Offset target, Rect rect, List<Offset> points) {
    int? index;
    var nearest = 19.0 * 19;
    for (var i = 0; i < points.length; i++) {
      final point = points[i];
      final screen = MatrixUtils.transformPoint(
        _viewport.value,
        Offset(
          rect.left + point.dx * rect.width,
          rect.top + point.dy * rect.height,
        ),
      );
      final distance = (screen - target).distanceSquared;
      if (distance <= nearest) {
        nearest = distance;
        index = i;
      }
    }
    return index;
  }

  Widget _previewLabel(String label) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xEEFFFFFF),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(label, style: Theme.of(context).textTheme.labelMedium),
    ),
  );

  Widget _strip(Iterable<Widget> children) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final child in children)
          Padding(padding: const EdgeInsets.only(right: 7), child: child),
      ],
    ),
  );

  Widget _looks() {
    final index = _selectedPreset;
    final look = index == null ? null : MakeupLook.values[index];
    return MakeupLookPicker(
      selectedLook: look,
      hasMakeup: MakeupPart.values.any(
        (part) => _design.layer(part).amount > 0,
      ),
      strength: look?.strengthIn(_design) ?? 1,
      enabled: !_blocked,
      onSelect: _applyLook,
      onStrengthStart: (_) => _sliderStart = (_design, _selectedPreset),
      onStrengthChanged: (strength) {
        if (look == null) return;
        setState(() {
          _design = _design.replaceLayers(look.atStrength(strength));
          _original = false;
        });
      },
      onStrengthEnd: (strength) {
        final before = _sliderStart;
        _sliderStart = null;
        if (before != null &&
            look != null &&
            look.strengthIn(before.$1) != strength) {
          setState(() => _remember(before));
        }
      },
    );
  }

  void _applyLook(MakeupLook? look) {
    final palette = look?.design ?? const MakeupDesign();
    _apply(_design.replaceLayers(palette), preset: look?.index);
  }

  Widget _productControls() {
    final effect = _design.layer(_part);
    final styles = _part.styleNames;
    final lashes = _part == MakeupPart.lashes;
    final shape = _section == _Section.shape;
    final hasPoints = makeupPoints(_photo!, _design, _part).isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_section.parts.length > 1)
          _strip(
            _section.parts.map(
              (part) => ChoiceChip(
                label: Text(part.label),
                selected: _part == part,
                onSelected: _blocked
                    ? null
                    : (_) => setState(() {
                        _part = part;
                        _pointMode = false;
                      }),
              ),
            ),
          ),
        if (lashes)
          _strip(
            styles.indexed.map((item) {
              final (index, label) = item;
              return _styleCard(
                label: label,
                selected: effect.amount > 0 && effect.style == index,
                illustration: MakeupStyleIllustration(
                  lashStyle: index,
                  lashesOnly: true,
                ),
                onTap: () => _setLayer(
                  effect.copyWith(
                    style: index,
                    amount: effect.amount > 0 ? effect.amount : .60,
                  ),
                ),
              );
            }),
          )
        else if (styles.length > 1)
          _strip(
            styles.indexed.map((item) {
              final (index, label) = item;
              return ChoiceChip(
                label: Text(label),
                selected: effect.amount > 0 && effect.style == index,
                onSelected: _blocked
                    ? null
                    : (_) => _setLayer(
                        effect.copyWith(
                          style: index,
                          amount: effect.amount > 0 ? effect.amount : .5,
                        ),
                      ),
              );
            }),
          ),
        if (!shape && _part.palette.length > 1)
          MakeupShadePicker(
            part: _part,
            selectedColor: effect.amount > 0 ? effect.color : null,
            onSelect: _blocked
                ? null
                : (color) => _setLayer(
                    effect.copyWith(
                      color: color,
                      amount: effect.amount > 0 ? effect.amount : .5,
                    ),
                  ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13),
          child: Row(
            children: [
              Text(shape ? '幅度' : '薄厚'),
              Expanded(
                child: Slider(
                  key: ValueKey(('makeup-strength', _part)),
                  value: effect.amount,
                  onChangeStart: _blocked
                      ? null
                      : (_) => _sliderStart = (_design, _selectedPreset),
                  onChanged: _blocked
                      ? null
                      : (value) => setState(() {
                          _design = _design.setLayer(
                            _part,
                            effect.copyWith(amount: value),
                          );
                          _selectedPreset = null;
                          _original = false;
                        }),
                  onChangeEnd: _blocked
                      ? null
                      : (_) {
                          final original = _sliderStart;
                          _sliderStart = null;
                          if (original != null &&
                              original.$1.layer(_part).amount !=
                                  _design.layer(_part).amount) {
                            setState(() => _remember(original));
                          }
                        },
                ),
              ),
              Text('${(effect.amount * 100).round()}%'),
            ],
          ),
        ),
        if (hasPoints)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: _blocked
                      ? null
                      : () => setState(() {
                          _pointMode = !_pointMode;
                          _original = false;
                        }),
                  icon: Icon(
                    _pointMode ? Icons.check : Icons.control_camera_outlined,
                    size: 18,
                  ),
                  label: Text(_pointMode ? '完成调点' : '多点微调'),
                ),
                if (_pointMode)
                  TextButton(
                    onPressed: _blocked
                        ? null
                        : () => _apply(_design.resetPoints(_part)),
                    child: const Text('恢复定位'),
                  ),
                if (effect.amount > 0)
                  TextButton(
                    onPressed: _blocked
                        ? null
                        : () => _setLayer(effect.copyWith(amount: 0)),
                    child: const Text('卸除本项'),
                  ),
              ],
            ),
          ),
        if (_pointMode)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Text(
              '拖动圆点微调位置，双指缩放画面。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  void _setLayer(MakeupLayer layer) => _apply(_design.setLayer(_part, layer));

  Widget _styleCard({
    required String label,
    required bool selected,
    required Widget illustration,
    required VoidCallback onTap,
  }) {
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
        button: true,
        selected: selected,
        child: InkWell(
          onTap: _blocked ? null : onTap,
          child: SizedBox(
            width: 82,
            child: Padding(
              padding: const EdgeInsets.all(5),
              child: Column(
                children: [
                  SizedBox(
                    height: 42,
                    width: double.infinity,
                    child: illustration,
                  ),
                  const SizedBox(height: 3),
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
}

class _MakeupPreviewPainter extends CustomPainter {
  const _MakeupPreviewPainter(this.photo, this.design, this.rect);

  final MakeupPhoto photo;
  final MakeupDesign? design;
  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    if (rect.isEmpty) return;
    if (design case final design?) {
      paintMakeup(canvas, rect, photo, design);
    } else {
      canvas.drawImageRect(
        photo.image,
        Rect.fromLTWH(
          0,
          0,
          photo.image.width.toDouble(),
          photo.image.height.toDouble(),
        ),
        rect,
        Paint()..filterQuality = FilterQuality.medium,
      );
    }
  }

  @override
  bool shouldRepaint(_MakeupPreviewPainter oldDelegate) =>
      oldDelegate.photo != photo ||
      oldDelegate.design != design ||
      oldDelegate.rect != rect;
}

class _MakeupPointPainter extends CustomPainter {
  const _MakeupPointPainter(this.points);

  final List<Offset> points;

  @override
  void paint(Canvas canvas, Size size) {
    final border = Paint()..color = const Color(0xFF7C3A53);
    final fill = Paint()..color = Colors.white;
    for (final point in points) {
      canvas.drawCircle(point, 5.5, border);
      canvas.drawCircle(point, 3.5, fill);
    }
  }

  @override
  bool shouldRepaint(_MakeupPointPainter oldDelegate) =>
      oldDelegate.points != points;
}
