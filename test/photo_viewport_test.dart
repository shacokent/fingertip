import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_nail_demo/widgets/photo_viewport.dart';

void main() {
  testWidgets('panning a photo keeps the surrounding controls stationary', (
    tester,
  ) async {
    final controller = TransformationController();
    final scroll = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            height: 450,
            child: SingleChildScrollView(
              controller: scroll,
              child: Column(
                children: [
                  SizedBox(
                    height: 350,
                    child: PhotoViewport(
                      controller: controller,
                      child: const ColoredBox(color: Colors.white),
                    ),
                  ),
                  const SizedBox(height: 350),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.drag(find.byType(PhotoViewport), const Offset(0, -90));
    await tester.pumpAndSettle();
    expect(controller.value.entry(1, 3), lessThan(-10));
    expect(scroll.offset, 0);
    await _close(tester, controller);
    scroll.dispose();
  });

  testWidgets('two fingers zoom and rotate without dragging the edited nail', (
    tester,
  ) async {
    final controller = TransformationController();
    var edited = 0;
    await _open(tester, controller, onSceneDrag: (_) => edited++);
    final center = tester.getCenter(find.byType(PhotoViewport));
    final first = await tester.createGesture(pointer: 1);
    final second = await tester.createGesture(pointer: 2);
    await first.down(center + const Offset(-30, 0));
    await second.down(center + const Offset(30, 0));
    await tester.pump();
    await first.moveTo(center + const Offset(-50, -30));
    await second.moveTo(center + const Offset(50, 30));
    await tester.pump();
    await first.moveTo(center + const Offset(-65, -55));
    await second.moveTo(center + const Offset(65, 55));
    await tester.pump();
    expect(controller.value.getMaxScaleOnAxis(), greaterThan(1.3));
    expect(controller.value.entry(1, 0).abs(), greaterThan(.2));
    expect(edited, 0);

    // Finishing a pinch with one finger should pan the view, not move a nail.
    await second.up();
    await first.moveBy(const Offset(25, 10));
    await tester.pump();
    await first.moveBy(const Offset(25, 10));
    await tester.pump();
    await first.up();
    expect(edited, 0);
    await _close(tester, controller);
  });

  testWidgets('tap and nail drags use the full inverse view transform', (
    tester,
  ) async {
    final controller = TransformationController(
      Matrix4.identity()
        ..translateByDouble(150, 200, 0, 1)
        ..rotateZ(math.pi / 2)
        ..scaleByDouble(2, 2, 1, 1)
        ..translateByDouble(-150, -200, 0, 1),
    );
    Offset? tapped;
    final deltas = <Offset>[];
    var starts = 0;
    await _open(
      tester,
      controller,
      onTap: (point) => tapped = point,
      onSceneDrag: deltas.add,
      onSceneDragStart: () => starts++,
    );
    final rect = tester.getRect(find.byType(PhotoViewport));
    const scenePoint = Offset(160, 210);
    final displayed = MatrixUtils.transformPoint(controller.value, scenePoint);
    await tester.tapAt(rect.topLeft + displayed);
    expect(tapped!.dx, closeTo(scenePoint.dx, .001));
    expect(tapped!.dy, closeTo(scenePoint.dy, .001));
    await tester.dragFrom(rect.center, const Offset(60, 0));
    final movement = deltas.fold(Offset.zero, (sum, delta) => sum + delta);
    expect(starts, 1);
    expect(movement.dx, closeTo(0, .001));
    expect(movement.dy, lessThan(-10));
    expect(controller.value.getMaxScaleOnAxis(), closeTo(2, .001));
    await _close(tester, controller);
  });

  testWidgets('pinch clamps zoom and letterbox taps do not edit the photo', (
    tester,
  ) async {
    final controller = TransformationController();
    var taps = 0;
    await _open(
      tester,
      controller,
      onTap: (_) => taps++,
      bounds: const Rect.fromLTWH(50, 40, 200, 300),
    );
    final rect = tester.getRect(find.byType(PhotoViewport));
    await tester.tapAt(rect.topLeft + const Offset(15, 15));
    expect(taps, 0);
    await tester.tapAt(rect.center);
    expect(taps, 1);
    final gestures = tester.widget<GestureDetector>(
      find.byKey(const ValueKey('photo-view-gestures')),
    );
    gestures.onScaleStart!(
      ScaleStartDetails(
        localFocalPoint: const Offset(150, 200),
        pointerCount: 2,
      ),
    );
    gestures.onScaleUpdate!(
      ScaleUpdateDetails(
        localFocalPoint: const Offset(150, 200),
        pointerCount: 2,
        scale: 100,
      ),
    );
    expect(controller.value.getMaxScaleOnAxis(), closeTo(8, .001));
    gestures.onScaleUpdate!(
      ScaleUpdateDetails(
        localFocalPoint: const Offset(150, 200),
        pointerCount: 2,
        scale: .001,
      ),
    );
    final matrix = controller.value;
    expect(
      math.sqrt(
        matrix.entry(0, 0) * matrix.entry(0, 0) +
            matrix.entry(1, 0) * matrix.entry(1, 0),
      ),
      closeTo(.5, .001),
    );
    await _close(tester, controller);
  });
}

Future<void> _open(
  WidgetTester tester,
  TransformationController controller, {
  ValueChanged<Offset>? onTap,
  ValueChanged<Offset>? onSceneDrag,
  VoidCallback? onSceneDragStart,
  Rect? bounds,
}) => tester.pumpWidget(
  MaterialApp(
    home: Center(
      child: SizedBox(
        width: 300,
        height: 400,
        child: PhotoViewport(
          controller: controller,
          onTap: onTap,
          onSceneDrag: onSceneDrag,
          onSceneDragStart: onSceneDragStart,
          interactionBounds: bounds,
          child: const ColoredBox(color: Colors.white),
        ),
      ),
    ),
  ),
);

Future<void> _close(
  WidgetTester tester,
  TransformationController controller,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
}
