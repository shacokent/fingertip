import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'screens/home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Nail segmentation model & sample',
    ], await rootBundle.loadString('assets/licenses/nail_model.txt'));
    yield LicenseEntryWithLineBreaks([
      'Google MediaPipe Hand and Face Landmarker',
    ], await rootBundle.loadString('assets/models/MEDIAPIPE_LICENSE.txt'));
  });
  runApp(const NailStudioApp());
}

class NailStudioApp extends StatelessWidget {
  const NailStudioApp({super.key});
  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF7A3F4E);
    return MaterialApp(
      title: '煜莹',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.light,
          surface: const Color(0xFFF8F5F3),
        ),
        scaffoldBackgroundColor: const Color(0xFFF8F5F3),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF8F5F3),
          surfaceTintColor: Colors.transparent,
          centerTitle: false,
        ),
        textTheme: const TextTheme(
          bodySmall: TextStyle(color: Color(0xFF81767B), height: 1.5),
          bodyMedium: TextStyle(color: Color(0xFF30262D), height: 1.5),
        ),
        sliderTheme: const SliderThemeData(trackHeight: 3),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 17),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
          ),
        ),
      ),
      home: const HomePage(),
    );
  }
}
