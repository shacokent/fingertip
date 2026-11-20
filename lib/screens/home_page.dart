import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'live_makeup_page.dart';
import 'nail_home_page.dart';

/// The brand chooser deliberately does not initialize either vision engine.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? _version = '0.19.1';

  @override
  void initState() {
    super.initState();
    unawaited(_loadVersion());
  }

  Future<void> _loadVersion() async {
    try {
      final value = await const MethodChannel(
        'offline_nail/app_info',
      ).invokeMethod<String>('getVersion');
      if (mounted && value != null && value.trim().isNotEmpty) {
        setState(() => _version = value.trim());
      }
    } on PlatformException {
      // Metadata is optional on development hosts.
    } on MissingPluginException {
      // Android and iOS register this channel.
    }
  }

  void _open(Widget page) {
    Navigator.push<void>(context, MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.white,
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  'assets/branding/logo.jpg',
                  width: 210,
                  height: 210,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.high,
                  semanticLabel: '主页 Logo',
                ),
                const SizedBox(height: 36),
                _module(
                  key: const ValueKey('home-nails'),
                  title: '美甲',
                  subtitle: '换款试戴 · 自由 DIY',
                  icon: Icons.back_hand_outlined,
                  onTap: () => _open(const NailHomePage()),
                ),
                const SizedBox(height: 12),
                _module(
                  key: const ValueKey('home-beauty'),
                  title: '美妆',
                  subtitle: '实时试妆 · 妆造与美睫',
                  icon: Icons.face_retouching_natural_outlined,
                  onTap: () => _open(const LiveMakeupPage()),
                ),
                const SizedBox(height: 24),
                Container(
                  key: const ValueKey('home-privacy-notice'),
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFAF7F6),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '免责声明与隐私说明',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF705860),
                        ),
                      ),
                      SizedBox(height: 7),
                      Text(
                        '本应用完全离线运行，不联网，不收集或上传个人信息、照片及使用数据。'
                        '照片、自拍效果和 DIY 作品由本应用在本机处理与保存。'
                        '主动导出或分享的内容由您选择的应用处理。'
                        '试戴效果仅供参考。',
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.7,
                          color: Color(0xFF8D7C82),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_version != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    '版本 $_version',
                    key: const ValueKey('home-app-version'),
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF9A8B90),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _module({
    required Key key,
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback onTap,
  }) => Material(
    key: key,
    color: const Color(0xFFFAF4F2),
    borderRadius: BorderRadius.circular(20),
    child: InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        child: Row(
          children: [
            Icon(icon, size: 28, color: const Color(0xFF7A3F4E)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF8D7C82),
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: Color(0xFF9A8B90)),
          ],
        ),
      ),
    ),
  );
}
