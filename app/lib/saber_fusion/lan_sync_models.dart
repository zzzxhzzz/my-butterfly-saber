import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:material_ui/material_ui.dart';

@immutable
class LanSyncAccount {
  final String username;
  final String passphrase;
  final String deviceName;
  final String deviceId;
  final int port;
  final String manualPeerAddress;
  final bool autoSyncOnEdit;
  final bool syncReadingProgress;
  final bool followRemotePage;
  final bool syncMistakeBank;

  const LanSyncAccount({
    this.username = '',
    this.passphrase = '',
    this.deviceName = '',
    this.deviceId = '',
    this.port = 47832,
    this.manualPeerAddress = '',
    this.autoSyncOnEdit = true,
    this.syncReadingProgress = true,
    this.followRemotePage = true,
    this.syncMistakeBank = true,
  });

  bool get isSignedIn =>
      username.trim().isNotEmpty && passphrase.trim().isNotEmpty;

  String get accountHash => sha256
      .convert(
        utf8.encode(
          'bfly-lan-v1:${username.trim().toLowerCase()}:${passphrase.trim()}',
        ),
      )
      .toString();

  String get discoveryHint =>
      sha256.convert(utf8.encode('hint:$accountHash')).toString().substring(0, 16);

  LanSyncAccount copyWith({
    String? username,
    String? passphrase,
    String? deviceName,
    String? deviceId,
    int? port,
    String? manualPeerAddress,
    bool? autoSyncOnEdit,
    bool? syncReadingProgress,
    bool? followRemotePage,
    bool? syncMistakeBank,
  }) => LanSyncAccount(
    username: username ?? this.username,
    passphrase: passphrase ?? this.passphrase,
    deviceName: deviceName ?? this.deviceName,
    deviceId: deviceId ?? this.deviceId,
    port: port ?? this.port,
    manualPeerAddress: manualPeerAddress ?? this.manualPeerAddress,
    autoSyncOnEdit: autoSyncOnEdit ?? this.autoSyncOnEdit,
    syncReadingProgress: syncReadingProgress ?? this.syncReadingProgress,
    followRemotePage: followRemotePage ?? this.followRemotePage,
    syncMistakeBank: syncMistakeBank ?? this.syncMistakeBank,
  );
}

@immutable
class LanSyncPeer {
  final String deviceId;
  final String deviceName;
  final String platform;
  final String host;
  final int port;
  final int lastSeenMs;
  final bool isManual;

  const LanSyncPeer({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.host,
    required this.port,
    required this.lastSeenMs,
    this.isManual = false,
  });

  String get address => '$host:$port';

  LanSyncPeer copyWith({
    String? deviceId,
    String? deviceName,
    String? platform,
    String? host,
    int? port,
    int? lastSeenMs,
    bool? isManual,
  }) => LanSyncPeer(
    deviceId: deviceId ?? this.deviceId,
    deviceName: deviceName ?? this.deviceName,
    platform: platform ?? this.platform,
    host: host ?? this.host,
    port: port ?? this.port,
    lastSeenMs: lastSeenMs ?? this.lastSeenMs,
    isManual: isManual ?? this.isManual,
  );
}

@immutable
class LanFileMeta {
  final String key;
  final String sha256;
  final int size;
  final int modifiedMs;
  final int? stateUpdatedAtMs;

  const LanFileMeta({
    required this.key,
    required this.sha256,
    required this.size,
    required this.modifiedMs,
    this.stateUpdatedAtMs,
  });

  Map<String, dynamic> toJson() => {
    'key': key,
    'sha256': sha256,
    'size': size,
    'modifiedMs': modifiedMs,
    if (stateUpdatedAtMs != null) 'stateUpdatedAtMs': stateUpdatedAtMs,
  };

  factory LanFileMeta.fromJson(Map<String, dynamic> json) => LanFileMeta(
    key: json['key'] as String? ?? '',
    sha256: json['sha256'] as String? ?? '',
    size: (json['size'] as num?)?.toInt() ?? 0,
    modifiedMs: (json['modifiedMs'] as num?)?.toInt() ?? 0,
    stateUpdatedAtMs: (json['stateUpdatedAtMs'] as num?)?.toInt(),
  );
}

@immutable
class LanReadingEntry {
  final String docPath;
  final String docName;
  final String pageName;
  final int pageIndex;
  final int totalPages;
  final double cameraX;
  final double cameraY;
  final double zoom;
  final double rotation;
  final int updatedAtMs;
  final String deviceName;

  const LanReadingEntry({
    required this.docPath,
    required this.docName,
    required this.pageName,
    required this.pageIndex,
    required this.totalPages,
    required this.cameraX,
    required this.cameraY,
    required this.zoom,
    required this.rotation,
    required this.updatedAtMs,
    required this.deviceName,
  });

  Map<String, dynamic> toJson() => {
    'docPath': docPath,
    'docName': docName,
    'pageName': pageName,
    'pageIndex': pageIndex,
    'totalPages': totalPages,
    'cameraX': cameraX,
    'cameraY': cameraY,
    'zoom': zoom,
    'rotation': rotation,
    'updatedAtMs': updatedAtMs,
    'deviceName': deviceName,
  };

  factory LanReadingEntry.fromJson(Map<String, dynamic> json) => LanReadingEntry(
    docPath: json['docPath'] as String? ?? '',
    docName: json['docName'] as String? ?? '',
    pageName: json['pageName'] as String? ?? '',
    pageIndex: (json['pageIndex'] as num?)?.toInt() ?? 1,
    totalPages: (json['totalPages'] as num?)?.toInt() ?? 1,
    cameraX: (json['cameraX'] as num?)?.toDouble() ?? 0,
    cameraY: (json['cameraY'] as num?)?.toDouble() ?? 0,
    zoom: (json['zoom'] as num?)?.toDouble() ?? 1,
    rotation: (json['rotation'] as num?)?.toDouble() ?? 0,
    updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
    deviceName: json['deviceName'] as String? ?? '',
  );
}

@immutable
class SyncedDocumentEvent {
  final int eventId;
  final String docPath;
  final bool contentUpdated;
  final bool stateUpdated;
  final String? targetPageName;
  final int? pageIndex;
  final double? cameraX;
  final double? cameraY;
  final double? zoom;
  final double? rotation;
  final String fromDeviceName;

  const SyncedDocumentEvent({
    required this.eventId,
    required this.docPath,
    required this.contentUpdated,
    required this.stateUpdated,
    this.targetPageName,
    this.pageIndex,
    this.cameraX,
    this.cameraY,
    this.zoom,
    this.rotation,
    this.fromDeviceName = '',
  });
}

@immutable
class LanSyncResult {
  final int uploaded;
  final int downloaded;
  final int conflicts;
  final int readingMerged;
  final List<SyncedDocumentEvent> updatedDocEvents;
  final List<String> newRecentPaths;
  final String peerName;

  const LanSyncResult({
    this.uploaded = 0,
    this.downloaded = 0,
    this.conflicts = 0,
    this.readingMerged = 0,
    this.updatedDocEvents = const [],
    this.newRecentPaths = const [],
    this.peerName = '',
  });
}

@immutable
class LanSyncState {
  final LanSyncAccount account;
  final bool serverRunning;
  final List<String> localAddresses;
  final int listeningPort;
  final List<LanSyncPeer> peers;
  final bool syncing;
  final DateTime? lastSyncAt;
  final String lastSyncSummary;
  final String? lastError;
  final List<LanReadingEntry> readingHistory;
  final int syncRevision;
  final SyncedDocumentEvent? lastDocumentEvent;
  final List<String> recentSyncedPaths;

  const LanSyncState({
    this.account = const LanSyncAccount(),
    this.serverRunning = false,
    this.localAddresses = const [],
    this.listeningPort = 47832,
    this.peers = const [],
    this.syncing = false,
    this.lastSyncAt,
    this.lastSyncSummary = '',
    this.lastError,
    this.readingHistory = const [],
    this.syncRevision = 0,
    this.lastDocumentEvent,
    this.recentSyncedPaths = const [],
  });

  static const _unset = Object();

  LanSyncState copyWith({
    LanSyncAccount? account,
    bool? serverRunning,
    List<String>? localAddresses,
    int? listeningPort,
    List<LanSyncPeer>? peers,
    bool? syncing,
    Object? lastSyncAt = _unset,
    String? lastSyncSummary,
    Object? lastError = _unset,
    List<LanReadingEntry>? readingHistory,
    int? syncRevision,
    Object? lastDocumentEvent = _unset,
    List<String>? recentSyncedPaths,
  }) => LanSyncState(
    account: account ?? this.account,
    serverRunning: serverRunning ?? this.serverRunning,
    localAddresses: localAddresses ?? this.localAddresses,
    listeningPort: listeningPort ?? this.listeningPort,
    peers: peers ?? this.peers,
    syncing: syncing ?? this.syncing,
    lastSyncAt: identical(lastSyncAt, _unset)
        ? this.lastSyncAt
        : lastSyncAt as DateTime?,
    lastSyncSummary: lastSyncSummary ?? this.lastSyncSummary,
    lastError: identical(lastError, _unset)
        ? this.lastError
        : lastError as String?,
    readingHistory: readingHistory ?? this.readingHistory,
    syncRevision: syncRevision ?? this.syncRevision,
    lastDocumentEvent: identical(lastDocumentEvent, _unset)
        ? this.lastDocumentEvent
        : lastDocumentEvent as SyncedDocumentEvent?,
    recentSyncedPaths: recentSyncedPaths ?? this.recentSyncedPaths,
  );
}
