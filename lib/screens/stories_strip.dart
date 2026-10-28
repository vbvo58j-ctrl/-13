import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';

/// Local story strip with 24-hour expiry. Stories are stored on this device;
/// cross-device delivery requires a transport/backend and is not implied here.
class StoriesStrip extends StatefulWidget {
  final String userName;
  final String profilePhotoPath;
  const StoriesStrip({super.key, required this.userName, required this.profilePhotoPath});

  @override
  State<StoriesStrip> createState() => _StoriesStripState();
}

class _StoriesStripState extends State<StoriesStrip> {
  static const _storageKey = 'blousab_stories_v1';
  final ImagePicker _picker = ImagePicker();
  List<Map<String, dynamic>> _stories = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadStories();
  }

  Future<void> _loadStories() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_storageKey) ?? <String>[];
    final loaded = <Map<String, dynamic>>[];
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final item in raw) {
      try {
        final map = Map<String, dynamic>.from(jsonDecode(item) as Map);
        final created = (map['createdAt'] as num?)?.toInt() ?? 0;
        final path = map['path']?.toString() ?? '';
        if (now - created < const Duration(hours: 24).inMilliseconds && File(path).existsSync()) {
          loaded.add(map);
        } else if (path.isNotEmpty) {
          try { await File(path).delete(); } catch (_) {}
        }
      } catch (_) {}
    }
    await prefs.setStringList(_storageKey, loaded.map(jsonEncode).toList());
    if (mounted) setState(() => _stories = loaded..sort((a, b) => ((b['createdAt'] as num?)?.toInt() ?? 0).compareTo((a['createdAt'] as num?)?.toInt() ?? 0)));
  }

  Future<void> _createStory() async {
    if (_busy) return;
    final source = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(leading: const Icon(Icons.photo_library_outlined), title: const Text('اختيار صورة من المعرض'), onTap: () => Navigator.pop(ctx, 'image_gallery')),
        ListTile(leading: const Icon(Icons.photo_camera_outlined), title: const Text('التقاط صورة بالكاميرا'), onTap: () => Navigator.pop(ctx, 'image_camera')),
        ListTile(leading: const Icon(Icons.video_library_outlined), title: const Text('اختيار فيديو من المعرض'), onTap: () => Navigator.pop(ctx, 'video_gallery')),
        ListTile(leading: const Icon(Icons.videocam_outlined), title: const Text('تصوير فيديو'), onTap: () => Navigator.pop(ctx, 'video_camera')),
        const SizedBox(height: 8),
      ])),
    );
    if (source == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final isVideo = source.toString().startsWith('video_');
      final pickerSource = source.endsWith('camera') ? ImageSource.camera : ImageSource.gallery;
      final picked = isVideo
          ? await _picker.pickVideo(source: pickerSource, maxDuration: const Duration(seconds: 60))
          : await _picker.pickImage(source: pickerSource, imageQuality: 78, maxWidth: 1440);
      if (picked == null) return;
      final captionController = TextEditingController();
      final caption = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
        title: const Text('إضافة ستوري'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          ClipRRect(borderRadius: BorderRadius.circular(12), child: isVideo ? Container(height: 150, width: double.infinity, color: Colors.black87, child: const Center(child: Icon(Icons.play_circle_outline, color: Colors.white, size: 64))) : Image.file(File(picked.path), height: 150, width: double.infinity, fit: BoxFit.cover)),
          const SizedBox(height: 12),
          TextField(controller: captionController, maxLength: 180, maxLines: 2, decoration: const InputDecoration(labelText: 'اكتب تعليقًا (اختياري)', border: OutlineInputBorder())),
          const SizedBox(height: 4),
          Text(isVideo ? 'الفيديو سيُضغط لتقليل حجمه، والمدة القصوى 60 ثانية. تنتهي الحالة بعد 24 ساعة.' : 'ستُضغط الصورة لتسهيل تحميلها، وتنتهي الحالة بعد 24 ساعة.', style: TextStyle(fontSize: 12)),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')), FilledButton(onPressed: () => Navigator.pop(ctx, captionController.text.trim()), child: const Text('نشر'))],
      ));
      captionController.dispose();
      if (caption == null) return;
      final dir = await getApplicationDocumentsDirectory();
      final storiesDir = Directory('${dir.path}/blousab_stories');
      if (!await storiesDir.exists()) await storiesDir.create(recursive: true);
      String target;
      if (isVideo) {
        // Compress video for easier transfer and playback; keep original as fallback.
        final compressed = await VideoCompress.compressVideo(picked.path, quality: VideoQuality.MediumQuality, deleteOrigin: false, includeAudio: true);
        final mediaFile = compressed?.file;
        final extension = mediaFile?.path.split('.').last ?? (picked.path.contains('.') ? picked.path.split('.').last : 'mp4');
        target = '${storiesDir.path}/story_${DateTime.now().millisecondsSinceEpoch}.$extension';
        await (mediaFile ?? File(picked.path)).copy(target);
      } else {
        target = '${storiesDir.path}/story_${DateTime.now().millisecondsSinceEpoch}.jpg';
        await File(picked.path).copy(target);
      }
      final story = <String, dynamic>{
        'id': DateTime.now().microsecondsSinceEpoch.toString(),
        'userId': 'local-user',
        'userName': widget.userName.isEmpty ? 'مستخدم بلوساب' : widget.userName,
        'path': target,
        'mediaType': isVideo ? 'video' : 'image',
        'caption': caption,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      };
      final prefs = await SharedPreferences.getInstance();
      final current = prefs.getStringList(_storageKey) ?? <String>[];
      current.insert(0, jsonEncode(story));
      await prefs.setStringList(_storageKey, current);
      await _loadStories();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(isVideo ? 'تم ضغط الفيديو ونشر الحالة على هذا الجهاز لمدة 24 ساعة.' : 'تم ضغط الصورة ونشر الحالة على هذا الجهاز لمدة 24 ساعة.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر إنشاء الستوري: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openStory(Map<String, dynamic> story) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => _StoryViewer(story: story, onDelete: () async {
      final prefs = await SharedPreferences.getInstance();
      final current = prefs.getStringList(_storageKey) ?? <String>[];
      current.removeWhere((raw) { try { return (jsonDecode(raw) as Map)['id']?.toString() == story['id']?.toString(); } catch (_) { return false; } });
      await prefs.setStringList(_storageKey, current);
      try { await File(story['path'].toString()).delete(); } catch (_) {}
      await _loadStories();
    })));
  }

  @override
  Widget build(BuildContext context) {
    final myPhoto = widget.profilePhotoPath.isNotEmpty && File(widget.profilePhotoPath).existsSync();
    return Container(
      height: 112,
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          SizedBox(width: 76, child: InkWell(onTap: _createStory, borderRadius: BorderRadius.circular(14), child: Column(children: [
            Stack(children: [
              Container(width: 62, height: 62, padding: const EdgeInsets.all(3), decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Theme.of(context).colorScheme.outlineVariant, width: 1.5)), child: CircleAvatar(backgroundImage: myPhoto ? FileImage(File(widget.profilePhotoPath)) : null, child: myPhoto ? null : const Icon(Icons.person_outline, size: 28))),
              Positioned(right: 0, bottom: 0, child: Container(decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, shape: BoxShape.circle, border: Border.all(color: Theme.of(context).scaffoldBackgroundColor, width: 2)), child: const Icon(Icons.add, size: 19, color: Colors.white))),
            ]),
            const SizedBox(height: 5),
            Text(_busy ? 'جارٍ التجهيز…' : 'قصتك', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
          ]))),
          ..._stories.map((story) => SizedBox(width: 78, child: InkWell(onTap: () => _openStory(story), borderRadius: BorderRadius.circular(14), child: Column(children: [
            Container(
              width: 66,
              height: 66,
              padding: const EdgeInsets.all(3),
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [Color(0xFFFCB045), Color(0xFFFD1D1D), Color(0xFF833AB4)],
                ),
              ),
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                child: ClipOval(
                  child: story['mediaType'] == 'video'
                      ? const ColoredBox(
                          color: Colors.black87,
                          child: Center(child: Icon(Icons.play_arrow, color: Colors.white, size: 28)),
                        )
                      : Image.file(
                          File(story['path'].toString()),
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text((story['userName'] ?? 'مستخدم').toString(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
          ])))),
        ],
      ),
    );
  }
}

class _StoryViewer extends StatefulWidget {
  final Map<String, dynamic> story;
  final Future<void> Function() onDelete;
  const _StoryViewer({required this.story, required this.onDelete});
  @override
  State<_StoryViewer> createState() => _StoryViewerState();
}

class _StoryViewerState extends State<_StoryViewer> {
  Timer? _timer;
  double _progress = 0;
  VideoPlayerController? _videoController;
  bool _videoReady = false;
  bool _saving = false;
  bool get _isVideo => widget.story['mediaType'] == 'video';

  @override
  void initState() {
    super.initState();
    if (_isVideo) {
      _videoController = VideoPlayerController.file(File(widget.story['path'].toString()))
        ..initialize().then((_) {
          if (!mounted) return;
          setState(() => _videoReady = true);
          _videoController!.setLooping(false);
          _videoController!.play();
        }).catchError((_) {});
    }
    _timer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!mounted) return;
      if (_isVideo && _videoController != null && _videoController!.value.isInitialized) {
        final duration = _videoController!.value.duration.inMilliseconds;
        if (duration > 0) _progress = (_videoController!.value.position.inMilliseconds / duration).clamp(0.0, 1.0);
        if (_videoController!.value.position >= _videoController!.value.duration && !_videoController!.value.isPlaying) {
          Navigator.of(context).maybePop();
          return;
        }
      } else {
        _progress += 0.02;
        if (_progress >= 1) { Navigator.of(context).maybePop(); return; }
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _videoController?.dispose();
    super.dispose();
  }

  Future<void> _saveStory() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final savedDir = Directory('${dir.path}/blousab_saved_statuses');
      if (!await savedDir.exists()) await savedDir.create(recursive: true);
      final source = File(widget.story['path'].toString());
      if (!await source.exists()) throw Exception('ملف الحالة غير موجود');
      final extension = source.path.contains('.') ? source.path.split('.').last : (_isVideo ? 'mp4' : 'jpg');
      final destination = '${savedDir.path}/status_${DateTime.now().millisecondsSinceEpoch}.$extension';
      await source.copy(destination);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تم حفظ الحالة داخل بلوساب: $destination')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر تحميل الحالة: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final path = widget.story['path'].toString();
    final caption = (widget.story['caption'] ?? '').toString();
    final created = DateTime.fromMillisecondsSinceEpoch((widget.story['createdAt'] as num?)?.toInt() ?? 0);
    final age = DateTime.now().difference(created);
    Widget media;
    if (_isVideo) {
      media = _videoReady && _videoController != null
          ? GestureDetector(onTap: () { final c = _videoController!; setState(() => c.value.isPlaying ? c.pause() : c.play()); }, child: AspectRatio(aspectRatio: _videoController!.value.aspectRatio, child: VideoPlayer(_videoController!)))
          : const Center(child: CircularProgressIndicator(color: Colors.white));
    } else {
      media = Image.file(File(path), fit: BoxFit.contain, width: double.infinity, errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, color: Colors.white, size: 64));
    }
    return Scaffold(backgroundColor: Colors.black, body: SafeArea(child: Stack(fit: StackFit.expand, children: [
      Center(child: media),
      Positioned.fill(child: Row(children: [Expanded(child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: () => Navigator.pop(context))), Expanded(child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: () => Navigator.pop(context)))])),
      Positioned(top: 10, left: 12, right: 12, child: Column(children: [
        ClipRRect(borderRadius: BorderRadius.circular(10), child: LinearProgressIndicator(value: _progress.clamp(0, 1), minHeight: 3, backgroundColor: Colors.white38, color: Colors.white)),
        const SizedBox(height: 12),
        Row(children: [const CircleAvatar(radius: 17, child: Icon(Icons.person_outline, size: 20)), const SizedBox(width: 8), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text((widget.story['userName'] ?? 'مستخدم بلوساب').toString(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)), Text(age.inMinutes < 1 ? 'الآن' : age.inHours > 0 ? 'منذ ${age.inHours} س' : 'منذ ${age.inMinutes} د', style: const TextStyle(color: Colors.white70, fontSize: 11))])),
          IconButton(onPressed: _saveStory, icon: Icon(_saving ? Icons.hourglass_top : Icons.download_outlined, color: Colors.white), tooltip: 'تحميل الحالة'),
          IconButton(onPressed: () async { await widget.onDelete(); if (mounted) Navigator.pop(context); }, icon: const Icon(Icons.delete_outline, color: Colors.white), tooltip: 'حذف الحالة'),
          IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close, color: Colors.white)),
        ]),
      ])),
      if (_isVideo && _videoReady) Positioned(bottom: 72, left: 0, right: 0, child: Center(child: IconButton(onPressed: () { final c = _videoController!; setState(() => c.value.isPlaying ? c.pause() : c.play()); }, icon: Icon(_videoController!.value.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill, color: Colors.white, size: 54)))),
      if (caption.isNotEmpty) Positioned(bottom: 42, left: 20, right: 20, child: Text(caption, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 18, shadows: [Shadow(color: Colors.black87, blurRadius: 8)]))),
    ])));
  }
}
