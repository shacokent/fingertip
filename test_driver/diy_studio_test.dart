import 'dart:convert';
import 'dart:io';
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() async => integrationDriver(
  responseDataCallback: (data) async {
    if (data == null) return;
    final folder = Directory(
      Platform.environment['NAIL_QA_OUTPUT'] ?? 'build/diy_qa',
    );
    await folder.create(recursive: true);
    const screenshots = {'diy_studio', 'diy_try_on', 'manual_nail_refinement'};
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
      if (!{
        'diy_design_example',
        'demo_diy_try_on',
        'diy_materials',
      }.contains(entry.key)) {
        continue;
      }
      await File(
        '${folder.path}/${entry.key}.png',
      ).writeAsBytes(base64Decode(entry.value as String));
    }
    await File('${folder.path}/diy_validation.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(data['diyMetrics']),
    );
  },
);
