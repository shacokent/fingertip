import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_nail_demo/main.dart';
import 'package:offline_nail_demo/screens/live_makeup_page.dart';
import 'package:offline_nail_demo/screens/nail_home_page.dart';

void main() {
  const versionChannel = MethodChannel('offline_nail/app_info');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(versionChannel, (call) async {
          expect(call.method, 'getVersion');
          return '9.8.7';
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(versionChannel, null);
  });

  testWidgets('brand chooser keeps logo privacy version and two modules', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const NailStudioApp());
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    final logo = tester.widget<Image>(find.byType(Image));
    expect((logo.image as AssetImage).assetName, 'assets/branding/logo.jpg');
    expect(find.text('美甲'), findsOneWidget);
    expect(find.text('美妆'), findsOneWidget);
    expect(find.text('拍照试戴'), findsNothing);
    expect(find.text('从相册选择'), findsNothing);
    expect(find.byKey(const ValueKey('home-privacy-notice')), findsOneWidget);
    expect(find.textContaining('完全离线运行，不联网'), findsOneWidget);
    expect(find.textContaining('不收集或上传'), findsOneWidget);
    expect(find.text('版本 9.8.7'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'home does not initialize vision or camera and nail entry preserves capture flow',
    (tester) async {
      var recognitionCalls = 0, beautyCalls = 0;
      const hands = MethodChannel('offline_nail/hand_landmarker');
      const beauty = MethodChannel('yuying/beauty');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hands, (_) async {
            recognitionCalls++;
            return {};
          });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(beauty, (_) async {
            beautyCalls++;
            return {};
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(hands, null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(beauty, null);
      });
      await tester.pumpWidget(const NailStudioApp());
      await tester.pumpAndSettle();
      expect(find.text('用示例体验'), findsNothing);
      expect(find.text('手形引导'), findsNothing);
      expect(find.byIcon(Icons.info_outline_rounded), findsNothing);
      expect(recognitionCalls, 0);
      expect(beautyCalls, 0);
      await tester.tap(find.byKey(const ValueKey('home-nails')));
      await tester.pumpAndSettle();
      expect(find.byType(NailHomePage), findsOneWidget);
      expect(find.text('拍照试戴'), findsOneWidget);
      expect(find.text('从相册选择'), findsOneWidget);
      expect(beautyCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'module chooser remains scrollable on a short large text display',
    (tester) async {
      tester.view.physicalSize = const Size(320, 420);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
          child: const NailStudioApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('home-beauty')));
      expect(find.text('美妆'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('beauty entry offers live makeup and a gallery fallback', (
    tester,
  ) async {
    final calls = <String>[];
    const face = MethodChannel('yuying/beauty');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(face, (call) async {
          calls.add(call.method);
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(face, null);
    });
    await tester.pumpWidget(const NailStudioApp());
    await tester.pumpAndSettle();
    expect(find.text('实时试妆 · 妆造与美睫'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('home-beauty')));
    await tester.pumpAndSettle();
    expect(find.byType(LiveMakeupPage), findsOneWidget);
    expect(find.byTooltip('从相册选择'), findsOneWidget);
    final compare = find.widgetWithText(OutlinedButton, '对比原肤');
    expect(compare, findsOneWidget);
    expect(tester.widget<OutlinedButton>(compare).onPressed, isNull);
    await tester.tap(find.text('清透日常'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<OutlinedButton>(compare).onPressed,
      isNotNull,
    );
    expect(calls, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
