import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() async => integrationDriver(
  responseDataCallback: (data) async {
    if (data == null) return;
    final folder = Directory(
      Platform.environment['NAIL_QA_OUTPUT'] ?? 'build/controls_qa',
    );
    await folder.create(recursive: true);
    const screenshots = {
      'controls_home_version',
      'controls_light_left',
      'controls_light_right',
      'controls_transformed',
      'controls_reset',
    };
    for (final raw in data['screenshots'] as List? ?? const []) {
      final shot = Map<String, dynamic>.from(raw as Map);
      final name = shot['screenshotName'];
      if (name is String && screenshots.contains(name)) {
        await File(
          '${folder.path}/$name.png',
        ).writeAsBytes((shot['bytes'] as List).cast<int>());
      }
    }
    for (final entry in (data['exports'] as Map? ?? const {}).entries) {
      if (!{'demo_lamp_left', 'demo_lamp_right'}.contains(entry.key)) continue;
      await File(
        '${folder.path}/${entry.key}.png',
      ).writeAsBytes(base64Decode(entry.value as String));
    }
    await File('${folder.path}/controls_validation.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(data['controlsMetrics']),
    );
  },
);
