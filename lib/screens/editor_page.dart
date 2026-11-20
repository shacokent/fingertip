import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/nail_models.dart';
import '../models/diy_models.dart';
import '../services/diy_library.dart';
import '../services/nail_favorites.dart';
import '../services/nail_mask_edit.dart';
import '../services/nail_renderer.dart';
import '../widgets/inline_style_browser.dart';
import '../widgets/nail_plan_rail.dart';
import '../widgets/photo_viewport.dart';
import 'diy_studio_page.dart';

class EditorPage extends StatefulWidget {
  const EditorPage({
    super.key,
    required this.analysis,
    this.library,
    this.favorites,
    this.diyImagePicker,
    this.refitNail,
  });
  final AnalysisResult analysis;
  final DiyLibrary? library;
  final NailFavorites? favorites;
  final Future<String?> Function()? diyImagePicker;
  final Future<NailRegion> Function(NailRegion current)? refitNail;
  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _TryOnLook {
  const _TryOnLook({
    required this.styles,
    required this.coatAmounts,
    required this.handCoatAmount,
    required this.gloss,
    required this.lightDirection,
    required this.currentStyle,
  });

  final Map<int, NailStyle> styles;
  final Map<int, double> coatAmounts;
  final double handCoatAmount;
  final double gloss;
  final double lightDirection;
  final NailStyle currentStyle;

  _TryOnLook replaceStyle(String id, NailStyle replacement) => _TryOnLook(
    styles: {
      for (final entry in styles.entries)
        entry.key: entry.value.id == id ? replacement : entry.value,
    },
    coatAmounts: coatAmounts,
    handCoatAmount: handCoatAmount,
    gloss: gloss,
    lightDirection: lightDirection,
    currentStyle: currentStyle.id == id ? replacement : currentStyle,
  );
}

typedef _TryOnPlan = ({String name, _TryOnLook look});

enum _EditorTool { styles, finish, edges }

class _Snapshot {
  _Snapshot(
    List<NailRegion> nails,
    Set<int> confirmedEdges,
    Map<int, _TryOnPlan> plans,
    this.activePlanId,
  ) : nails = List.of(nails),
      confirmedEdges = Set.of(confirmedEdges),
      plans = Map.of(plans);

  final List<NailRegion> nails;
  final Set<int> confirmedEdges;
  final Map<int, _TryOnPlan> plans;
  final int activePlanId;
}

class _EditorPageState extends State<EditorPage> {
  NailRenderer? _renderer;
  late List<NailRegion> _nails;
  Map<int, NailStyle> _styles = {};
  Map<int, double> _coatAmounts = {};
  final _history = <_Snapshot>[];
  late Map<int, _TryOnPlan> _plans;
  int _activePlanId = 1, _nextPlanId = 2;
  Set<int> _confirmedEdges = {};
  late final DiyLibrary _library;
  final _photoTransform = TransformationController();
  final _toolsScroll = ScrollController();
  Size? _photoViewportSize;
  List<DiySavedStyle> _customStyles = [];
  NailStyle _currentStyle = NailStyle.all.first;
  int? _selected;
  int? _originalPreviewPointer;
  int _nextId = 100;
  _EditorTool _tool = _EditorTool.styles;
  bool _all = true,
      _adding = false,
      _saving = false,
      _fitting = false,
      _refine = false,
      _restoring = false,
      _deleting = false,
      _styleLoading = false;
  int _styleGeneration = 0, _fitGeneration = 0, _maskGeneration = 0;
  int _libraryGeneration = 0;
  NailRegion? _maskBase;
  List<Offset> _contourPoints = [];
  double _edgeExpansion = 0, _edgeFeather = .35;
  double _handCoatAmount = defaultNailCoatAmount;
  (bool, int?)? _coatGestureScope;
  bool _coatUndoRecorded = false;
  double _gloss = .65;
  double _lightDirection = defaultNailLightDirection;
  String? _loadError;

  bool get _editingLocked => _restoring || _saving || _deleting;
  bool get _saveBlocked =>
      _renderer == null || _editingLocked || _fitting || _styleLoading;
  bool get _planBlocked => _saveBlocked || _adding;
  bool get _adjust => _tool == _EditorTool.edges;
  bool get _original => _originalPreviewPointer != null;

  NailRegion? get _selectedNail =>
      _nails.where((n) => n.id == _selected).firstOrNull;

  NailEdgeReviewReason? _edgeReviewReason(NailRegion nail) =>
      _confirmedEdges.contains(nail.id)
      ? null
      : widget.analysis.edgeReviewById[nail.id];

  double get _activeCoatAmount =>
      _all ? _handCoatAmount : (_coatAmounts[_selected] ?? _handCoatAmount);

  bool get _canChangeCoatAmount =>
      _renderer != null &&
      !_editingLocked &&
      !_fitting &&
      (_all
          ? _nails.any((nail) => nail.enabled)
          : _selectedNail?.enabled == true);

  @override
  void initState() {
    super.initState();
    _library = widget.library ?? DiyLibrary();
    _nails = List.of(widget.analysis.nails);
    _styles = {for (final nail in _nails) nail.id: _currentStyle};
    _plans = {1: (name: '方案 1', look: _captureLook())};
    _load();
    unawaited(_loadDiyLibrary());
  }

  Future<void> _load() async {
    NailRenderer? renderer;
    try {
      final codec = await ui.instantiateImageCodec(widget.analysis.pngBytes);
      final photo = (await codec.getNextFrame()).image;
      codec.dispose();
      final program = await ui.FragmentProgram.fromAsset('shaders/nail.frag');
      renderer = NailRenderer(photo, program);
      for (final nail in _nails) {
        await renderer.addMask(nail);
      }
      if (!mounted) {
        renderer.dispose();
        return;
      }
      setState(() => _renderer = renderer);
    } catch (e) {
      renderer?.dispose();
      if (mounted) setState(() => _loadError = '试戴画面暂时无法加载，请返回后重试。');
    }
  }

  void _remember() {
    if (_editingLocked) return;
    _record(_Snapshot(_nails, _confirmedEdges, _capturePlans(), _activePlanId));
  }

  void _record(_Snapshot snapshot) {
    _history.add(snapshot);
    if (_history.length > 30) _history.removeAt(0);
  }

  Map<int, _TryOnPlan> _capturePlans() => {
    ..._plans,
    _activePlanId: (name: _plans[_activePlanId]!.name, look: _captureLook()),
  };

  _TryOnLook _captureLook() => _TryOnLook(
    styles: Map.of(_styles),
    coatAmounts: Map.of(_coatAmounts),
    handCoatAmount: _handCoatAmount,
    gloss: _gloss,
    lightDirection: _lightDirection,
    currentStyle: _currentStyle,
  );

  void _applyLook(_TryOnLook look, {bool matchSelectedNail = false}) {
    _styles = {
      for (final nail in _nails)
        nail.id: look.styles[nail.id] ?? look.currentStyle,
    };
    _coatAmounts = {
      for (final nail in _nails)
        if (look.coatAmounts.containsKey(nail.id) ||
            look.handCoatAmount != defaultNailCoatAmount)
          nail.id: look.coatAmounts[nail.id] ?? look.handCoatAmount,
    };
    _handCoatAmount = look.handCoatAmount;
    _gloss = look.gloss;
    _lightDirection = look.lightDirection;
    _currentStyle = matchSelectedNail && !_all
        ? _styles[_selected] ?? look.currentStyle
        : look.currentStyle;
  }

  void _addPlan() {
    if (_planBlocked) return;
    final id = _nextPlanId++;
    _remember();
    setState(() {
      _plans = {..._capturePlans(), id: (name: '方案 $id', look: _captureLook())};
      _activePlanId = id;
      _coatGestureScope = null;
    });
  }

  Future<void> _switchPlan(int id, {bool removeCurrent = false}) async {
    final target = _plans[id];
    if (_planBlocked || target == null || id == _activePlanId) return;
    final plans = _capturePlans();
    final previous = _activePlanId;
    final snapshot = removeCurrent
        ? _Snapshot(_nails, _confirmedEdges, plans, previous)
        : null;
    setState(() => _restoring = true);
    try {
      await _prepareLook(target.look, _nails);
      if (!mounted) return;
      setState(() {
        if (snapshot != null) {
          _record(snapshot);
          plans.remove(previous);
        }
        _plans = plans;
        _activePlanId = id;
        _applyLook(target.look, matchSelectedNail: true);
        _coatGestureScope = null;
      });
    } catch (_) {
      if (mounted) _message('该方案的款式图片暂时无法读取。');
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  Future<void> _prepareLook(_TryOnLook look, List<NailRegion> nails) async {
    await _renderer?.prepareStyles([
      for (final nail in nails) look.styles[nail.id] ?? look.currentStyle,
      look.currentStyle,
    ]);
  }

  Future<void> _renamePlan() async {
    if (_planBlocked) return;
    final id = _activePlanId;
    final previousName = _plans[id]!.name;
    var name = previousName;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名方案'),
        content: TextFormField(
          key: const ValueKey('nail-plan-name'),
          initialValue: previousName,
          autofocus: true,
          maxLength: 24,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(labelText: '方案名称'),
          onChanged: (value) => name = value,
          onFieldSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, name.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (!mounted ||
        _planBlocked ||
        _activePlanId != id ||
        result == null ||
        result.isEmpty ||
        result == previousName) {
      return;
    }
    _remember();
    setState(() {
      _plans = {..._plans, id: (name: result, look: _captureLook())};
    });
  }

  Future<void> _deletePlan() async {
    if (_planBlocked || _plans.length < 2) return;
    final ids = _plans.keys.toList();
    final index = ids.indexOf(_activePlanId);
    await _switchPlan(ids[index == 0 ? 1 : index - 1], removeCurrent: true);
  }

  void _replacePlanStyle(String id, NailStyle replacement) {
    _plans = {
      for (final entry in _capturePlans().entries)
        entry.key: (
          name: entry.value.name,
          look: entry.value.look.replaceStyle(id, replacement),
        ),
    };
    _applyLook(_plans[_activePlanId]!.look, matchSelectedNail: true);
  }

  Future<void> _undo() async {
    if (_history.isEmpty || _editingLocked || _fitting) return;
    final snapshot = _history.last;
    _maskGeneration++;
    _styleGeneration++;
    setState(() {
      _restoring = true;
      _styleLoading = false;
    });
    try {
      final look = snapshot.plans[snapshot.activePlanId]!.look;
      await _prepareLook(look, snapshot.nails);
      for (final nail in snapshot.nails) {
        await _renderer?.addMask(nail);
      }
      if (!mounted) return;
      setState(() {
        _history.removeLast();
        _nails = List.of(snapshot.nails);
        _confirmedEdges = Set.of(snapshot.confirmedEdges);
        _plans = Map.of(snapshot.plans);
        _activePlanId = snapshot.activePlanId;
        _applyLook(look);
        _coatGestureScope = null;
        if (!_nails.any((n) => n.id == _selected)) {
          _selected = null;
          _refine = false;
        }
        _resetMaskEditing(_selectedNail);
      });
    } catch (_) {
      if (mounted) _message('这次撤销未完成，请再试一次。');
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  Future<void> _chooseStyle(NailStyle style) async {
    if (_renderer == null || _editingLocked || _fitting) return;
    if (!_all && _selected == null) {
      _message('先点选照片中的一片甲面');
      return;
    }
    final generation = ++_styleGeneration;
    final all = _all, selected = _selected;
    setState(() => _styleLoading = true);
    try {
      await _renderer!.prepareStyle(style);
      if (!mounted ||
          generation != _styleGeneration ||
          all != _all ||
          selected != _selected ||
          _editingLocked ||
          _fitting) {
        return;
      }
      _remember();
      setState(() {
        _currentStyle = style;
        _styles = Map.of(_styles);
        for (final nail in _nails) {
          if (_all || nail.id == _selected) _styles[nail.id] = style;
        }
      });
    } catch (_) {
      if (mounted) _message('这款图片暂时无法读取，请编辑后重新保存。');
    } finally {
      if (mounted && generation == _styleGeneration) {
        setState(() => _styleLoading = false);
      }
    }
  }

  Future<void> _loadDiyLibrary() async {
    final generation = ++_libraryGeneration;
    try {
      final styles = await _library.load();
      if (!mounted || generation != _libraryGeneration) return;
      setState(() => _customStyles = styles);
    } catch (_) {
      if (mounted) _message('自建款式暂时无法读取，请稍后再试。');
    }
  }

  Future<void> _openDiy([DiySavedStyle? initial]) async {
    if (_editingLocked || _fitting || _renderer == null) return;
    _styleGeneration++;
    setState(() => _styleLoading = false);
    final saved = await Navigator.of(context).push<DiySavedStyle>(
      MaterialPageRoute(
        builder: (_) => DiyStudioPage(
          initial: initial,
          library: _library,
          pickImage: widget.diyImagePicker,
        ),
      ),
    );
    if (!mounted || saved == null) return;
    final generation = ++_styleGeneration;
    final all = _all, selected = _selected;
    setState(() => _styleLoading = true);
    try {
      await _loadDiyLibrary();
      if (!mounted) return;
      await _renderer?.prepareStyle(saved.style);
      if (!mounted || generation != _styleGeneration || _editingLocked) return;
      if (initial != null) {
        setState(() {
          _replacePlanStyle(saved.id, saved.style);
          // Old image revisions can be removed by library maintenance.
          _history.clear();
        });
      }
      if (generation == _styleGeneration &&
          all == _all &&
          selected == _selected) {
        await _chooseStyle(saved.style);
      }
    } catch (_) {
      if (mounted) _message('款式已保存，试戴图片暂时无法加载，请重新选择。');
    } finally {
      if (mounted && generation == _styleGeneration) {
        setState(() => _styleLoading = false);
      }
    }
  }

  Future<void> _deleteDiy(DiySavedStyle saved) async {
    if (_editingLocked || _fitting) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除自建款式？'),
        content: Text('“${saved.name}”将从我的DIY中删除，已导出的效果图会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _editingLocked || _fitting) return;
    _libraryGeneration++;
    _styleGeneration++;
    setState(() {
      _styleLoading = false;
      _deleting = true;
    });
    try {
      await _library.delete(saved.id);
      if (!mounted) return;
      final fallback = NailStyle.all.first;
      setState(() {
        _customStyles = _customStyles.where((s) => s.id != saved.id).toList();
        _replacePlanStyle(saved.id, fallback);
        _styleLoading = false;
        _history.clear();
      });
    } catch (_) {
      if (mounted) _message('删除未完成，请稍后重试。');
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Future<void> _tapPhoto(Offset point) async {
    if (_editingLocked || _fitting) return;
    if (_adding) {
      final renderer = _renderer;
      if (renderer == null) return;
      final generation = ++_fitGeneration;
      setState(() => _fitting = true);
      try {
        final nail = await fitManualNail(
          pngBytes: widget.analysis.pngBytes,
          id: _nextId++,
          center: point,
          imageWidth: widget.analysis.width,
          imageHeight: widget.analysis.height,
        );
        await renderer.addMask(nail);
        if (!mounted || generation != _fitGeneration) return;
        _remember();
        setState(() {
          _nails = [..._nails, nail];
          _styles = {..._styles, nail.id: _currentStyle};
          _coatAmounts = {..._coatAmounts, nail.id: _handCoatAmount};
          _selected = nail.id;
          _adding = false;
          _tool = _EditorTool.edges;
          _all = false;
          _refine = true;
          _resetMaskEditing(nail);
        });
        _message(
          nail.label == '局部贴合'
              ? '已按附近甲面贴合，可继续拖动控制点修边。'
              : '已添加可调甲面，请拖动控制点贴合真实甲缘。',
        );
      } catch (_) {
        if (mounted) _message('暂时无法补选，请重新点一下甲面中心。');
      } finally {
        if (mounted && generation == _fitGeneration) {
          setState(() => _fitting = false);
        }
      }
      return;
    }
    final hit = _nails.reversed
        .where((n) => n.enabled && n.contains(point))
        .firstOrNull;
    setState(() {
      _selected = hit?.id;
      if (hit != null) {
        _all = false;
        _currentStyle = _styles[hit.id] ?? _currentStyle;
      }
      _maskGeneration++;
      _resetMaskEditing(hit);
    });
  }

  void _confirmEdge(NailRegion nail) {
    if (_editingLocked || _fitting || _edgeReviewReason(nail) == null) return;
    _remember();
    setState(() {
      _confirmedEdges = {..._confirmedEdges, nail.id};
      _tool = _EditorTool.styles;
      _refine = false;
    });
    _resetPhotoZoom();
    _resetToolsScroll();
  }

  void _resetMaskEditing(NailRegion? nail) {
    _maskBase = nail;
    _contourPoints = nail == null ? [] : contourFromMask(nail);
    _edgeExpansion = 0;
    _edgeFeather = .35;
  }

  Future<void> _replaceMask(
    NailRegion nail, {
    bool updateContour = false,
  }) async {
    if (!mounted || _selected != nail.id || _editingLocked || _fitting) return;
    final generation = ++_maskGeneration;
    final before = _selectedNail;
    // Publish geometry before the asynchronous upload, so moving to another
    // nail cannot leave the cache and the current region referring to different
    // masks. The renderer drops superseded uploads for the same region ID.
    setState(() {
      _nails = _nails.map((n) => n.id == nail.id ? nail : n).toList();
      if (updateContour) _contourPoints = contourFromMask(nail);
    });
    try {
      await _renderer?.addMask(nail);
      if (mounted && generation == _maskGeneration) setState(() {});
    } catch (_) {
      if (!mounted || generation != _maskGeneration) return;
      if (before != null) {
        setState(() {
          _nails = _nails.map((n) => n.id == before.id ? before : n).toList();
        });
      }
      _message('边缘暂时无法更新，请再试一次。');
    }
  }

  void _tuneEdge() {
    if (_editingLocked || _fitting) return;
    final base = _maskBase;
    if (base == null) return;
    unawaited(
      _replaceMask(
        tuneMask(base, expansion: _edgeExpansion, feather: _edgeFeather),
        updateContour: true,
      ),
    );
  }

  Future<void> _refitSelected() async {
    final old = _selectedNail;
    if (old == null || _editingLocked || _fitting) return;
    final generation = ++_fitGeneration;
    setState(() => _fitting = true);
    try {
      final fitted = widget.refitNail != null
          ? await widget.refitNail!(old)
          : await fitManualNail(
              pngBytes: widget.analysis.pngBytes,
              id: old.id,
              center: old.center,
              imageWidth: widget.analysis.width,
              imageHeight: widget.analysis.height,
            );
      if (!mounted || generation != _fitGeneration || _selected != old.id) {
        return;
      }
      if (fitted.label == '手动甲面') {
        _message('没有找到可靠的新甲缘，已保留当前角度和轮廓，可继续手动修边。');
        return;
      }
      final nail = preserveRefitOrientation(fitted, old);
      _remember();
      setState(() {
        _nails = _nails.map((n) => n.id == old.id ? nail : n).toList();
        _confirmedEdges = Set.of(_confirmedEdges)..remove(old.id);
        _refine = true;
        _resetMaskEditing(nail);
      });
      await _renderer?.addMask(nail);
      if (mounted) {
        setState(() {});
        _message('甲缘已更新，保留了您调整的角度和位置。');
      }
    } catch (_) {
      if (mounted) _message('暂时无法重新贴合，可拖动控制点手动修边。');
    } finally {
      if (mounted && generation == _fitGeneration) {
        setState(() => _fitting = false);
      }
    }
  }

  void _updateSelected(NailRegion Function(NailRegion) update) {
    if (_editingLocked || _fitting) return;
    final selected = _selectedNail;
    if (selected == null) return;
    setState(
      () => _nails = _nails
          .map((n) => n.id == selected.id ? update(n) : n)
          .toList(),
    );
  }

  void _changeCoatAmount(double value) {
    if (!_canChangeCoatAmount ||
        _coatGestureScope != (_all, _selected) ||
        value == _activeCoatAmount) {
      return;
    }
    if (!_coatUndoRecorded) {
      _remember();
      _coatUndoRecorded = true;
    }
    final selected = _selected;
    if (_all) {
      setState(() {
        _handCoatAmount = value;
        _coatAmounts = {for (final nail in _nails) nail.id: value};
      });
    } else if (selected != null) {
      setState(() => _coatAmounts = {..._coatAmounts, selected: value});
    }
  }

  Future<void> _save({bool share = false}) async {
    final renderer = _renderer;
    if (renderer == null || _saveBlocked) return;
    if (!_nails.any((n) => n.enabled)) {
      _message('请先识别或添加一片甲面');
      return;
    }
    setState(() => _saving = true);
    ui.Image? output;
    try {
      output = await renderer.export(
        _nails,
        _styles,
        _gloss,
        coatAmounts: _coatAmounts,
        lightDirection: _lightDirection,
      );
      final data = await output.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('图片编码失败');
      final dir = await getApplicationDocumentsDirectory();
      final folder = Directory('${dir.path}/NailStudio');
      await folder.create(recursive: true);
      final file = File(
        '${folder.path}/nail_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(data.buffer.asUint8List());
      if (!mounted) return;
      if (share) {
        final box = context.findRenderObject() as RenderBox?;
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path, mimeType: 'image/png')],
            sharePositionOrigin: box == null
                ? null
                : box.localToGlobal(Offset.zero) & box.size,
          ),
        );
      } else {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('效果图已保存'),
            content: Text(
              '已保存至 App 本地文件，图片最长边为 1600 像素。\n\n${file.path}\n\n点击“导出”可通过系统分享保存到其他位置。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('知道了'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) _message('导出失败，请重试：$e');
    } finally {
      output?.dispose();
      if (mounted) setState(() => _saving = false);
    }
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  void _holdOriginalPreview(PointerDownEvent event) {
    if (_originalPreviewPointer != null ||
        (event.buttons & kPrimaryButton) == 0) {
      return;
    }
    setState(() => _originalPreviewPointer = event.pointer);
  }

  void _releaseOriginalPreview(PointerEvent event) {
    if (mounted && _originalPreviewPointer == event.pointer) {
      setState(() => _originalPreviewPointer = null);
    }
  }

  @override
  void dispose() {
    _styleGeneration++;
    _maskGeneration++;
    _fitGeneration++;
    _libraryGeneration++;
    _photoTransform.dispose();
    _toolsScroll.dispose();
    _renderer?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final renderer = _renderer;
    final count = _nails.where((n) => n.enabled).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的试戴'),
        actions: [
          IconButton(
            tooltip: '撤销',
            onPressed: _history.isEmpty || _editingLocked || _fitting
                ? null
                : _undo,
            icon: const Icon(Icons.undo_rounded),
          ),
          PopupMenuButton<bool>(
            tooltip: '保存或导出',
            enabled: !_saveBlocked,
            icon: const Icon(Icons.ios_share_rounded),
            onSelected: (share) => _save(share: share),
            itemBuilder: (_) => const [
              PopupMenuItem(value: false, child: Text('保存到本机')),
              PopupMenuItem(value: true, child: Text('导出')),
            ],
          ),
        ],
      ),
      body: AbsorbPointer(
        key: const ValueKey('editor-operation-lock'),
        absorbing: _editingLocked,
        child: SafeArea(
          top: false,
          child: _fitEditor(
            photo: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: const Color(0xFFE9E4E1),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: LayoutBuilder(
                      builder: (context, box) {
                        _photoViewportSize = box.biggest;
                        final photoSize = Size(
                          widget.analysis.width.toDouble(),
                          widget.analysis.height.toDouble(),
                        );
                        final fitted = applyBoxFit(
                          BoxFit.contain,
                          photoSize,
                          box.biggest,
                        ).destination;
                        final photoOrigin = Offset(
                          (box.maxWidth - fitted.width) / 2,
                          (box.maxHeight - fitted.height) / 2,
                        );
                        final photoScale = photoSize.width / fitted.width;
                        final photoScene = renderer == null
                            ? Center(
                                child: _loadError == null
                                    ? const CircularProgressIndicator()
                                    : Padding(
                                        padding: const EdgeInsets.all(24),
                                        child: Text(_loadError!),
                                      ),
                              )
                            : NailScene(
                                renderer: renderer,
                                nails: _nails,
                                styles: _styles,
                                gloss: _gloss,
                                coatAmounts: _coatAmounts,
                                lightDirection: _lightDirection,
                                original: _original,
                                outlines: _adjust && !_refine,
                                selectedId: _selected,
                              );
                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            PhotoViewport(
                              controller: _photoTransform,
                              enabled:
                                  renderer != null &&
                                  !_editingLocked &&
                                  !_fitting,
                              interactionBounds: photoOrigin & fitted,
                              onTap: (point) =>
                                  _tapPhoto((point - photoOrigin) * photoScale),
                              onSceneDragStart: _remember,
                              onSceneDrag:
                                  _adjust &&
                                      !_refine &&
                                      _selected != null &&
                                      !_adding
                                  ? (delta) => _updateSelected(
                                      (n) => n.copyWith(
                                        center: Offset(
                                          (n.center.dx + delta.dx * photoScale)
                                              .clamp(0.0, photoSize.width),
                                          (n.center.dy + delta.dy * photoScale)
                                              .clamp(0.0, photoSize.height),
                                        ),
                                      ),
                                    )
                                  : null,
                              child: photoScene,
                            ),
                            if (renderer != null &&
                                _adjust &&
                                _refine &&
                                !_original &&
                                _selectedNail != null)
                              _contourOverlay(_selectedNail!, box.biggest),
                          ],
                        );
                      },
                    ),
                  ),
                  if (_original)
                    Positioned(top: 12, left: 12, child: _tag('原始照片')),
                  Positioned(
                    key: const ValueKey('hold-original-preview'),
                    bottom: 12,
                    right: 12,
                    child: Listener(
                      onPointerDown: _holdOriginalPreview,
                      onPointerUp: _releaseOriginalPreview,
                      onPointerCancel: _releaseOriginalPreview,
                      child: Semantics(
                        label: '按住查看原图',
                        button: true,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 11,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: .93),
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.compare_rounded, size: 17),
                              SizedBox(width: 6),
                              Text('按住看原图'),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_fitting && !_adding)
                    Positioned(left: 12, bottom: 64, child: _tag('正在重新贴合甲面…')),
                  Positioned(
                    right: 8,
                    top: 6,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_adjust && _refine) ...[
                          IconButton.filledTonal(
                            tooltip: '放大修边',
                            onPressed: _focusSelected,
                            icon: const Icon(Icons.zoom_in_rounded),
                          ),
                          const SizedBox(width: 4),
                        ],
                        IconButton.filledTonal(
                          tooltip: '查看全图',
                          key: const ValueKey('reset-photo-view'),
                          onPressed: _resetPhotoZoom,
                          icon: const Icon(Icons.fit_screen_rounded),
                        ),
                      ],
                    ),
                  ),
                  if (_adding)
                    Positioned(
                      left: 12,
                      bottom: 64,
                      right: 12,
                      child: _tag(_fitting ? '正在贴合附近甲面…' : '点一下漏掉的指甲中心，再拖点修边'),
                    ),
                ],
              ),
            ),
            plans: NailPlanRail(
              plans: {
                for (final entry in _plans.entries) entry.key: entry.value.name,
              },
              activeId: _activePlanId,
              enabled: !_planBlocked && count > 0,
              onAdd: _addPlan,
              onSelect: _switchPlan,
              onRename: _renamePlan,
              onDelete: _plans.length > 1 ? _deletePlan : null,
            ),
            tools: _toolPanel(count),
          ),
        ),
      ),
    );
  }

  Widget _fitEditor({
    required Widget photo,
    required Widget plans,
    required Widget tools,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      final scroll = SingleChildScrollView(
        key: const ValueKey('editor-compact-scroll'),
        controller: _toolsScroll,
        padding: const EdgeInsets.only(bottom: 6),
        child: tools,
      );
      final tabs = _toolBar();
      if (constraints.maxHeight < 450 &&
          constraints.maxWidth > constraints.maxHeight * 1.4) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(flex: 6, child: photo),
            Expanded(
              flex: 5,
              child: Column(
                children: [
                  plans,
                  tabs,
                  Expanded(child: scroll),
                ],
              ),
            ),
          ],
        );
      }
      return Column(
        children: [
          Expanded(child: photo),
          plans,
          tabs,
          SizedBox(
            height: math.min(228, constraints.maxHeight * .36),
            child: scroll,
          ),
        ],
      );
    },
  );

  void _setTool(_EditorTool tool) {
    if (_tool == tool || _editingLocked || _fitting) return;
    setState(() {
      _tool = tool;
      _adding = false;
      _refine = false;
      _coatGestureScope = null;
    });
    _resetToolsScroll();
  }

  void _resetToolsScroll() {
    if (_toolsScroll.hasClients) _toolsScroll.jumpTo(0);
  }

  Widget _toolBar() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
    child: Row(
      children: [
        for (final (tool, name, tooltip) in [
          (_EditorTool.styles, '款式', '选择款式'),
          (_EditorTool.finish, '效果', '调整效果'),
          (_EditorTool.edges, '甲缘', '微调甲面'),
        ])
          Expanded(
            child: Tooltip(
              message: tooltip,
              child: Semantics(
                selected: tool == _tool,
                child: TextButton(
                  key: ValueKey('nail-tool-${tool.name}'),
                  onPressed: _fitting ? null : () => _setTool(tool),
                  style: TextButton.styleFrom(
                    backgroundColor: tool == _tool
                        ? const Color(0xFFF0E1E7)
                        : Colors.transparent,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    minimumSize: const Size(0, 42),
                  ),
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _toolPanel(int count) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (count == 0 || widget.analysis.notice != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
          child: Text(
            count == 0 ? '可在「甲缘」里点「补选」，添加漏掉的指甲。' : widget.analysis.notice!,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      if (!_adjust) _scopeControls(),
      switch (_tool) {
        _EditorTool.styles => _stylePanel(),
        _EditorTool.finish => _finishPanel(),
        _EditorTool.edges => _edgeTools(),
      },
    ],
  );

  Widget _scopeControls() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Row(
      children: [
        ChoiceChip(
          label: const Text('整手'),
          selected: _all,
          onSelected: (_) => setState(() {
            _all = true;
            _selected = null;
          }),
          visualDensity: VisualDensity.compact,
        ),
        const SizedBox(width: 6),
        ChoiceChip(
          label: const Text('单指'),
          selected: !_all,
          onSelected: (_) {
            setState(() => _all = false);
            if (_selected == null) _message('点选照片中的甲面，再换款或调厚薄');
          },
          visualDensity: VisualDensity.compact,
        ),
      ],
    ),
  );

  Widget _edgeTools() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextButton.icon(
            onPressed: _renderer == null
                ? null
                : () => setState(() {
                    _adding = !_adding;
                    _fitGeneration++;
                    _fitting = false;
                    _refine = false;
                  }),
            icon: Icon(_adding ? Icons.close : Icons.add_circle_outline),
            label: Text(_adding ? '取消补选' : '补选'),
          ),
        ),
      ),
      _adjustmentPanel(),
    ],
  );

  Widget _tag(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .94),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Text(
      text,
      style: const TextStyle(fontSize: 12, color: Color(0xFF51414A)),
    ),
  );

  Widget _stylePanel() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (_styleLoading) const LinearProgressIndicator(minHeight: 2),
      InlineStyleBrowser(
        selectedStyle: _currentStyle,
        customStyles: _customStyles,
        favorites: widget.favorites,
        enabled: _renderer != null && !_editingLocked && !_fitting,
        onSelected: _chooseStyle,
        onCreateDiy: () => _openDiy(),
        onEditDiy: (style) => _openDiy(style),
        onDeleteDiy: _deleteDiy,
      ),
    ],
  );

  Widget _finishPanel() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            const Text('薄涂', style: TextStyle(fontSize: 12)),
            Expanded(
              child: Semantics(
                label: '涂层厚薄',
                child: Slider(
                  key: const ValueKey('nail-coat-amount'),
                  max: 2,
                  value: _activeCoatAmount,
                  onChangeStart: (_) {
                    _coatGestureScope = (_all, _selected);
                    _coatUndoRecorded = false;
                  },
                  onChangeEnd: (_) => _coatGestureScope = null,
                  onChanged: _canChangeCoatAmount ? _changeCoatAmount : null,
                ),
              ),
            ),
            const Text('厚涂', style: TextStyle(fontSize: 12)),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            const Text('光泽', style: TextStyle(fontSize: 12)),
            Expanded(
              child: Slider(
                key: const ValueKey('nail-gloss'),
                value: _gloss,
                onChangeStart: (_) => _remember(),
                onChanged: (value) {
                  if (_editingLocked || _fitting) return;
                  setState(() => _gloss = value);
                },
              ),
            ),
            const Text('亮面', style: TextStyle(fontSize: 12)),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
        child: Row(
          children: [
            const Text('灯光', style: TextStyle(fontSize: 12)),
            Expanded(
              child: Slider(
                key: const ValueKey('light-direction'),
                min: -math.pi,
                max: math.pi,
                value: _lightDirection,
                label: _lightDirectionLabel,
                onChangeStart: (_) => _remember(),
                onChanged: _renderer == null || _editingLocked || _fitting
                    ? null
                    : (value) => setState(() => _lightDirection = value),
              ),
            ),
            Semantics(
              label: '灯光来自$_lightDirectionLabel方',
              child: SizedBox(
                width: 52,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Transform.rotate(
                      angle: _lightDirection + math.pi / 2,
                      child: const Icon(Icons.north_rounded, size: 18),
                    ),
                    Flexible(
                      child: Text(
                        _lightDirectionLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ],
  );

  String get _lightDirectionLabel {
    const labels = ['右', '右下', '下', '左下', '左', '左上', '上', '右上'];
    final index = (_lightDirection / (math.pi / 4)).round() % 8;
    return labels[index];
  }

  void _resetPhotoZoom() {
    _photoTransform.value = Matrix4.identity();
  }

  void _focusSelected() {
    if (_editingLocked || _fitting) return;
    final nail = _selectedNail;
    final viewport = _photoViewportSize;
    if (nail == null || viewport == null) return;
    final natural = Size(
      widget.analysis.width.toDouble(),
      widget.analysis.height.toDouble(),
    );
    final fitted = applyBoxFit(BoxFit.contain, natural, viewport).destination;
    final scale = fitted.width / natural.width;
    final origin = Offset(
      (viewport.width - fitted.width) / 2,
      (viewport.height - fitted.height) / 2,
    );
    final target = origin + nail.center * scale;
    final zoom =
        (viewport.shortestSide /
                (math.max(nail.width, nail.height) * scale * 1.7))
            .clamp(1.5, 7.0);
    final current = _photoTransform.value;
    final rotation = math.atan2(current.entry(1, 0), current.entry(0, 0));
    _photoTransform.value = Matrix4.identity()
      ..translateByDouble(viewport.width / 2, viewport.height / 2, 0, 1)
      ..rotateZ(rotation)
      ..scaleByDouble(zoom, zoom, 1, 1)
      ..translateByDouble(-target.dx, -target.dy, 0, 1);
  }

  Widget _contourOverlay(NailRegion nail, Size viewport) {
    final natural = Size(
      widget.analysis.width.toDouble(),
      widget.analysis.height.toDouble(),
    );
    final fitted = applyBoxFit(BoxFit.contain, natural, viewport).destination;
    final scale = fitted.width / natural.width;
    final origin = Offset(
      (viewport.width - fitted.width) / 2,
      (viewport.height - fitted.height) / 2,
    );
    Offset toViewport(Offset uv) {
      final local = Offset(
        (uv.dx - .5) * nail.width,
        (uv.dy - .5) * nail.height,
      );
      final c = math.cos(nail.angle), s = math.sin(nail.angle);
      return origin +
          (nail.center +
                  Offset(
                    c * local.dx - s * local.dy,
                    s * local.dx + c * local.dy,
                  )) *
              scale;
    }

    final points = _contourPoints.map(toViewport).toList();
    return MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(gestureSettings: const DeviceGestureSettings(touchSlop: 6)),
      child: ValueListenableBuilder<Matrix4>(
        valueListenable: _photoTransform,
        builder: (context, transform, _) {
          const hitSize = 24.0;
          final displayed = points
              .map((p) => MatrixUtils.transformPoint(transform, p))
              .toList();
          return Stack(
            fit: StackFit.expand,
            children: [
              IgnorePointer(
                child: CustomPaint(painter: _ContourPainter(displayed)),
              ),
              for (var i = 0; i < points.length; i++)
                Positioned(
                  left: displayed[i].dx - hitSize / 2,
                  top: displayed[i].dy - hitSize / 2,
                  child: GestureDetector(
                    key: ValueKey('contour-point-$i'),
                    behavior: HitTestBehavior.opaque,
                    dragStartBehavior: DragStartBehavior.down,
                    onPanStart: (_) {
                      if (_editingLocked || _fitting) return;
                      _remember();
                      final current = _selectedNail;
                      if (current != null) {
                        _maskBase = current;
                        _edgeExpansion = 0;
                      }
                    },
                    onPanUpdate: (details) {
                      if (_editingLocked || _fitting) return;
                      final c = math.cos(nail.angle), s = math.sin(nail.angle);
                      // A view rotation changes the direction as well as the
                      // length of a screen drag. Invert the entire view matrix.
                      final inverse = Matrix4.inverted(transform);
                      final delta =
                          (MatrixUtils.transformPoint(inverse, details.delta) -
                              MatrixUtils.transformPoint(
                                inverse,
                                Offset.zero,
                              )) /
                          scale;
                      final local = Offset(
                        c * delta.dx + s * delta.dy,
                        -s * delta.dx + c * delta.dy,
                      );
                      final nextPoints = List<Offset>.of(_contourPoints);
                      final next =
                          nextPoints[i] +
                          Offset(local.dx / nail.width, local.dy / nail.height);
                      nextPoints[i] = Offset(
                        next.dx.clamp(.005, .995),
                        next.dy.clamp(.005, .995),
                      );
                      setState(() {
                        _contourPoints = nextPoints;
                        _edgeExpansion = 0;
                      });
                      final updated = applyContour(
                        _maskBase ?? nail,
                        nextPoints,
                        feather: _edgeFeather,
                      );
                      _maskBase = updated;
                      unawaited(_replaceMask(updated));
                    },
                    child: Container(
                      width: hitSize,
                      height: hitSize,
                      alignment: Alignment.center,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFFFFF),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: const Color(0xFF7A3F4E),
                            width: 1.5,
                          ),
                          boxShadow: const [
                            BoxShadow(color: Color(0x5534222B), blurRadius: 3),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _adjustmentPanel() {
    final nail = _selectedNail;
    if (nail == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
        child: Column(
          children: [
            const Text('点选一片甲面后，可拖动位置并调整大小与方向。'),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => _setTool(_EditorTool.styles),
              child: const Text('返回款式'),
            ),
          ],
        ),
      );
    }
    final review = _refine ? _edgeReviewReason(nail) : null;
    final maxSize = math
        .max(widget.analysis.width, widget.analysis.height)
        .toDouble();
    Widget slider(
      String label,
      double value,
      double min,
      double max,
      void Function(double) change,
    ) => Row(
      children: [
        SizedBox(
          width: 35,
          child: Text(label, style: const TextStyle(fontSize: 12)),
        ),
        Expanded(
          child: Slider(
            key: ValueKey('nail-adjust-$label'),
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChangeStart: (_) {
              _remember();
            },
            onChanged: (value) {
              if (_editingLocked || _fitting) return;
              change(value);
            },
          ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  nail.isManual ? '补选甲面 · 可按真实甲缘修边' : '微调甲面',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                onPressed: () {
                  _remember();
                  _fitGeneration++;
                  _maskGeneration++;
                  setState(() {
                    _nails = _nails.where((n) => n.id != nail.id).toList();
                    _styles = Map.of(_styles)..remove(nail.id);
                    _coatAmounts = Map.of(_coatAmounts)..remove(nail.id);
                    _confirmedEdges = Set.of(_confirmedEdges)..remove(nail.id);
                    _selected = null;
                    _fitting = false;
                    _refine = false;
                    _resetMaskEditing(null);
                  });
                },
                child: const Text('删除'),
              ),
              if (review != null)
                TextButton(
                  key: const ValueKey('nail-edge-confirm'),
                  onPressed: _fitting ? null : () => _confirmEdge(nail),
                  child: const Text('确认甲缘'),
                )
              else
                TextButton(
                  onPressed: () {
                    setState(() {
                      _tool = _EditorTool.styles;
                      _adding = false;
                      _refine = false;
                      _fitGeneration++;
                      _fitting = false;
                    });
                    _resetToolsScroll();
                  },
                  child: const Text('完成'),
                ),
            ],
          ),
          Wrap(
            spacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ChoiceChip(
                label: const Text('位置大小', style: TextStyle(fontSize: 11)),
                selected: !_refine,
                onSelected: (_) => setState(() {
                  _refine = false;
                }),
                visualDensity: VisualDensity.compact,
              ),
              ChoiceChip(
                key: const ValueKey('refine-nail-contour'),
                label: const Text('修边贴合', style: TextStyle(fontSize: 11)),
                selected: _refine,
                onSelected: (_) => setState(() {
                  _refine = true;
                  _resetMaskEditing(nail);
                }),
                visualDensity: VisualDensity.compact,
              ),
              TextButton.icon(
                key: const ValueKey('refit-nail'),
                onPressed: _fitting ? null : _refitSelected,
                icon: const Icon(Icons.auto_fix_high_rounded, size: 15),
                label: Text(
                  _fitting ? '贴合中' : '重新贴合',
                  style: const TextStyle(fontSize: 11),
                ),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
          if (_refine) ...[
            if (review != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '建议检查 · ${review.label}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF986116),
                  ),
                ),
              ),
            slider('扩边', _edgeExpansion, -3, 3, (value) {
              setState(() => _edgeExpansion = value);
              _tuneEdge();
            }),
            slider('柔边', _edgeFeather, .3, 3, (value) {
              setState(() => _edgeFeather = value);
              _tuneEdge();
            }),
            const Padding(
              padding: EdgeInsets.only(bottom: 7),
              child: Text(
                '点击放大修边，可拖动8个控制点；双指缩放查看细节',
                style: TextStyle(fontSize: 11, color: Color(0xFF907883)),
              ),
            ),
          ] else ...[
            slider(
              '宽度',
              nail.width,
              5,
              maxSize * .45,
              (value) => _updateSelected((n) => n.copyWith(width: value)),
            ),
            slider(
              '长度',
              nail.height,
              5,
              maxSize * .5,
              (value) => _updateSelected((n) => n.copyWith(height: value)),
            ),
            slider(
              '旋转',
              nail.angle,
              -math.pi,
              math.pi,
              (value) => _updateSelected((n) => n.copyWith(angle: value)),
            ),
          ],
        ],
      ),
    );
  }
}

class _ContourPainter extends CustomPainter {
  _ContourPainter(this.points);
  final List<Offset> points;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 3) return;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 0; i < points.length; i++) {
      final p0 = points[(i - 1 + points.length) % points.length];
      final p1 = points[i];
      final p2 = points[(i + 1) % points.length];
      final p3 = points[(i + 2) % points.length];
      final c1 = p1 + (p2 - p0) / 6;
      final c2 = p2 - (p3 - p1) / 6;
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = const Color(0x228B4D64));
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFFFAF5F7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(covariant _ContourPainter oldDelegate) =>
      points != oldDelegate.points;
}
