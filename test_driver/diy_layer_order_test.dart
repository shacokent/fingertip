import 'dart:convert';
import 'dart:io';
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() async => integrationDriver(
  responseDataCallback: (data) async {
    if (data == null) return;
    final folder = Directory(
      Platform.environment['NAIL_QA_OUTPUT'] ?? 'build/layer_order_qa',
    );
    await folder.create(recursive: true);
    for (final raw in data['screenshots'] as List? ?? const []) {
      final shot = Map<String, dynamic>.from(raw as Map);
      final name = shot['screenshotName'];
      if (name == 'layers_image_above' || name == 'layers_ink_above') {
        await File(
          '${folder.path}/$name.png',
        ).writeAsBytes((shot['bytes'] as List).cast<int>());
      }
    }
    for (final entry in (data['layerExports'] as Map? ?? const {}).entries) {
      if (entry.key == 'layers_saved_design' ||
          entry.key == 'layers_eraser_protection') {
        await File(
          '${folder.path}/${entry.key}.png',
        ).writeAsBytes(base64Decode(entry.value as String));
      }
    }
    await File('${folder.path}/layer_order_validation.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(data['layerMetrics']),
    );
  },
);
