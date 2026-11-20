import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() async {
  await integrationDriver(
    responseDataCallback: (data) async {
      if (data == null) return;
      final folder = Directory(
        Platform.environment['NAIL_QA_OUTPUT'] ?? 'build/live_preview_qa',
      );
      await folder.create(recursive: true);
      const screenshotNames = {'live_preview_detected', 'live_preview_empty'};
      for (final raw in data['screenshots'] as List? ?? const []) {
        final shot = Map<String, dynamic>.from(raw as Map);
        final name = shot['screenshotName'];
        if (name is! String || !screenshotNames.contains(name)) continue;
        final bytes = (shot['bytes'] as List).cast<int>();
        await File('${folder.path}/$name.png').writeAsBytes(bytes);
      }
      await File('${folder.path}/live_preview_validation.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert(data['previewMetrics']),
      );
    },
  );
}
