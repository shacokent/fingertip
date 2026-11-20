import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() async => integrationDriver(
  responseDataCallback: (data) async {
    if (data == null) return;
    final folder = Directory(
      Platform.environment['NAIL_QA_OUTPUT'] ?? 'build/material_qa',
    );
    await folder.create(recursive: true);
    for (final raw in data['screenshots'] as List? ?? const []) {
      final shot = Map<String, dynamic>.from(raw as Map);
      final name = shot['screenshotName'];
      if (name is String &&
          {
            'material_editor_glitter',
            'material_editor_cat_eye',
          }.contains(name)) {
        await File(
          '${folder.path}/$name.png',
        ).writeAsBytes((shot['bytes'] as List).cast<int>());
      }
    }
    for (final entry in (data['exports'] as Map? ?? const {}).entries) {
      if (!{
        'material_glitter_sheet',
        'material_cat_eye_sheet',
        'material_photo_comparison',
        'material_photo_glitter_left',
        'material_photo_glitter_right',
        'material_photo_cat_eye_left',
        'material_photo_cat_eye_right',
      }.contains(entry.key)) {
        continue;
      }
      await File(
        '${folder.path}/${entry.key}.png',
      ).writeAsBytes(base64Decode(entry.value as String));
    }
    await File('${folder.path}/material_validation.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(data['materialMetrics']),
    );
  },
);
