import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

enum MistakeMastery {
  unmastered('未掌握'),
  reviewing('巩固中'),
  mastered('已掌握');

  final String label;
  const MistakeMastery(this.label);

  MistakeMastery get next =>
      MistakeMastery.values[(index + 1) % MistakeMastery.values.length];
}

@immutable
class MistakeEntry {
  final String id;
  final DateTime createdAt;
  final String subject;
  final MistakeMastery mastery;
  final String documentName;
  final int? pageNumber;
  final String imagePath;
  final String note;
  final String aiExplanation;

  const MistakeEntry({
    required this.id,
    required this.createdAt,
    required this.subject,
    required this.mastery,
    required this.documentName,
    this.pageNumber,
    required this.imagePath,
    this.note = '',
    this.aiExplanation = '',
  });

  MistakeEntry copyWith({
    String? subject,
    MistakeMastery? mastery,
    String? note,
    String? aiExplanation,
  }) => MistakeEntry(
    id: id,
    createdAt: createdAt,
    subject: subject ?? this.subject,
    mastery: mastery ?? this.mastery,
    documentName: documentName,
    pageNumber: pageNumber,
    imagePath: imagePath,
    note: note ?? this.note,
    aiExplanation: aiExplanation ?? this.aiExplanation,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    'subject': subject,
    'mastery': mastery.name,
    'documentName': documentName,
    'pageNumber': pageNumber,
    'imagePath': imagePath,
    'note': note,
    'aiExplanation': aiExplanation,
  };

  factory MistakeEntry.fromJson(Map<String, dynamic> json) => MistakeEntry(
    id: json['id'] as String? ?? '',
    createdAt:
        DateTime.tryParse(json['createdAt'] as String? ?? '') ??
        DateTime.now(),
    subject: json['subject'] as String? ?? '综合',
    mastery: MistakeMastery.values.firstWhere(
      (e) => e.name == json['mastery'],
      orElse: () => MistakeMastery.unmastered,
    ),
    documentName: json['documentName'] as String? ?? '',
    pageNumber: (json['pageNumber'] as num?)?.toInt(),
    imagePath: json['imagePath'] as String? ?? '',
    note: json['note'] as String? ?? '',
    aiExplanation: json['aiExplanation'] as String? ?? '',
  );
}

class MistakeBankService extends ChangeNotifier {
  MistakeBankService._();

  static final MistakeBankService instance = MistakeBankService._();

  final List<MistakeEntry> _entries = [];
  final Map<String, Uint8List> _memoryImages = {};
  bool _loaded = false;

  List<MistakeEntry> get entries => List.unmodifiable(_entries);

  Future<Directory?> getRootDirectory() => _rootDirectory();

  Future<void> reloadFromDisk() async {
    _loaded = false;
    await ensureLoaded();
    notifyListeners();
  }

  Future<Directory?> _rootDirectory() async {
    if (kIsWeb) return null;
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory('${docs.path}/Linwood/Butterfly/SaberFusion/mistakes');
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    return root;
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final root = await _rootDirectory();
      if (root == null) return;
      final indexFile = File('${root.path}/index.json');
      if (!await indexFile.exists()) return;
      final raw = await indexFile.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        _entries
          ..clear()
          ..addAll(
            decoded
                .whereType<Map>()
                .map((e) => MistakeEntry.fromJson(Map<String, dynamic>.from(e))),
          );
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> _persist() async {
    try {
      final root = await _rootDirectory();
      if (root == null) return;
      final indexFile = File('${root.path}/index.json');
      await indexFile.writeAsString(
        jsonEncode(_entries.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }

  Future<MistakeEntry> addMistake({
    required Uint8List imageBytes,
    required String subject,
    required String documentName,
    int? pageNumber,
    String note = '',
    String aiExplanation = '',
  }) async {
    await ensureLoaded();
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    var imagePath = 'mem://$id';
    final root = await _rootDirectory();
    if (root != null) {
      final imagesDir = Directory('${root.path}/images');
      if (!await imagesDir.exists()) {
        await imagesDir.create(recursive: true);
      }
      final file = File('${imagesDir.path}/$id.png');
      await file.writeAsBytes(imageBytes, flush: true);
      imagePath = file.path;
    } else {
      _memoryImages[imagePath] = imageBytes;
    }
    final entry = MistakeEntry(
      id: id,
      createdAt: DateTime.now(),
      subject: subject.trim().isEmpty ? '综合' : subject.trim(),
      mastery: MistakeMastery.unmastered,
      documentName: documentName,
      pageNumber: pageNumber,
      imagePath: imagePath,
      note: note.trim(),
      aiExplanation: aiExplanation.trim(),
    );
    _entries.insert(0, entry);
    await _persist();
    notifyListeners();
    return entry;
  }

  Future<Uint8List?> readImageBytes(MistakeEntry entry) async {
    if (entry.imagePath.startsWith('mem://')) {
      return _memoryImages[entry.imagePath];
    }
    if (kIsWeb || entry.imagePath.isEmpty) return null;
    try {
      final file = File(entry.imagePath);
      if (await file.exists()) {
        return await file.readAsBytes();
      }
    } catch (_) {}
    return null;
  }

  Future<void> updateMastery(String id, MistakeMastery mastery) async {
    final idx = _entries.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    _entries[idx] = _entries[idx].copyWith(mastery: mastery);
    await _persist();
    notifyListeners();
  }

  Future<void> updateNote(String id, String note) async {
    final idx = _entries.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    _entries[idx] = _entries[idx].copyWith(note: note);
    await _persist();
    notifyListeners();
  }

  Future<void> deleteMistake(String id) async {
    final idx = _entries.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    final removed = _entries.removeAt(idx);
    _memoryImages.remove(removed.imagePath);
    if (!kIsWeb && !removed.imagePath.startsWith('mem://')) {
      try {
        final file = File(removed.imagePath);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
    await _persist();
    notifyListeners();
  }

  String exportMarkdown(List<MistakeEntry> items) {
    final buffer = StringBuffer('# 错题本导出\n\n');
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final pageInfo =
          item.pageNumber != null ? ' · 第 ${item.pageNumber} 页' : '';
      buffer.writeln(
        '## ${i + 1}. [${item.subject}] ${item.mastery.label}',
      );
      buffer.writeln(
        '- 来源：${item.documentName.isEmpty ? '当前文档' : item.documentName}$pageInfo',
      );
      buffer.writeln('- 时间：${item.createdAt.toLocal()}');
      if (item.note.isNotEmpty) {
        buffer.writeln('- 笔记：${item.note}');
      }
      if (item.aiExplanation.isNotEmpty) {
        buffer.writeln('\n${item.aiExplanation}\n');
      }
      buffer.writeln('---\n');
    }
    return buffer.toString();
  }
}
