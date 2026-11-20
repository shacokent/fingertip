import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Small schematic cards show the shape of the lashes and the palette of a
/// complete look independently of the photo currently being edited.
class MakeupStyleIllustration extends StatelessWidget {
  const MakeupStyleIllustration({
    super.key,
    required this.lashStyle,
    this.lashesOnly = false,
    this.shadow = const Color(0xFFBD8B86),
    this.cheek = const Color(0xFFD58E90),
    this.lip = const Color(0xFFA95266),
    this.lipFinish = 0,
  });

  final int lashStyle, lipFinish;
  final bool lashesOnly;
  final Color shadow, cheek, lip;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _MakeupStylePainter(
      lashStyle,
      lashesOnly,
      shadow,
      cheek,
      lip,
      lipFinish,
    ),
    child: const SizedBox.expand(),
  );
}

class _MakeupStylePainter extends CustomPainter {
  const _MakeupStylePainter(
    this.lashStyle,
    this.lashesOnly,
    this.shadow,
    this.cheek,
    this.lip,
    this.lipFinish,
  );

  final int lashStyle, lipFinish;
  final bool lashesOnly;
  final Color shadow, cheek, lip;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(size.width / 100, size.height / 72);
    canvas.save();
    canvas.translate(
      (size.width - 100 * scale) / 2,
      (size.height - 72 * scale) / 2,
    );
    canvas.scale(scale);
    if (lashesOnly) {
      canvas.translate(6, 25);
      canvas.scale(1.75);
      _eye(canvas);
    } else {
      final face = Path()
        ..moveTo(50, 4)
        ..cubicTo(31, 4, 21, 15, 24, 36)
        ..cubicTo(25, 54, 35, 66, 50, 69)
        ..cubicTo(65, 66, 75, 54, 76, 36)
        ..cubicTo(79, 15, 69, 4, 50, 4)
        ..close();
      canvas.drawPath(face, Paint()..color = const Color(0xFFF1CDB8));
      for (final x in [35.0, 65.0]) {
        final spot = Offset(x, 45);
        canvas.drawOval(
          Rect.fromCenter(center: spot, width: 18, height: 12),
          Paint()
            ..shader = RadialGradient(
              colors: [
                cheek.withValues(alpha: .75 * cheek.a),
                cheek.withValues(alpha: 0),
              ],
            ).createShader(Rect.fromCircle(center: spot, radius: 9)),
        );
      }
      canvas.save();
      canvas.translate(28, 25);
      canvas.scale(.40);
      _eye(canvas);
      canvas.restore();
      canvas.save();
      canvas.translate(72, 25);
      canvas.scale(-.40, .40);
      _eye(canvas);
      canvas.restore();
      final mouth = Path()
        ..moveTo(40, 53)
        ..quadraticBezierTo(45, 47, 50, 51)
        ..quadraticBezierTo(55, 47, 60, 53)
        ..quadraticBezierTo(50, 62, 40, 53);
      final mouthColor = Color.alphaBlend(lip, const Color(0xFFD4998B));
      canvas.drawPath(mouth, Paint()..color = mouthColor);
      canvas.drawPath(
        Path()
          ..moveTo(40, 53)
          ..quadraticBezierTo(50, 55, 60, 53),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = .6
          ..color = Color.lerp(mouthColor, const Color(0xFF4C2931), .4)!,
      );
      if (lip.a > 0 && (lipFinish == 1 || lipFinish >= 3)) {
        canvas.drawOval(
          Rect.fromCenter(
            center: const Offset(50, 56),
            width: lipFinish == 4 ? 8 : 12,
            height: lipFinish == 4 ? 1.5 : 2,
          ),
          Paint()
            ..color = Colors.white.withValues(
              alpha: lipFinish == 4 ? .47 : .24,
            ),
        );
      }
      if (lip.a > 0 && lipFinish == 5) {
        final glint = Paint()..color = Colors.white.withValues(alpha: .72);
        for (final point in const [
          Offset(45, 53),
          Offset(49, 54.5),
          Offset(52, 52),
          Offset(55, 54),
        ]) {
          canvas.drawCircle(point, .8, glint);
        }
      }
    }
    canvas.restore();
  }

  void _eye(Canvas canvas) {
    final shadowCenter = const Offset(25, 2);
    canvas.drawOval(
      const Rect.fromLTWH(-1, -10, 52, 26),
      Paint()
        ..shader = RadialGradient(
          colors: [
            shadow.withValues(alpha: .65 * shadow.a),
            shadow.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: shadowCenter, radius: 25)),
    );
    final eye = Path()
      ..moveTo(0, 12)
      ..quadraticBezierTo(25, -11, 50, 12)
      ..quadraticBezierTo(25, 27, 0, 12)
      ..close();
    canvas.drawPath(eye, Paint()..color = const Color(0xFFFFF8F1));
    canvas.save();
    canvas.clipPath(eye);
    canvas.drawCircle(
      const Offset(25, 11),
      8,
      Paint()..color = const Color(0xFF795C54),
    );
    canvas.drawCircle(
      const Offset(25, 10.5),
      4.7,
      Paint()..color = const Color(0xFF35262A),
    );
    canvas.drawCircle(
      const Offset(23, 8),
      1.5,
      Paint()..color = const Color(0xFFFFFAF6),
    );
    canvas.restore();
    final ink = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFF412F38);
    canvas.drawPath(
      Path()
        ..moveTo(0, 12)
        ..quadraticBezierTo(25, -11, 50, 12),
      ink,
    );
    if (lashStyle < 0) return;
    final lower = lashStyle == 5;
    final count = switch (lashStyle) {
      1 => 16,
      2 => 11,
      3 => 20,
      4 => 15,
      5 => 14,
      6 => 11,
      7 => 10,
      8 => 14,
      9 => 17,
      _ => 13,
    };
    for (var index = 0; index < count; index++) {
      final t = .07 + (lashStyle == 7 ? .44 : .88) * index / (count - 1);
      final base = Offset(50 * t, 12 + (lower ? 30 : -46) * t * (1 - t));
      final length = switch (lashStyle) {
        1 => 4 + (1 - t) * 12,
        2 => (index.isEven ? 13.0 : 5.0) * math.sin(math.pi * t),
        3 => 7 + 8 * math.sin(math.pi * t),
        4 => 4 + 13 * math.sin(math.pi * t),
        5 => 3 + 5 * math.sin(math.pi * t),
        6 => 4 + 11 * math.sin(math.pi * t),
        7 => 5 + (1 - t) * 8,
        8 => (index % 3 == 0 ? 15.0 : 7.0) * math.sin(math.pi * t),
        9 => 3.5 + 4 * math.sin(math.pi * t),
        _ => 3 + 6 * math.sin(math.pi * t),
      };
      final lean = (t - .56) * length;
      final rise = lower ? length : -length;
      canvas.drawPath(
        Path()
          ..moveTo(base.dx, base.dy)
          ..quadraticBezierTo(
            base.dx + lean * .2,
            base.dy + rise * .78,
            base.dx + lean,
            base.dy + rise,
          ),
        ink,
      );
    }
  }

  @override
  bool shouldRepaint(_MakeupStylePainter oldDelegate) =>
      oldDelegate.lashStyle != lashStyle ||
      oldDelegate.lashesOnly != lashesOnly ||
      oldDelegate.shadow != shadow ||
      oldDelegate.cheek != cheek ||
      oldDelegate.lip != lip ||
      oldDelegate.lipFinish != lipFinish;
}
