import 'package:flutter/material.dart';

import '../models/nail_models.dart';
import '../services/camera_preview_geometry.dart';

/// Only shows current model detections; null means waiting, not zero nails.
class LiveNailOverlay extends StatelessWidget {
  const LiveNailOverlay({
    super.key,
    required this.nails,
    required this.imageSize,
    this.unavailable = false,
    this.capturing = false,
  });

  final List<NailRegion>? nails;
  final Size? imageSize;
  final bool unavailable;
  final bool capturing;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.biggest;
        final geometry = imageSize == null
            ? null
            : PreviewGeometry.cover(
                imageSize: imageSize!,
                viewportSize: viewport,
              );
        final visible = geometry == null
            ? <NailRegion>[]
            : (nails ?? <NailRegion>[]).where(geometry.isVisible).toList();
        final waiting = nails == null || geometry == null;
        final String title;
        final String hint;
        final IconData icon;
        final Color accent;
        if (capturing) {
          title = '正在拍照…';
          hint = '请稍微稳住手机';
          icon = Icons.camera_alt_outlined;
          accent = Colors.white;
        } else if (unavailable) {
          title = '预览识别暂不可用';
          hint = '仍可拍照，拍摄后会识别甲面';
          icon = Icons.info_outline_rounded;
          accent = const Color(0xFFFFD8A3);
        } else if (waiting) {
          title = '正在识别指甲…';
          hint = '让甲面清晰地出现在画面中';
          icon = Icons.search_rounded;
          accent = Colors.white;
        } else if (visible.isEmpty) {
          title = '尚未识别到指甲';
          hint = '试着调整距离、光线或拍摄角度';
          icon = Icons.search_rounded;
          accent = const Color(0xFFFFD8A3);
        } else {
          title = '已识别到 ${visible.length} 个指甲';
          hint = '可继续调整角度，再按快门';
          icon = Icons.check_circle_outline_rounded;
          accent = const Color(0xFFAAFFD6);
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            if (!waiting && !unavailable && !capturing)
              CustomPaint(
                key: const ValueKey('live-nail-markers'),
                painter: LiveNailMarkerPainter(visible, geometry),
              ),
            Positioned(
              top: 16,
              left: 12,
              right: 12,
              child: Center(
                child: Semantics(
                  liveRegion: true,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 11,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xC9232529),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: accent.withValues(alpha: .35)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, size: 19, color: accent),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            title,
                            style: TextStyle(
                              color: accent,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: 16,
              left: 16,
              right: 16,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 13,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xAA232529),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    hint,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
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

class LiveNailMarkerPainter extends CustomPainter {
  LiveNailMarkerPainter(this.nails, this.geometry);

  final List<NailRegion> nails;
  final PreviewGeometry geometry;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (var index = 0; index < nails.length; index++) {
      final nail = nails[index];
      final center = geometry.toViewport(nail.center);
      final width = nail.width * geometry.scale + 6;
      final height = nail.height * geometry.scale + 6;
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(nail.angle);
      final outline = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset.zero, width: width, height: height),
        Radius.circular(width * .4),
      );
      canvas.drawRRect(outline, Paint()..color = const Color(0x2284F5BC));
      canvas.drawRRect(
        outline,
        Paint()
          ..color = const Color(0xBB173D2D)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4,
      );
      canvas.drawRRect(
        outline,
        Paint()
          ..color = const Color(0xFFAAFFD6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8,
      );
      canvas.restore();
      // Number badges stay upright even when the photographed nail is rotated.
      final badge = center + Offset(width * .35, -height * .4);
      canvas.drawCircle(badge, 9, Paint()..color = const Color(0xFFAAFFD6));
      final label = TextPainter(
        text: TextSpan(
          text: '${index + 1}',
          style: const TextStyle(
            color: Color(0xFF173D2D),
            fontWeight: FontWeight.w700,
            fontSize: 10,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, badge - Offset(label.width / 2, label.height / 2));
      label.dispose();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant LiveNailMarkerPainter oldDelegate) =>
      !identical(nails, oldDelegate.nails) ||
      geometry.scale != oldDelegate.geometry.scale ||
      geometry.offset != oldDelegate.geometry.offset;
}
