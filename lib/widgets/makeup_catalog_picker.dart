import 'package:flutter/material.dart';

import '../services/photo_makeup.dart';
import 'makeup_style_illustration.dart';

Widget _catalogStrip(List<Widget> children, {Key? key}) =>
    SingleChildScrollView(
      key: key,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          for (final child in children)
            Padding(padding: const EdgeInsets.only(right: 7), child: child),
        ],
      ),
    );

/// Shared catalog for the camera and the photo editor.
class MakeupLookPicker extends StatefulWidget {
  const MakeupLookPicker({
    super.key,
    required this.selectedLook,
    required this.hasMakeup,
    required this.strength,
    required this.enabled,
    required this.onSelect,
    required this.onStrengthChanged,
    this.onStrengthStart,
    this.onStrengthEnd,
  });

  final MakeupLook? selectedLook;
  final bool hasMakeup, enabled;
  final double strength;
  final ValueChanged<MakeupLook?> onSelect;
  final ValueChanged<double> onStrengthChanged;
  final ValueChanged<double>? onStrengthStart, onStrengthEnd;

  @override
  State<MakeupLookPicker> createState() => _MakeupLookPickerState();
}

class _MakeupLookPickerState extends State<MakeupLookPicker> {
  late MakeupLookGroup _group =
      widget.selectedLook?.group ?? MakeupLookGroup.daily;

  static const _groupOrder = [
    MakeupLookGroup.daily,
    MakeupLookGroup.signature,
    MakeupLookGroup.holiday,
    MakeupLookGroup.seasonal,
    MakeupLookGroup.soft,
    MakeupLookGroup.glow,
    MakeupLookGroup.bold,
  ];

  @override
  void didUpdateWidget(MakeupLookPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    final look = widget.selectedLook;
    if (look != null && look != oldWidget.selectedLook) _group = look.group;
  }

  Widget _card({
    required String label,
    required bool selected,
    required Widget preview,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
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
          onTap: widget.enabled ? onTap : null,
          child: SizedBox(
            width: 82,
            child: Padding(
              padding: const EdgeInsets.all(5),
              child: Column(
                children: [
                  SizedBox(width: double.infinity, height: 40, child: preview),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _lookCard(MakeupLook look) {
    final design = look.design;
    final lash = design.layer(MakeupPart.lashes);
    Color pigment(MakeupPart part) {
      final layer = design.layer(part);
      return layer.color.withValues(alpha: layer.amount);
    }

    return _card(
      label: look.label,
      selected: look == widget.selectedLook,
      preview: MakeupStyleIllustration(
        lashStyle: lash.amount > 0 ? lash.style : -1,
        shadow: pigment(MakeupPart.shadow),
        cheek: pigment(MakeupPart.blush),
        lip: pigment(MakeupPart.lipstick),
        lipFinish: design.layer(MakeupPart.lipstick).style,
      ),
      onTap: () => widget.onSelect(look),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _catalogStrip([
        for (final group in _groupOrder)
          ChoiceChip(
            label: Text(group.label),
            selected: _group == group,
            onSelected: widget.enabled
                ? (_) => setState(() => _group = group)
                : null,
          ),
      ]),
      _catalogStrip([
        _card(
          label: '原肤',
          selected: !widget.hasMakeup && widget.selectedLook == null,
          preview: const Icon(Icons.face_outlined),
          onTap: () => widget.onSelect(null),
        ),
        for (final look in MakeupLook.values.where(
          (look) => look.group == _group,
        ))
          _lookCard(look),
      ], key: ValueKey(_group)),
      if (widget.selectedLook == null && widget.hasMakeup)
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 5, 12, 2),
          child: Text('当前为自定义妆效'),
        ),
      if (widget.selectedLook != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              const Text('整妆强度'),
              Expanded(
                child: Semantics(
                  label: '整妆强度',
                  child: Slider(
                    key: const ValueKey('makeup-look-strength'),
                    value: widget.strength,
                    semanticFormatterCallback: (value) =>
                        '${(value * 100).round()}%',
                    onChangeStart: widget.enabled
                        ? widget.onStrengthStart
                        : null,
                    onChanged: widget.enabled ? widget.onStrengthChanged : null,
                    onChangeEnd: widget.enabled ? widget.onStrengthEnd : null,
                  ),
                ),
              ),
              Text('${(widget.strength * 100).round()}%'),
            ],
          ),
        ),
    ],
  );
}

class MakeupShadePicker extends StatefulWidget {
  const MakeupShadePicker({
    super.key,
    required this.part,
    required this.selectedColor,
    required this.onSelect,
  });

  final MakeupPart part;
  final Color? selectedColor;
  final ValueChanged<Color>? onSelect;

  @override
  State<MakeupShadePicker> createState() => _MakeupShadePickerState();
}

class _MakeupShadePickerState extends State<MakeupShadePicker> {
  late int _family = _familyForSelection();

  int _familyForSelection() {
    final color = widget.selectedColor;
    if (color == null) return 0;
    final shade = widget.part.palette.indexOf(color);
    final family = widget.part.shadeFamilies.indexWhere(
      (entry) => entry.$2.contains(shade),
    );
    return family < 0 ? 0 : family;
  }

  @override
  void didUpdateWidget(MakeupShadePicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.part != oldWidget.part ||
        (widget.selectedColor != null &&
            widget.selectedColor != oldWidget.selectedColor)) {
      _family = _familyForSelection();
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.part.palette;
    final families = widget.part.shadeFamilies;
    final indices = families.isEmpty
        ? Iterable<int>.generate(palette.length)
        : families[_family].$2;
    final onSelect = widget.onSelect;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (families.isNotEmpty)
          _catalogStrip([
            for (final (index, family) in families.indexed)
              ChoiceChip(
                label: Text(family.$1),
                selected: _family == index,
                onSelected: onSelect == null
                    ? null
                    : (_) => setState(() => _family = index),
              ),
          ], key: ValueKey(widget.part)),
        _catalogStrip([
          for (final index in indices)
            MakeupShadeSwatch(
              color: palette[index],
              label: widget.part.shadeName(index),
              selected: palette[index] == widget.selectedColor,
              onTap: onSelect == null ? null : () => onSelect(palette[index]),
            ),
        ], key: ValueKey((widget.part, _family))),
      ],
    );
  }
}

class MakeupShadeSwatch extends StatelessWidget {
  const MakeupShadeSwatch({
    super.key,
    required this.color,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final ink = ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black87;
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        label: label,
        selected: selected,
        button: true,
        enabled: onTap != null,
        onTap: onTap,
        child: ExcludeSemantics(
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: SizedBox(
              width: 50,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Column(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: selected
                              ? colors.primary
                              : colors.outlineVariant,
                          width: selected ? 2 : 1,
                        ),
                      ),
                      child: selected
                          ? Icon(Icons.check_rounded, size: 17, color: ink)
                          : null,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
