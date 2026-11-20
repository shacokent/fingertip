import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// A view-only transform. Interaction positions are returned in the original
/// child coordinate space so editing never changes the photograph itself.
class PhotoViewport extends StatefulWidget {
  const PhotoViewport({
    super.key,
    required this.controller,
    required this.child,
    this.onTap,
    this.onSceneDrag,
    this.onSceneDragStart,
    this.interactionBounds,
    this.enabled = true,
    this.minScale = .5,
    this.maxScale = 8,
  });

  final TransformationController controller;
  final Widget child;
  final ValueChanged<Offset>? onTap;
  final ValueChanged<Offset>? onSceneDrag;
  final VoidCallback? onSceneDragStart;
  final Rect? interactionBounds;
  final bool enabled;
  final double minScale, maxScale;

  @override
  State<PhotoViewport> createState() => _PhotoViewportState();
}

class _PhotoViewportState extends State<PhotoViewport> {
  Matrix4 _start = Matrix4.identity();
  Offset _startFocal = Offset.zero, _lastFocal = Offset.zero;
  double _startScale = 1, _detailScale = 1, _detailRotation = 0;
  int _pointers = 0;
  final _activePointers = <int>{};
  bool _hadMultiplePointers = false, _sceneDrag = false, _dragStarted = false;

  void _begin(Offset focal, int pointers, double scale, double rotation) {
    _start = widget.controller.value.clone();
    _startScale = math.sqrt(
      _start.entry(0, 0) * _start.entry(0, 0) +
          _start.entry(1, 0) * _start.entry(1, 0),
    );
    _startFocal = _lastFocal = focal;
    _detailScale = scale;
    _detailRotation = rotation;
    _pointers = pointers;
    _hadMultiplePointers |= pointers > 1;
    final point = widget.controller.toScene(focal);
    _sceneDrag =
        !_hadMultiplePointers &&
        widget.onSceneDrag != null &&
        (widget.interactionBounds?.contains(point) ?? true);
  }

  void _update(ScaleUpdateDetails details) {
    if (!widget.enabled) return;
    if (details.pointerCount != _pointers) {
      // Adding or lifting a finger changes the focal point and the recognizer's
      // baseline. Rebase rather than making the photograph jump.
      _begin(
        details.localFocalPoint,
        details.pointerCount,
        details.scale,
        details.rotation,
      );
      return;
    }
    if (_sceneDrag && details.pointerCount == 1) {
      if (!_dragStarted) {
        _dragStarted = true;
        widget.onSceneDragStart?.call();
      }
      final before = widget.controller.toScene(_lastFocal);
      final after = widget.controller.toScene(details.localFocalPoint);
      widget.onSceneDrag!(after - before);
      _lastFocal = details.localFocalPoint;
      return;
    }
    final factor = (details.scale / _detailScale).clamp(
      widget.minScale / _startScale,
      widget.maxScale / _startScale,
    );
    final rotation = details.rotation - _detailRotation;
    widget.controller.value = Matrix4.identity()
      ..translateByDouble(
        details.localFocalPoint.dx,
        details.localFocalPoint.dy,
        0,
        1,
      )
      ..rotateZ(rotation)
      ..scaleByDouble(factor, factor, 1, 1)
      ..translateByDouble(-_startFocal.dx, -_startFocal.dy, 0, 1)
      ..multiply(_start);
  }

  @override
  Widget build(BuildContext context) => MediaQuery(
    // Let photo gestures claim the pointer before the compact layout's outer
    // vertical scroll view. Scrolling the controls remains unchanged.
    data: MediaQuery.of(
      context,
    ).copyWith(gestureSettings: const DeviceGestureSettings(touchSlop: 6)),
    child: Listener(
      onPointerDown: (event) {
        if (_activePointers.isEmpty) {
          _hadMultiplePointers = false;
        }
        _activePointers.add(event.pointer);
        if (_activePointers.length > 1) {
          _hadMultiplePointers = true;
          _sceneDrag = false;
        }
      },
      onPointerUp: (event) => _activePointers.remove(event.pointer),
      onPointerCancel: (event) => _activePointers.remove(event.pointer),
      child: GestureDetector(
        key: const ValueKey('photo-view-gestures'),
        behavior: HitTestBehavior.opaque,
        onTapUp: !widget.enabled || widget.onTap == null
            ? null
            : (details) {
                final point = widget.controller.toScene(details.localPosition);
                if (widget.interactionBounds?.contains(point) ?? true) {
                  widget.onTap!(point);
                }
              },
        onScaleStart: !widget.enabled
            ? null
            : (details) {
                _dragStarted = false;
                _begin(details.localFocalPoint, details.pointerCount, 1, 0);
              },
        onScaleUpdate: !widget.enabled ? null : _update,
        onScaleEnd: !widget.enabled
            ? null
            : (_) {
                _sceneDrag = false;
                _dragStarted = false;
              },
        child: AnimatedBuilder(
          animation: widget.controller,
          builder: (context, child) => Transform(
            transform: widget.controller.value,
            alignment: Alignment.topLeft,
            transformHitTests: false,
            child: child,
          ),
          child: SizedBox.expand(child: widget.child),
        ),
      ),
    ),
  );
}
