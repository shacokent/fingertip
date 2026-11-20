import 'dart:convert';
import 'dart:io';
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() async {
  await integrationDriver(
    responseDataCallback: (data) async {
      if (data == null) return;
      final folder = Directory(
        Platform.environment['NAIL_QA_OUTPUT'] ?? 'build/qa',
      );
      await folder.create(recursive: true);
      for (final raw in data['screenshots'] as List? ?? const []) {
        final shot = Map<String, dynamic>.from(raw as Map);
        final bytes = (shot['bytes'] as List).cast<int>();
        final name = shot['screenshotName'] == 'nail_home'
            ? 'preview_home.png'
            : 'preview_editor.png';
        await File('${folder.path}/$name').writeAsBytes(bytes);
      }
      final exports = data['exports'] as Map? ?? const {};
      for (final entry in exports.entries) {
        final name = entry.key as String;
        if (name != 'demo_rose' && name != 'demo_wine') continue;
        await File(
          '${folder.path}/$name.png',
        ).writeAsBytes(base64Decode(entry.value as String));
      }
      await File('${folder.path}/ios_validation.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert(data['metrics']),
      );
    },
  );
}
