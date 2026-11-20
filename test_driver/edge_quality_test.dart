import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() async => integrationDriver(
  responseDataCallback: (data) async {
    if (data == null) return;
    final folder = Directory(
      Platform.environment['NAIL_QA_OUTPUT'] ?? 'build/edge_quality_qa',
    );
    await folder.create(recursive: true);
    for (final raw in data['screenshots'] as List? ?? const []) {
      final shot = Map<String, dynamic>.from(raw as Map);
      if (shot['screenshotName'] == 'edge_editor_after') {
        await File(
          '${folder.path}/edge_editor_after.png',
        ).writeAsBytes((shot['bytes'] as List).cast<int>());
      }
    }
    for (final entry in (data['exports'] as Map? ?? const {}).entries) {
      final name = entry.key as String;
      if (!RegExp(
        r'^edge_(before|after|variant_(030|032|034|038))_(mask(_[0-9]+)?|wine|diy)$',
      ).hasMatch(name)) {
        continue;
      }
      await File(
        '${folder.path}/$name.png',
      ).writeAsBytes(base64Decode(entry.value as String));
    }
    await File('${folder.path}/edge_native_validation.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(data['edgeMetrics']),
    );
  },
);
