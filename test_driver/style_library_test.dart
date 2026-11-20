import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() async {
  await integrationDriver(
    responseDataCallback: (data) async {
      if (data == null) return;
      final directory = Directory(
        Platform.environment['NAIL_QA_OUTPUT'] ?? 'build/style_library_qa',
      );
      await directory.create(recursive: true);
      for (final raw in data['screenshots'] as List? ?? const []) {
        final shot = Map<String, dynamic>.from(raw as Map);
        final name = shot['screenshotName'];
        if (name != 'style_library_botanical' &&
            name != 'style_applied_flowers') {
          continue;
        }
        await File(
          '${directory.path}/$name.png',
        ).writeAsBytes((shot['bytes'] as List).cast<int>());
      }
      for (final entry in (data['exports'] as Map? ?? const {}).entries) {
        if (entry.key != 'style_catalog' && entry.key != 'demo_flowers') {
          continue;
        }
        await File(
          '${directory.path}/${entry.key}.png',
        ).writeAsBytes(base64Decode(entry.value as String));
      }
      await File(
        '${directory.path}/style_library_validation.json',
      ).writeAsString(
        const JsonEncoder.withIndent('  ').convert(data['styleMetrics']),
      );
    },
  );
}
