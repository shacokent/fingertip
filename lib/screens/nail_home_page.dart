import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import '../services/nail_analysis.dart';
import 'camera_page.dart';
import 'editor_page.dart';

class NailHomePage extends StatefulWidget {
  const NailHomePage({super.key});
  @override
  State<NailHomePage> createState() => _NailHomePageState();
}

class _NailHomePageState extends State<NailHomePage> {
  final _engine = NailAnalysisEngine();
  bool _busy = false;
  String? _version;
  String _stage = '正在识别甲面';

  @override
  void initState() {
    super.initState();
    unawaited(_loadVersion());
  }

  Future<void> _loadVersion() async {
    try {
      final version = await const MethodChannel(
        'offline_nail/app_info',
      ).invokeMethod<String>('getVersion');
      if (mounted && version != null && version.trim().isNotEmpty) {
        setState(() => _version = version.trim());
      }
    } on PlatformException {
      // Version metadata is optional on unsupported development targets.
    } on MissingPluginException {
      // Android and iOS provide this channel; widget-only hosts do not.
    }
  }

  Future<void> _camera() async {
    if (_busy) return;
    final path = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const CameraPage()),
    );
    if (!mounted || path == null) return;
    try {
      await _analyze(await File(path).readAsBytes());
    } on FileSystemException {
      if (mounted) _error('照片文件无法读取，请重新拍摄。');
    }
  }

  Future<void> _gallery() async {
    if (_busy) return;
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 2000,
        maxHeight: 2000,
        imageQuality: 95,
        requestFullMetadata: false,
      );
      if (!mounted || file == null) return;
      await _analyze(await file.readAsBytes());
    } on PlatformException {
      if (mounted) _error('无法打开相册，请检查权限后重试。');
    } on FileSystemException {
      if (mounted) _error('图片无法读取，请选择其他照片。');
    }
  }

  Future<void> _analyze(Uint8List bytes) async {
    if (_busy || !mounted) return;
    setState(() {
      _busy = true;
      _stage = '正在识别甲面';
    });
    try {
      final result = await _engine.analyze(
        bytes,
        onStage: (stage) {
          if (mounted && _busy) setState(() => _stage = stage);
        },
      );
      if (!mounted) return;
      setState(() => _busy = false);
      await Navigator.push<void>(
        context,
        MaterialPageRoute(builder: (_) => EditorPage(analysis: result)),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        await _error(
          e is FormatException
              ? '${e.message}\n\n请重新拍摄，或从相册选择其他照片。'
              : '暂时无法完成识别。请重试，或换一张指甲清晰、无遮挡的照片。',
        );
      }
    }
  }

  Future<void> _error(String text) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('请再试一次'),
      content: Text(text),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('知道了'),
        ),
      ],
    ),
  );

  @override
  void dispose() {
    _engine.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(title: const Text('美甲')),
      body: Stack(
        children: [
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 28,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
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
                      const SizedBox(height: 64),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _busy ? null : _camera,
                          icon: const Icon(Icons.camera_alt_outlined, size: 20),
                          label: const Text(
                            '拍照试戴',
                            style: TextStyle(fontSize: 16),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _busy ? null : _gallery,
                          icon: const Icon(
                            Icons.photo_library_outlined,
                            size: 19,
                          ),
                          label: const Text('从相册选择'),
                        ),
                      ),
                      const SizedBox(height: 26),
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
                              '照片和 DIY 作品由本应用在本机处理与保存。'
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
                        const SizedBox(height: 18),
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
          if (_busy)
            Positioned.fill(
              child: ColoredBox(
                color: const Color(0xF5FFFFFF),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 42,
                        height: 42,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        _stage,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
