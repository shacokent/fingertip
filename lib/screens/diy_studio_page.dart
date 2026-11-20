import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/diy_models.dart';
import '../models/diy_stickers.dart';
import '../services/diy_library.dart';
import '../widgets/diy_canvas.dart';

enum _StudioTool { stickers, base, draw, layers }

class DiyStudioPage extends StatefulWidget {
  const DiyStudioPage({super.key, this.initial, this.library, this.pickImage});
  final DiySavedStyle? initial;
  final DiyLibrary? library;
  final Future<String?> Function()? pickImage;
  @override
  State<DiyStudioPage> createState() => _DiyStudioPageState();
}

class _DiyStudioPageState extends State<DiyStudioPage> {
  late final DiyLibrary _library = widget.library ?? DiyLibrary();
  late DiyNailDesign _design = widget.initial?.design ?? const DiyNailDesign();
  late final _name = TextEditingController(text: _design.name);
  final _history = <DiyNailDesign>[];
  final _redo = <DiyNailDesign>[];
  final _draft = 'draft_${DateTime.now().microsecondsSinceEpoch}';
  String? _selected;
  String _stickerCategory = DiySticker.categories.first;
  _StudioTool _tool = _StudioTool.stickers;
  bool _saving = false, _importing = false, _eraser = false;
  Color _brushColor = const Color(0xFF7A3F4E);
  double _brushWidth = .012;

  DiyLayer? get _layer =>
      _design.layers.where((l) => l.id == _selected).firstOrNull;

  void _remember() {
    _history.add(_design);
    if (_history.length > 50) _history.removeAt(0);
    _redo.clear();
  }

  void _undo() {
    if (_history.isEmpty) return;
    _redo.add(_design);
    setState(() {
      _design = _history.removeLast().copyWith(name: _name.text);
      _syncSelection();
    });
  }

  void _redoChange() {
    if (_redo.isEmpty) return;
    _history.add(_design);
    setState(() {
      _design = _redo.removeLast().copyWith(name: _name.text);
      _syncSelection();
    });
  }

  void _syncSelection() {
    if (!_design.layers.any((l) => l.id == _selected)) _selected = null;
  }

  void _replaceLayer(DiyLayer layer) {
    setState(
      () => _design = _design.copyWith(
        layers: [
          for (final old in _design.layers) old.id == layer.id ? layer : old,
        ],
      ),
    );
  }

  void _add(DiyLayer layer) {
    if (_design.layers.length >= 80) {
      _message('图层已较多，请先删除一些不需要的素材。');
      return;
    }
    _remember();
    setState(() {
      _design = _design.copyWith(layers: [..._design.layers, layer]);
      _selected = layer.id;
    });
  }

  void _deleteLayer(String id) {
    _remember();
    setState(() {
      _design = _design.copyWith(
        layers: _design.layers.where((l) => l.id != id).toList(),
      );
      if (_selected == id) _selected = null;
    });
  }

  void _moveLayer(String id, int direction) {
    final layers = List<DiyLayer>.of(_design.layers);
    final index = layers.indexWhere((l) => l.id == id);
    final target = index + direction;
    if (index < 0 || target < 0 || target >= layers.length) return;
    _remember();
    final layer = layers.removeAt(index);
    layers.insert(target, layer);
    setState(() => _design = _design.copyWith(layers: layers));
  }

  void _lock(DiyLayer layer) {
    _remember();
    _replaceLayer(layer.copyWith(locked: !layer.locked));
  }

  Future<void> _importImage() async {
    if (_saving || _importing) return;
    setState(() => _importing = true);
    try {
      final String? sourcePath;
      if (widget.pickImage != null) {
        sourcePath = await widget.pickImage!();
      } else {
        sourcePath = (await ImagePicker().pickImage(
          source: ImageSource.gallery,
          maxWidth: 1536,
          maxHeight: 1536,
          imageQuality: 100,
          requestFullMetadata: false,
        ))?.path;
      }
      if (sourcePath == null || !mounted) return;
      final path = await _library.importImage(sourcePath, draftId: _draft);
      if (!mounted) {
        await _library.discardDraft(_draft);
        return;
      }
      final codec = await ui.instantiateImageCodec(
        await File(path).readAsBytes(),
      );
      final image = (await codec.getNextFrame()).image;
      final aspect = image.width / image.height;
      image.dispose();
      codec.dispose();
      final width = aspect >= 2 / 3 ? .95 : .95 * aspect * 1.5,
          height = aspect >= 2 / 3 ? .95 / (aspect * 1.5) : .95;
      _add(
        DiyLayer(
          id: 'image_${DateTime.now().microsecondsSinceEpoch}',
          kind: DiyLayerKind.image,
          name: '导入图片',
          imagePath: path,
          width: width,
          height: height,
        ),
      );
    } catch (_) {
      if (mounted) _message('这张图片暂时无法导入，请尝试 JPEG 或 PNG 图片。');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _save() async {
    if (_saving || _importing) return;
    setState(() => _saving = true);
    try {
      final result = await _library.save(
        _design.copyWith(name: _name.text),
        existingId: widget.initial?.id,
      );
      await _library.discardDraft(_draft);
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop<DiySavedStyle>(result);
      }
    } catch (_) {
      if (mounted) _message('保存没有完成，请检查本机空间后重试。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  void dispose() {
    _name.dispose();
    unawaited(_library.discardDraft(_draft));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: Scaffold(
      backgroundColor: const Color(0xFFF8F3F0),
      appBar: AppBar(
        title: const Text('DIY 美甲'),
        actions: [
          IconButton(
            tooltip: '撤销设计',
            onPressed: _history.isEmpty || _saving ? null : _undo,
            icon: const Icon(Icons.undo_rounded),
          ),
          IconButton(
            tooltip: '重做设计',
            onPressed: _redo.isEmpty || _saving ? null : _redoChange,
            icon: const Icon(Icons.redo_rounded),
          ),
          TextButton(
            key: const ValueKey('diy-save'),
            onPressed: _saving || _importing ? null : _save,
            child: Text(_saving ? '保存中' : '保存'),
          ),
        ],
      ),
      body: AbsorbPointer(
        absorbing: _saving,
        child: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final minHeight =
                  690.0 +
                  (MediaQuery.textScalerOf(context).scale(12) / 12 - 1).clamp(
                        0,
                        1,
                      ) *
                      160;
              final content = _body();
              return constraints.maxHeight < minHeight
                  ? SingleChildScrollView(
                      child: SizedBox(height: minHeight, child: content),
                    )
                  : content;
            },
          ),
        ),
      ),
    ),
  );

  Widget _body() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
        child: TextField(
          key: const ValueKey('diy-style-name'),
          controller: _name,
          maxLength: 30,
          decoration: const InputDecoration(
            hintText: '给款式起个名字',
            isDense: true,
            counterText: '',
            border: InputBorder.none,
          ),
          onChanged: (value) => _design = _design.copyWith(name: value),
        ),
      ),
      Expanded(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 26),
            child: AspectRatio(
              aspectRatio: 2 / 3,
              child: DiyCanvas(
                design: _design,
                selectedLayerId: _selected,
                drawing: _tool == _StudioTool.draw,
                eraser: _eraser,
                brushColor: _brushColor,
                brushWidth: _brushWidth,
                onSelect: (id) => setState(() => _selected = id),
                onGestureStart: _remember,
                onLayerChanged: _replaceLayer,
                onStroke: _add,
              ),
            ),
          ),
        ),
      ),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 18, vertical: 4),
        child: Text(
          '拖动素材 · 双指缩放旋转 · 锁定后位置固定',
          style: TextStyle(color: Color(0xFF957C85), fontSize: 11),
        ),
      ),
      if (_layer != null && _tool != _StudioTool.draw) _transformBar(_layer!),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            _toolButton(
              '导入图片',
              Icons.add_photo_alternate_outlined,
              _importing ? null : _importImage,
              false,
              key: const ValueKey('diy-import-image'),
            ),
            _toolButton(
              '素材',
              Icons.auto_awesome_outlined,
              () => setState(() => _tool = _StudioTool.stickers),
              _tool == _StudioTool.stickers,
              key: const ValueKey('diy-material-tool'),
            ),
            _toolButton(
              '底色',
              Icons.palette_outlined,
              () => setState(() => _tool = _StudioTool.base),
              _tool == _StudioTool.base,
              key: const ValueKey('diy-base-tool'),
            ),
            _toolButton(
              '手绘',
              Icons.brush_outlined,
              () => setState(() => _tool = _StudioTool.draw),
              _tool == _StudioTool.draw,
              key: const ValueKey('diy-draw-tool'),
            ),
            _toolButton(
              '图层',
              Icons.layers_outlined,
              () => setState(() => _tool = _StudioTool.layers),
              _tool == _StudioTool.layers,
              key: const ValueKey('diy-layers-tool'),
            ),
          ],
        ),
      ),
      Container(
        height: 200,
        color: Colors.white,
        child: switch (_tool) {
          _StudioTool.stickers => _stickers(),
          _StudioTool.base => _basePanel(),
          _StudioTool.draw => _drawingPanel(),
          _StudioTool.layers => _layersPanel(),
        },
      ),
    ],
  );

  Widget _toolButton(
    String title,
    IconData icon,
    VoidCallback? onTap,
    bool selected, {
    Key? key,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: TextButton(
      key: key,
      onPressed: _saving ? null : onTap,
      style: TextButton.styleFrom(
        minimumSize: const Size(60, 49),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        foregroundColor: selected
            ? const Color(0xFF7A3F4E)
            : const Color(0xFF9D8A90),
        backgroundColor: selected
            ? const Color(0xFFEDDFE4)
            : Colors.transparent,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 19),
          const SizedBox(height: 2),
          Text(title, style: const TextStyle(fontSize: 10)),
        ],
      ),
    ),
  );

  Widget _transformBar(DiyLayer layer) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 15),
    child: Row(
      children: [
        const Text('缩放', style: TextStyle(fontSize: 11)),
        Expanded(
          child: Slider(
            key: const ValueKey('diy-layer-scale'),
            value: layer.scale.clamp(.1, 4),
            min: .1,
            max: 4,
            onChangeStart: (_) => _remember(),
            onChanged: (value) => _replaceLayer(layer.copyWith(scale: value)),
          ),
        ),
        IconButton(
          key: const ValueKey('diy-lock-layer'),
          tooltip: layer.locked ? '解锁位置' : '锁定位置',
          onPressed: () => _lock(layer),
          visualDensity: VisualDensity.compact,
          icon: Icon(layer.locked ? Icons.lock : Icons.lock_open, size: 19),
        ),
        IconButton(
          tooltip: '旋转图层',
          onPressed: () {
            _remember();
            _replaceLayer(
              layer.copyWith(rotation: layer.rotation + math.pi / 12),
            );
          },
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.rotate_right, size: 19),
        ),
        IconButton(
          key: const ValueKey('diy-delete-layer'),
          tooltip: '删除图层',
          onPressed: () => _deleteLayer(layer.id),
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.delete_outline, size: 19),
        ),
      ],
    ),
  );

  Widget _stickers() {
    final stickers = DiySticker.all
        .where((s) => s.category == _stickerCategory)
        .toList();
    return Column(
      children: [
        SizedBox(
          height: 43,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: DiySticker.categories.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, index) {
              final category = DiySticker.categories[index];
              return ChoiceChip(
                label: Text(category, style: const TextStyle(fontSize: 11)),
                selected: category == _stickerCategory,
                onSelected: (_) => setState(() => _stickerCategory = category),
              );
            },
          ),
        ),
        Expanded(
          child: GridView.builder(
            key: const ValueKey('diy-material-grid'),
            padding: const EdgeInsets.fromLTRB(12, 5, 12, 10),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 90,
              mainAxisExtent: 81,
              crossAxisSpacing: 5,
              mainAxisSpacing: 5,
            ),
            itemCount: stickers.length,
            itemBuilder: (context, index) {
              final sticker = stickers[index];
              return InkWell(
                key: ValueKey('diy-sticker-${sticker.id}'),
                borderRadius: BorderRadius.circular(10),
                onTap: () => _add(
                  DiyLayer(
                    id: 'sticker_${DateTime.now().microsecondsSinceEpoch}',
                    kind: DiyLayerKind.sticker,
                    name: sticker.name,
                    stickerId: sticker.id,
                    width: .62,
                    height: .42,
                  ),
                ),
                child: Column(
                  children: [
                    SizedBox(
                      width: 51,
                      height: 53,
                      child: CustomPaint(painter: DiyStickerPainter(sticker)),
                    ),
                    Text(
                      sticker.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 9),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _palette(Color selected, ValueChanged<Color> choose) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final color in _colors)
        InkWell(
          key: ValueKey('diy-color-${color.toARGB32()}'),
          onTap: () => choose(color),
          borderRadius: BorderRadius.circular(20),
          child: Container(
            width: 29,
            height: 29,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected == color
                    ? const Color(0xFF7A3F4E)
                    : const Color(0xFFD5C6CD),
                width: selected == color ? 2.5 : 1,
              ),
            ),
            child: color.a == 0
                ? const Icon(Icons.block, size: 16, color: Color(0xFFBDAFB5))
                : null,
          ),
        ),
    ],
  );

  Widget _basePanel() => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(20, 13, 20, 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '选择底色',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        _palette(_design.baseColor, (color) {
          _remember();
          setState(() => _design = _design.copyWith(baseColor: color));
        }),
        TextButton.icon(
          onPressed: () => _hexColor(_design.baseColor, (color) {
            _remember();
            setState(() => _design = _design.copyWith(baseColor: color));
          }),
          icon: const Icon(Icons.colorize_outlined, size: 16),
          label: const Text('输入色号', style: TextStyle(fontSize: 11)),
        ),
      ],
    ),
  );

  Widget _drawingPanel() => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
    child: Column(
      children: [
        Row(
          children: [
            const Text('画笔', style: TextStyle(fontSize: 12)),
            Expanded(
              child: Slider(
                value: _brushWidth,
                min: .003,
                max: .045,
                onChanged: (value) => setState(() => _brushWidth = value),
              ),
            ),
            const Text('橡皮', style: TextStyle(fontSize: 11)),
            Switch(
              key: const ValueKey('diy-eraser'),
              value: _eraser,
              onChanged: (value) => setState(() => _eraser = value),
            ),
          ],
        ),
        _palette(
          _brushColor,
          (color) => setState(() {
            _brushColor = color;
            _eraser = false;
          }),
        ),
        const SizedBox(height: 8),
        const Text(
          '图层列表越靠上，遮挡越靠前；橡皮只擦除它下方的笔迹。',
          style: TextStyle(color: Color(0xFF9B858E), fontSize: 10),
        ),
      ],
    ),
  );

  Widget _layersPanel() => _design.layers.isEmpty
      ? const Center(
          child: Text(
            '先导入图片、添加素材或手绘一笔',
            style: TextStyle(color: Color(0xFF9B858E), fontSize: 12),
          ),
        )
      : ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 5),
          itemCount: _design.layers.length,
          itemBuilder: (context, index) {
            final layer = _design.layers.reversed.elementAt(index);
            return Material(
              key: ValueKey('diy-layer-${layer.id}'),
              color: _selected == layer.id
                  ? const Color(0xFFF3E8EC)
                  : Colors.white,
              child: InkWell(
                onTap: () => setState(() => _selected = layer.id),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 3, 7, 3),
                  child: Row(
                    children: [
                      Icon(
                        layer.kind == DiyLayerKind.image
                            ? Icons.image_outlined
                            : layer.kind == DiyLayerKind.stroke
                            ? Icons.brush_outlined
                            : Icons.auto_awesome_outlined,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          layer.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                      _smallButton(
                        layer.locked ? Icons.lock : Icons.lock_open,
                        '锁定或解锁位置',
                        () => _lock(layer),
                      ),
                      _smallButton(
                        Icons.arrow_upward_rounded,
                        '上移图层',
                        index == 0 ? null : () => _moveLayer(layer.id, 1),
                        key: ValueKey('diy-layer-up-${layer.id}'),
                      ),
                      _smallButton(
                        Icons.arrow_downward_rounded,
                        '下移图层',
                        index == _design.layers.length - 1
                            ? null
                            : () => _moveLayer(layer.id, -1),
                        key: ValueKey('diy-layer-down-${layer.id}'),
                      ),
                      _smallButton(
                        Icons.delete_outline,
                        '删除此图层',
                        () => _deleteLayer(layer.id),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
  Widget _smallButton(
    IconData icon,
    String tip,
    VoidCallback? action, {
    Key? key,
  }) => IconButton(
    key: key,
    tooltip: tip,
    onPressed: action,
    icon: Icon(icon, size: 16),
    constraints: const BoxConstraints.tightFor(width: 29, height: 34),
    padding: EdgeInsets.zero,
  );

  Future<void> _hexColor(Color initial, ValueChanged<Color> choose) async {
    final controller = TextEditingController(
      text: initial
          .toARGB32()
          .toRadixString(16)
          .padLeft(8, '0')
          .substring(2)
          .toUpperCase(),
    );
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('输入底色色号'),
        content: TextField(
          controller: controller,
          maxLength: 6,
          decoration: const InputDecoration(
            prefixText: '#',
            hintText: '例如 FFE4DC',
          ),
          textCapitalization: TextCapitalization.characters,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('应用'),
          ),
        ],
      ),
    );
    // The dialog exit transition may still own its TextField briefly.
    Future<void>.delayed(const Duration(milliseconds: 350), controller.dispose);
    if (text == null) return;
    final normalized = text.trim().replaceAll('#', '');
    if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(normalized)) {
      if (mounted) _message('请输入 6 位颜色值，例如 FFE4DC。');
      return;
    }
    if (mounted) choose(Color(int.parse('FF$normalized', radix: 16)));
  }
}

const _colors = [
  Color(0xFFFFF0E8),
  Color(0xFFFFFCF3),
  Color(0xFF2B2631),
  Color(0xFFAA6575),
  Color(0xFF7B233B),
  Color(0xFFDF8C80),
  Color(0xFFEBAFC5),
  Color(0xFFC6AFDC),
  Color(0xFF728C7B),
  Color(0xFF7089A0),
  Color(0xFF32626E),
  Color(0xFF967162),
  Color(0xFFD3AE62),
  Color(0xFFB8B7BE),
  Color(0xFFECDED1),
  Color(0x00FFFFFF),
];
