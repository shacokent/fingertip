import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// A single row of plans with actions that stay visible while plans scroll.
class NailPlanRail extends StatefulWidget {
  const NailPlanRail({
    super.key,
    required this.plans,
    required this.activeId,
    required this.enabled,
    required this.onAdd,
    required this.onSelect,
    required this.onRename,
    required this.onDelete,
  });

  final Map<int, String> plans;
  final int activeId;
  final bool enabled;
  final VoidCallback onAdd;
  final ValueChanged<int> onSelect;
  final VoidCallback onRename;
  final VoidCallback? onDelete;

  @override
  State<NailPlanRail> createState() => _NailPlanRailState();
}

enum _PlanAction { rename, delete }

class _NailPlanRailState extends State<NailPlanRail> {
  final _scroll = ScrollController();
  final _chipKeys = <int, GlobalKey>{};
  double? _width;

  @override
  void didUpdateWidget(covariant NailPlanRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    _chipKeys.removeWhere((id, _) => !widget.plans.containsKey(id));
    if (oldWidget.activeId != widget.activeId ||
        oldWidget.plans.length != widget.plans.length ||
        oldWidget.plans[widget.activeId] != widget.plans[widget.activeId]) {
      _revealActive();
    }
  }

  void _revealActive() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final chip = _chipKeys[widget.activeId]?.currentContext
          ?.findRenderObject();
      if (chip == null || !chip.attached) return;
      final position = _scroll.position;
      final viewport = RenderAbstractViewport.of(chip);
      final start = viewport.getOffsetToReveal(chip, 0).offset;
      final end = viewport.getOffsetToReveal(chip, 1).offset;
      final offset = position.pixels;
      final reveal = start < end ? start : offset.clamp(end, start).toDouble();
      final target = reveal
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if ((target - offset).abs() > .5) position.jumpTo(target);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth != _width) {
                  _width = constraints.maxWidth;
                  _revealActive();
                }
                return SingleChildScrollView(
                  controller: _scroll,
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final plan in widget.plans.entries)
                        Padding(
                          key: ValueKey('nail-plan-item-${plan.key}'),
                          padding: const EdgeInsetsDirectional.only(end: 6),
                          child: Tooltip(
                            key: _chipKeys.putIfAbsent(plan.key, GlobalKey.new),
                            message: plan.value,
                            excludeFromSemantics: true,
                            child: ChoiceChip(
                              key: ValueKey('nail-plan-${plan.key}'),
                              label: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 108,
                                ),
                                child: Text(
                                  plan.value,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              selected: plan.key == widget.activeId,
                              onSelected: widget.enabled
                                  ? (selected) {
                                      if (selected) widget.onSelect(plan.key);
                                    }
                                  : null,
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
          IconButton(
            key: const ValueKey('nail-plan-add'),
            tooltip: '新建方案（复制当前）',
            icon: const Icon(Icons.add_circle_outline, size: 22),
            onPressed: widget.enabled ? widget.onAdd : null,
          ),
          PopupMenuButton<_PlanAction>(
            key: const ValueKey('nail-plan-menu'),
            tooltip: '管理当前方案',
            icon: const Icon(Icons.more_horiz, size: 22),
            enabled:
                widget.enabled && widget.plans.containsKey(widget.activeId),
            onSelected: (action) {
              if (!widget.enabled) return;
              switch (action) {
                case _PlanAction.rename:
                  widget.onRename();
                case _PlanAction.delete:
                  widget.onDelete?.call();
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                key: ValueKey('nail-plan-rename'),
                value: _PlanAction.rename,
                child: Text('重命名方案'),
              ),
              if (widget.onDelete != null)
                const PopupMenuItem(
                  key: ValueKey('nail-plan-delete'),
                  value: _PlanAction.delete,
                  child: Text('删除方案'),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}
