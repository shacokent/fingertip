import 'package:flutter/material.dart';

import '../models/diy_models.dart';
import '../models/nail_models.dart';
import '../services/nail_favorites.dart';
import 'nail_style_swatch.dart';

/// Two inline strips keep the photograph visible while changing a design.
class InlineStyleBrowser extends StatefulWidget {
  const InlineStyleBrowser({
    super.key,
    required this.selectedStyle,
    required this.customStyles,
    required this.onSelected,
    required this.onCreateDiy,
    required this.onEditDiy,
    required this.onDeleteDiy,
    this.enabled = true,
    this.favorites,
  });

  final NailStyle selectedStyle;
  final List<DiySavedStyle> customStyles;
  final ValueChanged<NailStyle> onSelected;
  final VoidCallback onCreateDiy;
  final ValueChanged<DiySavedStyle> onEditDiy;
  final ValueChanged<DiySavedStyle> onDeleteDiy;
  final bool enabled;
  final NailFavorites? favorites;

  @override
  State<InlineStyleBrowser> createState() => _InlineStyleBrowserState();
}

class _InlineStyleBrowserState extends State<InlineStyleBrowser> {
  static const _seasonalCategories = [
    NailCategory.holidayArt,
    NailCategory.orientalArt,
    NailCategory.frostJewels,
    NailCategory.winterMagnetic,
    NailCategory.fineFrench,
    NailCategory.winterPrints,
  ];
  static final _orderedCategories = [
    NailCategory.classic,
    ..._seasonalCategories,
    for (final category in NailCategory.values)
      if (category != NailCategory.classic &&
          !_seasonalCategories.contains(category))
        category,
  ];
  static final _stylesByCategory = {
    for (final category in NailCategory.values)
      category: NailStyle.all.where((s) => s.category == category).toList(),
  };

  late NailCategory _category = widget.selectedStyle.category;
  late bool _custom = widget.selectedStyle.isCustom;
  bool _showFavorites = false;
  bool _loadingFavorites = true;
  bool _savingFavorite = false;
  Set<String> _favoriteIds = {};
  final _stylesScroll = ScrollController();

  NailFavorites get _favorites => widget.favorites ?? NailFavorites.local;

  @override
  void initState() {
    super.initState();
    _loadFavorites();
  }

  Future<void> _loadFavorites() async {
    try {
      final ids = await _favorites.load();
      if (mounted) setState(() => _favoriteIds = ids);
    } catch (_) {
      // Other styles remain available if local favorites cannot be read.
    } finally {
      if (mounted) setState(() => _loadingFavorites = false);
    }
  }

  Future<void> _toggleFavorite() async {
    if (_loadingFavorites || _savingFavorite) return;
    final id = widget.selectedStyle.id;
    setState(() => _savingFavorite = true);
    try {
      final ids = await _favorites.setFavorite(id, !_favoriteIds.contains(id));
      if (mounted) setState(() => _favoriteIds = ids);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('收藏暂时无法保存，请重试。')));
      }
    } finally {
      if (mounted) setState(() => _savingFavorite = false);
    }
  }

  @override
  void didUpdateWidget(covariant InlineStyleBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedStyle.id != widget.selectedStyle.id ||
        oldWidget.selectedStyle.texturePath !=
            widget.selectedStyle.texturePath) {
      _category = widget.selectedStyle.category;
      _custom = widget.selectedStyle.isCustom;
    }
  }

  @override
  void dispose() {
    _stylesScroll.dispose();
    super.dispose();
  }

  void _selectCategory(NailCategory? category, {bool favorites = false}) {
    setState(() {
      _showFavorites = favorites;
      _custom = category == null;
      if (category != null) _category = category;
    });
    if (_stylesScroll.hasClients) _stylesScroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final customById = {
      for (final entry in widget.customStyles) entry.id: entry,
    };
    final favoriteStyles = [
      for (final id in _favoriteIds)
        ?(customById[id]?.style ?? NailStyle.byId(id)),
    ];
    final styles = _showFavorites
        ? favoriteStyles
        : _custom
        ? widget.customStyles.map((entry) => entry.style).toList()
        : _stylesByCategory[_category]!;
    final isFavorite = _favoriteIds.contains(widget.selectedStyle.id);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 10, 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.selectedStyle.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('toggle-nail-favorite'),
                tooltip: isFavorite ? '取消收藏' : '收藏当前款式',
                isSelected: isFavorite,
                selectedIcon: const Icon(Icons.favorite, size: 19),
                icon: const Icon(Icons.favorite_border, size: 19),
                visualDensity: VisualDensity.compact,
                onPressed:
                    widget.enabled && !_loadingFavorites && !_savingFavorite
                    ? _toggleFavorite
                    : null,
              ),
              TextButton.icon(
                key: const ValueKey('create-diy-style'),
                onPressed: widget.enabled ? widget.onCreateDiy : null,
                icon: const Icon(Icons.brush_outlined, size: 16),
                label: const Text('DIY新建', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 36,
          child: ListView(
            key: const ValueKey('inline-style-categories'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              _categoryChip(
                'favorites',
                '收藏',
                favoriteStyles.length,
                selected: _showFavorites,
                select: () => _selectCategory(null, favorites: true),
              ),
              _categoryChip(
                'custom',
                '我的DIY',
                widget.customStyles.length,
                selected: !_showFavorites && _custom,
                select: () => _selectCategory(null),
              ),
              for (final category in _orderedCategories)
                _categoryChip(
                  category.name,
                  category.label,
                  _stylesByCategory[category]!.length,
                  selected:
                      !_showFavorites && !_custom && category == _category,
                  select: () => _selectCategory(category),
                ),
            ],
          ),
        ),
        const SizedBox(height: 5),
        SizedBox(
          height: 83,
          child: styles.isEmpty
              ? Center(
                  child: _showFavorites
                      ? Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            _loadingFavorites ? '正在读取收藏…' : '试戴喜欢的款式后，点上方爱心收藏。',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        )
                      : TextButton.icon(
                          onPressed: widget.enabled ? widget.onCreateDiy : null,
                          icon: const Icon(Icons.add_circle_outline, size: 19),
                          label: const Text('导入图片、画一笔，创建自己的款式'),
                        ),
                )
              : ListView.separated(
                  key: const ValueKey('inline-style-list'),
                  controller: _stylesScroll,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: styles.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 7),
                  itemBuilder: (context, index) {
                    final style = styles[index];
                    return _styleCard(style, customById[style.id]);
                  },
                ),
        ),
      ],
    );
  }

  Widget _categoryChip(
    String id,
    String label,
    int count, {
    required bool selected,
    required VoidCallback select,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        key: ValueKey('inline-category-$id'),
        selected: selected,
        showCheckmark: false,
        label: Text('$label $count', style: const TextStyle(fontSize: 11)),
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 3),
        onSelected: widget.enabled ? (_) => select() : null,
      ),
    );
  }

  Widget _styleCard(NailStyle style, DiySavedStyle? saved) {
    final selected = style.id == widget.selectedStyle.id;
    return Material(
      color: selected ? const Color(0xFFF0E1E7) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? const Color(0xFF8D5064) : const Color(0xFFECE3E4),
          width: selected ? 1.4 : 1,
        ),
      ),
      child: InkWell(
        key: ValueKey('inline-style-${style.id}'),
        borderRadius: BorderRadius.circular(12),
        onTap: widget.enabled ? () => widget.onSelected(style) : null,
        onLongPress: saved != null && widget.enabled
            ? () => widget.onEditDiy(saved)
            : null,
        child: SizedBox(
          width: 72,
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 5, 4, 3),
                child: Column(
                  children: [
                    NailStyleSwatch(style: style, width: 32, height: 45),
                    const SizedBox(height: 4),
                    Text(
                      style.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              if (saved != null)
                Positioned(
                  right: 0,
                  top: 0,
                  child: SizedBox.square(
                    dimension: 27,
                    child: PopupMenuButton<String>(
                      key: ValueKey('custom-style-menu-${style.id}'),
                      tooltip: '管理${style.name}',
                      padding: EdgeInsets.zero,
                      iconSize: 16,
                      enabled: widget.enabled,
                      onSelected: (action) {
                        if (action == 'edit') widget.onEditDiy(saved);
                        if (action == 'delete') widget.onDeleteDiy(saved);
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('编辑款式')),
                        PopupMenuItem(value: 'delete', child: Text('删除款式')),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
