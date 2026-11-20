part of 'photo_makeup.dart';

List<Offset> _sample(List<Offset> points, int count) {
  if (points.length < 2 || count < 2) return points;
  final distance = <double>[0];
  for (var i = 1; i < points.length; i++) {
    distance.add(distance.last + (points[i] - points[i - 1]).distance);
  }
  if (distance.last == 0) return List.filled(count, points.first);
  var segment = 1;
  return List.generate(count, (i) {
    final target = distance.last * i / (count - 1);
    while (segment < points.length - 1 && distance[segment] < target) {
      segment++;
    }
    final length = distance[segment] - distance[segment - 1];
    final t = length == 0 ? 0.0 : (target - distance[segment - 1]) / length;
    return Offset.lerp(points[segment - 1], points[segment], t)!;
  });
}

Offset _center(List<Offset> points) =>
    points.fold(Offset.zero, (sum, p) => sum + p) / points.length.toDouble();

class _Eye {
  _Eye(this.loop, this.brow, this.onRight);
  final List<Offset> loop, brow;
  final bool onRight;

  Offset get center => _center(loop);
  double get width =>
      loop.map((p) => p.dx).reduce(math.max) -
      loop.map((p) => p.dx).reduce(math.min);

  List<Offset> arc({bool lower = false}) {
    var left = 0, right = 0;
    for (var i = 1; i < loop.length; i++) {
      if (loop[i].dx < loop[left].dx) left = i;
      if (loop[i].dx > loop[right].dx) right = i;
    }
    List<Offset> walk(int direction) {
      final points = <Offset>[loop[left]];
      var i = left;
      while (i != right) {
        i = (i + direction) % loop.length;
        points.add(loop[i]);
      }
      return points;
    }

    final forward = walk(1), backward = walk(-1);
    final forwardUpper = _center(forward).dy < _center(backward).dy;
    return forwardUpper != lower ? forward : backward;
  }

  Offset corner(bool outer) {
    final upper = arc();
    return onRight == outer ? upper.last : upper.first;
  }
}

List<_Eye> _eyes(MakeupFaceGeometry photo) {
  final a = photo.region('eyeA'), b = photo.region('eyeB');
  final browsA = photo.region('browA'), browsB = photo.region('browB');
  if (a.isEmpty || b.isEmpty) return const [];
  return _center(a).dx < _center(b).dx
      ? [_Eye(a, browsA, false), _Eye(b, browsB, true)]
      : [_Eye(b, browsB, false), _Eye(a, browsA, true)];
}

List<Offset> _controls(
  MakeupFaceGeometry photo,
  MakeupDesign design,
  MakeupPart part,
) {
  final eyes = _eyes(photo);
  final style = design.layer(part).style;
  final axis = eyes.length == 2
      ? eyes[1].center - eyes[0].center
      : const Offset(1, 0);
  final right = _unit(Offset(axis.dx * photo.aspect, axis.dy));
  final down = Offset(-right.dy, right.dx);
  Offset faceOffset(double eyeWidth, double along, double below) {
    final value = (right * along + down * below) * (eyeWidth * photo.aspect);
    return Offset(value.dx / photo.aspect, value.dy);
  }

  return switch (part) {
    MakeupPart.foundation || MakeupPart.powder => _sample([
      ...photo.region('outline'),
      photo.region('outline').first,
    ], 17).take(16).toList(),
    MakeupPart.lipstick => _sample([
      ...photo.region('outerLips'),
      photo.region('outerLips').first,
    ], 13).take(12).toList(),
    MakeupPart.eyeCorner => [for (final eye in eyes) eye.corner(style == 1)],
    MakeupPart.brows => [
      for (final eye in eyes)
        if (eye.brow.length >= 4)
          ..._sample([...eye.brow, eye.brow.first], 7).take(6),
    ],
    MakeupPart.lashes ||
    MakeupPart.liner ||
    MakeupPart.shadow ||
    MakeupPart.doubleLid => [
      for (final eye in eyes)
        ..._sample(
          eye.arc(lower: part == MakeupPart.lashes && style == 5),
          5,
        ).asMap().entries.map((entry) {
          final t = math.sin(math.pi * entry.key / 4);
          final offset = switch (part) {
            MakeupPart.shadow => .12,
            MakeupPart.doubleLid => style == 1 ? .28 : .19,
            _ => 0.0,
          };
          return entry.value + faceOffset(eye.width, 0, -offset * t);
        }),
    ],
    MakeupPart.concealer ||
    MakeupPart.blush ||
    MakeupPart.contour ||
    MakeupPart.highlight => [
      for (final eye in eyes)
        eye.center +
            faceOffset(
              eye.width,
              (eye.onRight ? 1 : -1) * (part == MakeupPart.concealer ? 0 : .43),
              switch (part) {
                MakeupPart.concealer => .39,
                MakeupPart.blush => .93,
                MakeupPart.contour => 1.19,
                _ => .68,
              },
            ),
    ],
  };
}

List<Offset> makeupPoints(
  MakeupFaceGeometry photo,
  MakeupDesign design,
  MakeupPart part,
) {
  final points = _controls(photo, design, part);
  final offsets = design._points[part];
  if (offsets == null) return points;
  return [
    for (var i = 0; i < points.length; i++)
      points[i] + (offsets[i] ?? Offset.zero),
  ];
}

Path _curve(List<Offset> points, {bool closed = false}) {
  final path = Path();
  if (points.isEmpty) return path;
  path.moveTo(points.first.dx, points.first.dy);
  final size = points.length;
  Offset at(int i) => points[closed ? i % size : i.clamp(0, size - 1)];
  for (var i = 0; i < size - (closed ? 0 : 1); i++) {
    final a = at(i), b = at(i + 1);
    final controlA = a + (b - at(i - 1)) / 6;
    final controlB = b - (at(i + 2) - a) / 6;
    path.cubicTo(
      controlA.dx,
      controlA.dy,
      controlB.dx,
      controlB.dy,
      b.dx,
      b.dy,
    );
  }
  if (closed) path.close();
  return path;
}

Offset _unit(Offset vector) =>
    vector.distance > .0001 ? vector / vector.distance : Offset.zero;

void _softOval(
  Canvas canvas,
  Offset center,
  double rx,
  double ry,
  double angle,
  Color color,
  double opacity,
) {
  if (rx <= 0 || ry <= 0 || opacity <= 0) return;
  canvas.save();
  canvas.translate(center.dx, center.dy);
  canvas.rotate(angle);
  canvas.scale(rx, ry);
  final paint = Paint()
    ..shader = RadialGradient(
      colors: [
        color.withValues(alpha: opacity),
        color.withValues(alpha: opacity * .58),
        color.withValues(alpha: 0),
      ],
      stops: const [0, .51, 1],
    ).createShader(const Rect.fromLTWH(-1, -1, 2, 2));
  canvas.drawCircle(Offset.zero, 1, paint);
  paint.shader?.dispose();
  canvas.restore();
}

void _warpEye(
  Canvas canvas,
  Rect rect,
  MakeupPhoto photo,
  _Eye eye,
  Offset anchor,
  MakeupLayer effect,
) {
  final image = photo.image;
  final center = Offset(anchor.dx * image.width, anchor.dy * image.height);
  final width = eye.width * image.width;
  final radius = width * .47;
  if (radius < 3) return;
  final direction = (eye.onRight == (effect.style == 1) ? 1 : -1).toDouble();
  final source = <Offset>[], target = <Offset>[];
  final indices = <int>[];
  const grid = 12;
  for (var y = 0; y <= grid; y++) {
    for (var x = 0; x <= grid; x++) {
      final local = Offset(
        (x / grid * 2 - 1) * radius,
        (y / grid * 2 - 1) * radius,
      );
      final src = center + local;
      final envelope = (1 - local.distance / radius).clamp(0.0, 1.0);
      source.add(src);
      target.add(
        src +
            Offset(
              direction * width * .10 * effect.amount * envelope * envelope,
              0,
            ),
      );
      if (x < grid && y < grid) {
        final a = y * (grid + 1) + x, b = a + grid + 1;
        indices.addAll([a, a + 1, b, b, a + 1, b + 1]);
      }
    }
  }
  final vertices = ui.Vertices(
    ui.VertexMode.triangles,
    target,
    textureCoordinates: source,
    indices: indices,
  );
  final shader = ui.ImageShader(
    image,
    TileMode.clamp,
    TileMode.clamp,
    Matrix4.identity().storage,
    filterQuality: FilterQuality.low,
  );
  canvas.save();
  canvas.translate(rect.left, rect.top);
  canvas.scale(rect.width / image.width, rect.height / image.height);
  canvas.drawVertices(vertices, BlendMode.src, Paint()..shader = shader);
  canvas.restore();
  vertices.dispose();
  shader.dispose();
}

void _drawLashes(
  Canvas canvas,
  List<Offset> controls,
  double width,
  bool onRight,
  MakeupLayer effect,
) {
  final lower = effect.style == 5;
  final count = switch (effect.style) {
    2 => 13,
    3 => 31,
    5 => 16,
    6 => 18,
    7 => 24,
    8 => 19,
    9 => 26,
    _ => 22,
  };
  final metrics = _curve(controls).computeMetrics().iterator;
  if (!metrics.moveNext()) return;
  final curve = metrics.current;
  final outerDirection = onRight ? 1.0 : -1.0;
  for (var i = 1; i < count - 1; i++) {
    final t = i / (count - 1);
    final location = curve.getTangentForOffset(curve.length * t);
    if (location == null) continue;
    final towardOuter = onRight ? t : 1 - t;
    if (effect.style == 7 && towardOuter < .48) continue;
    final mid = math.sin(t * math.pi);
    final length =
        width *
        (.55 + .45 * effect.amount) *
        switch (effect.style) {
          1 => .07 + .28 * math.pow(towardOuter, 1.5),
          2 => .10 + .19 * mid * (i.isEven ? 1 : .44),
          3 => .13 + .25 * mid,
          4 => .08 + .31 * mid * mid,
          5 => .07 + .09 * mid,
          6 => .11 + .25 * mid * (i % 3 == 0 ? .78 : 1),
          7 => .08 + .25 * math.pow(towardOuter, 1.6),
          8 => .11 + .25 * mid * (i % 3 == 1 ? 1 : .56),
          9 => .07 + .09 * mid,
          _ => .09 + .15 * mid,
        };
    final root = location.position;
    final tangent = location.vector;
    final lashDirection = Offset(tangent.dy, -tangent.dx) * (lower ? -1 : 1);
    final swept = (t - .5) * .64 + outerDirection * .17;
    final tip = root + (tangent * swept + lashDirection) * length;
    final middle =
        root + (tangent * swept * .19 + lashDirection * .58) * length;
    final thickness =
        width *
        switch (effect.style) {
          3 => .018,
          2 || 8 => .014,
          6 => .007,
          9 => .008,
          _ => .010,
        } *
        (.44 + effect.amount * .56);
    final normal = _unit(Offset(-(tip - root).dy, (tip - root).dx)) * thickness;
    final path = Path()
      ..moveTo(root.dx - normal.dx, root.dy - normal.dy)
      ..quadraticBezierTo(
        middle.dx - normal.dx * .58,
        middle.dy - normal.dy * .58,
        tip.dx,
        tip.dy,
      )
      ..quadraticBezierTo(
        middle.dx + normal.dx * .64,
        middle.dy + normal.dy * .64,
        root.dx + normal.dx,
        root.dy + normal.dy,
      )
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..color = effect.color.withValues(
          alpha: effect.amount * (lower ? .68 : .82),
        ),
    );
  }
}

void paintMakeup(
  Canvas canvas,
  Rect photoRect,
  MakeupPhoto photo,
  MakeupDesign design,
) {
  final image = photo.image;
  final imageRect = Rect.fromLTWH(
    0,
    0,
    image.width.toDouble(),
    image.height.toDouble(),
  );
  canvas.save();
  canvas.clipRect(photoRect);
  canvas.drawImageRect(
    image,
    imageRect,
    photoRect,
    Paint()..filterQuality = FilterQuality.medium,
  );
  final corner = design.layer(MakeupPart.eyeCorner);
  if (corner.amount > 0) {
    final eyes = _eyes(photo);
    final anchors = makeupPoints(photo, design, MakeupPart.eyeCorner);
    for (var i = 0; i < eyes.length; i++) {
      _warpEye(canvas, photoRect, photo, eyes[i], anchors[i], corner);
    }
  }
  _paintCosmetics(canvas, photoRect, photo, design);
  canvas.restore();
}

/// Renders pigment only. A platform camera preview remains below the canvas.
/// Reflection is applied to all cosmetic geometry in one operation.
void paintLiveMakeup(
  Canvas canvas,
  Rect photoRect,
  MakeupFaceGeometry geometry,
  MakeupDesign design, {
  required bool mirrored,
}) {
  if (photoRect.isEmpty) return;
  canvas.save();
  canvas.clipRect(photoRect);
  if (mirrored) {
    canvas.translate(photoRect.left + photoRect.right, 0);
    canvas.scale(-1, 1);
  }
  _paintCosmetics(canvas, photoRect, geometry, design);
  canvas.restore();
}

void _paintCosmetics(
  Canvas canvas,
  Rect photoRect,
  MakeupFaceGeometry photo,
  MakeupDesign design,
) {
  if (MakeupPart.values.every((part) => design.layer(part).amount == 0)) return;
  MakeupLayer pigment(MakeupPart part) {
    final layer = design.layer(part);
    final tone = photo._tone;
    if (layer.amount == 0 || tone == null) return layer;
    final sample = tone.color;
    final luma = .2126 * sample.r + .7152 * sample.g + .0722 * sample.b;
    final base = HSLColor.fromColor(layer.color);
    final shift = ((luma - .62) * .57).clamp(-.23, .13) * tone.confidence;
    var color = base
        .withLightness((base.lightness + shift).clamp(.045, .94))
        .toColor();
    if (part == MakeupPart.foundation ||
        part == MakeupPart.concealer ||
        part == MakeupPart.powder) {
      color = Color.lerp(color, sample, .18 * tone.confidence)!;
    }
    return layer.copyWith(color: color);
  }

  Offset display(Offset p) => Offset(
    photoRect.left + p.dx * photoRect.width,
    photoRect.top + p.dy * photoRect.height,
  );
  List<Offset> points(MakeupPart part) =>
      makeupPoints(photo, design, part).map(display).toList();
  final eyes = _eyes(photo);
  final faceWidth = photo.faceWidth * photoRect.width;
  final outline = photo.region('outline').map(display).toList();
  Path skinMask(List<Offset> boundary) {
    final face = _curve(boundary, closed: true);
    for (final region in ['eyeA', 'eyeB', 'browA', 'browB', 'outerLips']) {
      final hole = photo.region(region).map(display).toList();
      if (hole.length > 2) {
        face.addPath(_curve(hole, closed: true), Offset.zero);
      }
    }
    return face..fillType = PathFillType.evenOdd;
  }

  final eyeRoll = eyes.length == 2
      ? (display(eyes[1].center) - display(eyes[0].center)).direction
      : 0.0;
  final faceDown = Offset(-math.sin(eyeRoll), math.cos(eyeRoll));
  final skin = skinMask(outline);
  for (final part in [
    MakeupPart.foundation,
    MakeupPart.concealer,
    MakeupPart.powder,
    MakeupPart.contour,
    MakeupPart.blush,
    MakeupPart.highlight,
  ]) {
    final layer = pigment(part);
    if (layer.amount == 0) continue;
    final anchors = points(part);
    if (part == MakeupPart.foundation || part == MakeupPart.powder) {
      final mask = skinMask(anchors);
      final bounds = mask.getBounds();
      canvas.save();
      canvas.clipPath(mask);
      final opacity =
          layer.amount * (part == MakeupPart.foundation ? .23 : .13);
      _softOval(
        canvas,
        bounds.center,
        bounds.width * .54,
        bounds.height * .59,
        eyeRoll,
        layer.color,
        opacity,
      );
      canvas.restore();
    } else {
      canvas.save();
      canvas.clipPath(skin);
      final (width, height, opacity) = switch (part) {
        MakeupPart.concealer => (.16, .075, .24),
        MakeupPart.contour => (.20, .085, .28),
        MakeupPart.blush => (.20, .115, .41),
        _ => (.135, .054, .25),
      };
      for (var i = 0; i < anchors.length; i++) {
        _softOval(
          canvas,
          anchors[i],
          faceWidth * width,
          faceWidth * height,
          eyeRoll + (i == 0 ? .29 : -.29),
          layer.color,
          opacity * layer.amount,
        );
      }
      canvas.restore();
    }
  }

  final brows = pigment(MakeupPart.brows);
  if (brows.amount > 0) {
    final anchors = points(MakeupPart.brows);
    for (var i = 0; i + 6 <= anchors.length; i += 6) {
      canvas.drawPath(
        _curve(anchors.sublist(i, i + 6), closed: true),
        Paint()
          ..color = brows.color.withValues(alpha: .37 * brows.amount)
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            math.max(.25, faceWidth * .003),
          ),
      );
    }
  }

  for (final part in [
    MakeupPart.shadow,
    MakeupPart.doubleLid,
    MakeupPart.liner,
    MakeupPart.lashes,
  ]) {
    final layer = pigment(part);
    if (layer.amount == 0) continue;
    final anchors = points(part);
    for (var i = 0; i < eyes.length; i++) {
      final eye = eyes[i];
      final width = eye.width * photoRect.width;
      final arc = anchors.sublist(i * 5, i * 5 + 5);
      if (width < 3) continue;
      if (part == MakeupPart.lashes) {
        _drawLashes(canvas, arc, width, eye.onRight, layer);
      } else if (part == MakeupPart.shadow) {
        canvas.save();
        canvas.clipPath(skin);
        for (var j = 0; j < arc.length; j++) {
          final intensity = j == 0 || j == arc.length - 1
              ? .13
              : layer.style == 1 && j == (eye.onRight ? 3 : 1)
              ? .40
              : .22;
          _softOval(
            canvas,
            arc[j] - faceDown * (width * .038),
            width * .27,
            width * .18,
            eyeRoll,
            layer.color,
            layer.amount * intensity,
          );
        }
        if (layer.style == 2) {
          _softOval(
            canvas,
            arc[2] - faceDown * (width * .045),
            width * .21,
            width * .10,
            eyeRoll,
            const Color(0xffecd1b6),
            layer.amount * .18,
          );
        }
        canvas.restore();
      } else {
        final isFold = part == MakeupPart.doubleLid;
        final stroke = Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = math.max(
            .48,
            width * (isFold ? .015 : .018 + layer.amount * .024),
          )
          ..color = layer.color.withValues(
            alpha: layer.amount * (isFold ? .58 : .89),
          );
        if (isFold) {
          stroke.maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            math.max(.3, width * .013),
          );
          final fold = _curve(arc);
          final shader = LinearGradient(
            colors: [
              stroke.color.withValues(alpha: 0),
              stroke.color,
              stroke.color.withValues(alpha: 0),
            ],
            stops: const [0, .50, 1],
          ).createShader(fold.getBounds().inflate(.5));
          canvas.drawPath(fold, stroke..shader = shader);
          shader.dispose();
        } else {
          final path = _curve(arc);
          canvas.drawPath(path, stroke);
          if (layer.style != 0) {
            final outer = eye.onRight ? arc.last : arc.first;
            final tip =
                outer +
                Offset(math.cos(eyeRoll), math.sin(eyeRoll)) *
                    (width * (eye.onRight ? 1 : -1) * .24 * layer.amount) -
                faceDown *
                    (width * (layer.style == 1 ? .13 : .05) * layer.amount);
            final wing = Path()
              ..moveTo(outer.dx, outer.dy - stroke.strokeWidth * .47)
              ..lineTo(tip.dx, tip.dy)
              ..lineTo(outer.dx, outer.dy + stroke.strokeWidth * .53)
              ..close();
            canvas.drawPath(wing, Paint()..color = stroke.color);
          }
        }
      }
    }
  }

  final lipstick = pigment(MakeupPart.lipstick);
  if (lipstick.amount > 0) {
    final outer = points(MakeupPart.lipstick);
    final left = outer.reduce((a, b) => a.dx < b.dx ? a : b);
    final right = outer.reduce((a, b) => a.dx > b.dx ? a : b);
    final across = _unit(right - left);
    final down = Offset(-across.dy, across.dx);
    double project(Offset p, Offset axis) => p.dx * axis.dx + p.dy * axis.dy;
    (double, double) extent(List<Offset> values, Offset axis) {
      final projected = values.map((p) => project(p, axis));
      return (projected.reduce(math.min), projected.reduce(math.max));
    }

    final (leftEdge, rightEdge) = extent(outer, across);
    final (topEdge, bottomEdge) = extent(outer, down);
    final width = rightEdge - leftEdge, height = bottomEdge - topEdge;
    if (width < 2 || height < 1) return;
    final center =
        across * ((leftEdge + rightEdge) / 2) +
        down * ((topEdge + bottomEdge) / 2);
    final angle = across.direction;
    var lip = _curve(outer, closed: true);
    final inner = photo.region('innerLips').map(display).toList();
    if (inner.length >= 5) {
      final (innerTop, innerBottom) = extent(inner, down);
      if (innerBottom - innerTop > math.max(.4, height * .14)) {
        lip = Path.combine(
          PathOperation.difference,
          lip,
          _curve(inner, closed: true),
        );
      }
    }
    canvas.save();
    canvas.clipPath(lip);
    final color = lipstick.color;
    if (lipstick.style == 2) {
      _softOval(
        canvas,
        center + down * (height * .035),
        width * .64,
        height * .61,
        angle,
        color,
        lipstick.amount * .63,
      );
    } else {
      canvas.drawPath(
        lip,
        Paint()
          ..color = color.withValues(alpha: lipstick.amount * .56)
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            math.max(.35, width * .018),
          ),
      );
    }
    _softOval(
      canvas,
      center + down * (height * .13),
      width * .46,
      height * .36,
      angle,
      color,
      lipstick.amount * .12,
    );
    final sheen = switch (lipstick.style) {
      1 => (.27, .13, .27),
      3 => (.32, .20, .16),
      4 => (.24, .075, .42),
      5 => (.29, .14, .18),
      _ => null,
    };
    if (sheen != null) {
      final (wide, tall, strength) = sheen;
      final sample = photo._tone?.color;
      final light = sample == null ? 1.0 : (.60 + .40 * sample.g);
      _softOval(
        canvas,
        center + down * (height * .24) - across * (width * .07),
        width * wide,
        height * tall,
        angle,
        Color.lerp(color, const Color(0xfffce0d1), .73)!,
        lipstick.amount * strength * light,
      );
      if (lipstick.style == 4) {
        _softOval(
          canvas,
          center + down * (height * .21) + across * (width * .16),
          width * .09,
          height * .059,
          angle,
          const Color(0xfffce9e0),
          lipstick.amount * .24 * light,
        );
      }
      if (lipstick.style == 5) {
        final sparkle = Paint()
          ..color = Color.lerp(
            color,
            const Color(0xffffeee2),
            .84,
          )!.withValues(alpha: lipstick.amount * .66 * light);
        // Fixed lip-space points follow the mouth without shimmering in place.
        for (final (x, y, radius) in const [
          (-.31, -.12, .009),
          (-.23, -.25, .014),
          (-.13, -.18, .010),
          (-.04, -.28, .013),
          (.06, -.17, .009),
          (.16, -.24, .015),
          (.28, -.12, .010),
          (-.28, .20, .011),
          (-.19, .32, .016),
          (-.10, .23, .010),
          (.00, .36, .017),
          (.11, .26, .012),
          (.20, .31, .015),
          (.29, .19, .010),
        ]) {
          canvas.drawCircle(
            center + across * (width * x) + down * (height * y),
            math.max(.37, width * radius),
            sparkle,
          );
        }
      }
    }
    canvas.restore();
  }
}
