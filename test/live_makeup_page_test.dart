import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_nail_demo/screens/live_makeup_page.dart';
import 'package:offline_nail_demo/services/photo_makeup.dart';
import 'package:offline_nail_demo/widgets/makeup_catalog_picker.dart';

void main() {
  test('grouped products expose every shade exactly once', () {
    for (final part in [
      MakeupPart.blush,
      MakeupPart.shadow,
      MakeupPart.lipstick,
    ]) {
      final indices = part.shadeFamilies.expand((family) => family.$2).toList()
        ..sort();
      expect(indices, List.generate(part.palette.length, (index) => index));
    }
  });

  testWidgets('a lip shade is reachable directly by family', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Color? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MakeupShadePicker(
            part: MakeupPart.lipstick,
            selectedColor: selected,
            onSelect: (color) => selected = color,
          ),
        ),
      ),
    );
    expect(find.text('港红'), findsNothing);
    await tester.tap(find.text('红调'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('港红'));
    expect(selected, MakeupPart.lipstick.palette[26]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'live looks wait for a current face and refresh on mirror change',
    (tester) async {
      const channel = MethodChannel('test/live_makeup');
      final frames = StreamController<dynamic>(sync: true);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      late int session;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (_) async => null,
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'startMakeup') {
          session = (call.arguments as Map)['sessionId'] as int;
          return {'mirrored': false, 'width': 480, 'height': 640};
        }
        if (call.method == 'setPhotoPreviewDirection') {
          return (call.arguments as Map)['mirrored'];
        }
        return null;
      });
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        await frames.close();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: LiveMakeupPage(
            cameraChannel: channel,
            cameraEvents: frames.stream,
            previewBuilder: (_, created) => _TestPreview(created),
          ),
        ),
      );
      for (var step = 0; step < 5; step++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
      }
      expect(calls, ['stop', 'startMakeup']);
      expect(find.text('请保持单人入镜'), findsOneWidget);

      List<List<double>> oval(double x, double y, double w, double h) => [
        for (var i = 0; i < 8; i++)
          [
            x + w * math.cos(i * math.pi / 4),
            y + h * math.sin(i * math.pi / 4),
          ],
      ];
      Map<String, Object> face(
        int timestamp, {
        bool mirrored = false,
        int? sessionId,
        int count = 1,
      }) => {
        'type': 'frame',
        'sessionId': sessionId ?? session,
        'timestampMs': timestamp,
        'width': 480,
        'height': 640,
        'faceCount': count,
        'mirrored': mirrored,
        'face': {'yaw': 0},
        'makeupRegions': {
          'outline': oval(.50, .50, .22, .30),
          'eyeA': oval(.40, .46, .05, .018),
          'eyeB': oval(.60, .46, .05, .018),
          'outerLips': oval(.50, .62, .076, .026),
        },
      };
      frames.add(face(100, sessionId: session - 1));
      await tester.pump();
      expect(find.text('原肤 · 选择妆造开始'), findsNothing);

      frames.add(face(110));
      await tester.pump();
      expect(find.text('原肤 · 选择妆造开始'), findsOneWidget);
      await tester.tap(find.text('清透日常'));
      await tester.pump();
      expect(find.text('实时妆效'), findsOneWidget);
      expect(calls, ['stop', 'startMakeup']);

      await tester.tap(find.text('光泽'));
      await tester.pump();
      expect(find.text('清透日常'), findsNothing);
      expect(find.text('实时妆效'), findsOneWidget);
      await tester.tap(find.text('莓果釉光'));
      await tester.pump();
      await tester.tap(find.text('秋冬新妆'));
      await tester.pump();
      final seasonalLook = find.text('森绿珊瑚');
      final selectedCard = find.ancestor(
        of: seasonalLook,
        matching: find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.selected == true,
        ),
      );
      expect(find.text('实时妆效'), findsOneWidget);
      expect(selectedCard, findsNothing);
      await tester.tap(seasonalLook);
      await tester.pump();
      expect(selectedCard, findsOneWidget);
      await tester.tap(find.text('风格妆'));
      await tester.pump();
      await tester.tap(find.text('千金妆'));
      await tester.pump();
      await tester.tap(find.text('节日妆'));
      await tester.pump();
      await tester.tap(find.text('粉晶微闪'));
      await tester.pump();
      expect(find.text('实时妆效'), findsOneWidget);
      final intensity = find.byKey(const ValueKey('makeup-look-strength'));
      expect(tester.widget<Slider>(intensity).value, 1);
      tester.widget<Slider>(intensity).onChanged!(.42);
      await tester.pump();
      expect(tester.widget<Slider>(intensity).value, closeTo(.42, .0001));
      expect(find.text('42%'), findsOneWidget);
      await tester.tap(find.text('对比原肤'));
      await tester.pump();
      expect(find.text('原肤对比'), findsOneWidget);
      await tester.tap(find.text('查看妆效'));
      await tester.pump();
      expect(find.text('实时妆效'), findsOneWidget);
      expect(calls, ['stop', 'startMakeup']);

      await tester.tap(find.byTooltip('左右翻转取景'));
      await tester.pumpAndSettle();
      expect(calls.last, 'setPhotoPreviewDirection');
      final mirrorButton = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == '左右翻转取景',
        ),
      );
      expect(mirrorButton.isSelected, isTrue);
      expect(find.text('实时妆效'), findsNothing);
      frames.add(face(120));
      await tester.pump();
      expect(find.text('实时妆效'), findsNothing);
      frames.add(face(130, mirrored: true));
      await tester.pump();
      expect(find.text('实时妆效'), findsOneWidget);

      frames.add(face(140, mirrored: true, count: 2));
      await tester.pump();
      expect(find.text('检测到多张脸，请单人试妆'), findsOneWidget);
      expect(find.text('实时妆效'), findsNothing);

      // Android can report its pause after the framework is already resumed.
      final interruptedSession = session;
      frames.add({
        'type': 'status',
        'status': 'paused',
        'sessionId': interruptedSession,
      });
      await tester.pumpAndSettle();
      expect(session, isNot(interruptedSession));
      expect(calls.where((call) => call == 'startMakeup').length, 2);
      frames.add(face(150, mirrored: true, sessionId: interruptedSession));
      await tester.pump();
      expect(find.text('实时妆效'), findsNothing);
      frames.add(face(160));
      await tester.pump();
      expect(find.text('实时妆效'), findsOneWidget);
      expect(tester.widget<Slider>(intensity).value, closeTo(.42, .0001));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(calls.last, 'stop');
      expect(tester.takeException(), isNull);
    },
  );
}

class _TestPreview extends StatefulWidget {
  const _TestPreview(this.onCreated);

  final PlatformViewCreatedCallback onCreated;

  @override
  State<_TestPreview> createState() => _TestPreviewState();
}

class _TestPreviewState extends State<_TestPreview> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onCreated(1);
    });
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.grey);
}
