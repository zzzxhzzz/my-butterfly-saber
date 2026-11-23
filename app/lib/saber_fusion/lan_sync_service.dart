import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:butterfly/api/file_system.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:network_info_plus/network_info_plus.dart';
import 'package:synchronized/synchronized.dart';

import 'lan_sync_models.dart';
import 'mistake_bank_service.dart';

String normalizeSyncDocPath(String raw) {
  var p = raw.trim().replaceAll('\\', '/');
  while (p.contains('//')) {
    p = p.replaceAll('//', '/');
  }
  while (p.endsWith('/') && p.length > 1) {
    p = p.substring(0, p.length - 1);
  }
  if (p.isNotEmpty && !p.startsWith('/')) {
    p = '/$p';
  }
  return p;
}

class LanSyncHooks {
  const LanSyncHooks._();

  static void Function(String relativeDocPath)? onDocumentSaved;
  static void Function(
    String? pathKey,
    String? pageName,
    double x,
    double y,
    double zoom,
    double rotation,
  )?
  onDocumentStateSaved;

  static void notifyDocumentSaved(AssetLocation location) {
    if (location.isRemote || location.absolute || location.path.isEmpty) {
      return;
    }
    onDocumentSaved?.call(normalizeSyncDocPath(location.path));
  }

  static void notifyDocumentStateSaved(PersistedDocumentState state) {
    onDocumentStateSaved?.call(
      state.pathKey,
      state.pageName,
      state.camera.positionX,
      state.camera.positionY,
      state.camera.zoom,
      state.camera.rotation,
    );
  }
}

class LanSyncService {
  static const int defaultHttpPort = 47832;
  static const int discoveryUdpPort = 47833;
  static const String _authHeader = 'x-bfly-sync-auth';

  final Lock _syncLock = Lock();
  final Lock _metaLock = Lock();

  HttpServer? _server;
  RawDatagramSocket? _udpSocket;
  Timer? _broadcastTimer;
  LanSyncAccount? _activeAccount;
  int _listeningPort = defaultHttpPort;
  int _eventSeq = 0;

  void Function(LanSyncPeer peer)? onPeerDiscovered;
  void Function(LanSyncPeer peer)? onPeerPinged;
  void Function(SyncedDocumentEvent event, {List<String> newRecentPaths})?
  onRemoteUpdate;
  void Function(
    List<LanReadingEntry> merged,
    SyncedDocumentEvent? activeEvent,
  )?
  onReadingMemoryMerged;

  bool get isServerRunning => _server != null;
  int get listeningPort => _listeningPort;

  int _nextEventId() => ++_eventSeq;

  String get _platformLabel {
    if (kIsWeb) return 'Web';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isAndroid) return 'Android';
    if (Platform.isLinux) return 'Linux';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isIOS) return 'iOS';
    return Platform.operatingSystem;
  }

  Future<Directory> _docsDir() async {
    final base = await getButterflyDirectory();
    final dir = Directory('$base/Documents');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> _statesDir() async {
    final base = await getButterflyDirectory();
    final dir = Directory('$base/DocumentStates');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> _metaDir() async {
    final base = await getButterflyDirectory();
    final dir = Directory('$base/SaberFusion');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<Directory?> _mistakesDir() async =>
      MistakeBankService.instance.getRootDirectory();

  Future<List<String>> getLocalIpv4Addresses() async {
    if (kIsWeb) return const [];
    final found = <String>{};
    try {
      final wifiIp = await NetworkInfo().getWifiIP();
      if (wifiIp != null && wifiIp.isNotEmpty && _isUsableLanIpv4(wifiIp)) {
        found.add(wifiIp);
      }
    } catch (_) {}
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (_isUsableLanIpv4(addr.address)) {
            found.add(addr.address);
          }
        }
      }
    } catch (_) {}
    final list = found.toList()
      ..sort((a, b) => _lanIpScore(a).compareTo(_lanIpScore(b)));
    return list;
  }

  static bool _isUsableLanIpv4(String ip) {
    if (ip.startsWith('127.') || ip.startsWith('169.254.')) return false;
    final parts = ip.split('.');
    return parts.length == 4 && parts.every((p) => int.tryParse(p) != null);
  }

  static int _lanIpScore(String ip) {
    if (ip.startsWith('192.168.')) return 0;
    if (ip.startsWith('10.')) return 1;
    if (ip.startsWith('172.')) return 2;
    return 3;
  }

  Future<void> startServer(LanSyncAccount account) async {
    if (kIsWeb || !account.isSignedIn) return;
    await stopServer();
    _activeAccount = account;
    final preferredPort = account.port > 0 && account.port <= 65535
        ? account.port
        : defaultHttpPort;
    try {
      _server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        preferredPort,
        shared: true,
      );
    } catch (_) {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0, shared: true);
    }
    _listeningPort = _server!.port;
    _server!.listen(_handleHttpRequest, onError: (_) {});
  }

  Future<void> stopServer() async {
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
  }

  Future<void> startDiscovery(LanSyncAccount account) async {
    if (kIsWeb || !account.isSignedIn) return;
    await stopDiscovery();
    _activeAccount = account;
    try {
      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryUdpPort,
        reuseAddress: true,
      );
    } catch (_) {
      try {
        _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      } catch (_) {
        return;
      }
    }
    _udpSocket!.broadcastEnabled = true;
    _udpSocket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = _udpSocket?.receive();
      if (datagram == null) return;
      _handleUdpPacket(datagram);
    }, onError: (_) {});

    unawaited(_sendDiscoveryBroadcast());
    _broadcastTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_sendDiscoveryBroadcast()),
    );
  }

  Future<void> stopDiscovery() async {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    try {
      _udpSocket?.close();
    } catch (_) {}
    _udpSocket = null;
  }

  Future<void> _sendDiscoveryBroadcast() async {
    final socket = _udpSocket;
    final account = _activeAccount;
    if (socket == null || account == null || !account.isSignedIn) return;
    final payload = utf8.encode(
      jsonEncode({
        't': 'bfly_lan_v1',
        'hint': account.discoveryHint,
        'id': account.deviceId,
        'name': account.deviceName,
        'platform': _platformLabel,
        'port': _listeningPort,
      }),
    );

    final targets = <String>{'255.255.255.255'};
    final localIps = await getLocalIpv4Addresses();
    for (final ip in localIps) {
      final dot = ip.lastIndexOf('.');
      if (dot > 0) {
        targets.add('${ip.substring(0, dot)}.255');
      }
    }
    for (final target in targets) {
      try {
        socket.send(payload, InternetAddress(target), discoveryUdpPort);
      } catch (_) {}
    }
  }

  void _handleUdpPacket(Datagram datagram) {
    final account = _activeAccount;
    if (account == null || !account.isSignedIn) return;
    try {
      final decoded = jsonDecode(utf8.decode(datagram.data));
      if (decoded is! Map) return;
      if (decoded['t'] != 'bfly_lan_v1') return;
      if (decoded['hint'] != account.discoveryHint) return;
      final peerId = decoded['id'] as String? ?? '';
      if (peerId.isEmpty || peerId == account.deviceId) return;
      final peerPort =
          (decoded['port'] as num?)?.toInt() ?? defaultHttpPort;
      final host = datagram.address.address;
      if (!_isUsableLanIpv4(host)) return;
      onPeerDiscovered?.call(
        LanSyncPeer(
          deviceId: peerId,
          deviceName: decoded['name'] as String? ?? host,
          platform: decoded['platform'] as String? ?? 'Unknown',
          host: host,
          port: peerPort,
          lastSeenMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } catch (_) {}
  }

  bool _isAuthorized(HttpRequest request) {
    final account = _activeAccount;
    if (account == null || !account.isSignedIn) return false;
    final token = request.headers.value(_authHeader);
    return token != null && token == account.accountHash;
  }

  Future<void> _sendJson(
    HttpResponse response,
    int statusCode,
    Object data,
  ) async {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(data));
    await response.close();
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    final account = _activeAccount;
    if (account == null || !account.isSignedIn) {
      await _sendJson(request.response, HttpStatus.serviceUnavailable, {
        'error': 'LAN sync is signed out',
      });
      return;
    }
    if (!_isAuthorized(request)) {
      await _sendJson(request.response, HttpStatus.unauthorized, {
        'error': 'Invalid sync account credentials',
      });
      return;
    }

    final path = request.uri.path;
    try {
      if (request.method == 'GET' && path == '/api/v1/health') {
        await _sendJson(request.response, HttpStatus.ok, {
          'deviceId': account.deviceId,
          'deviceName': account.deviceName,
          'platform': _platformLabel,
          'port': _listeningPort,
          'username': account.username,
          'serverTimeMs': DateTime.now().millisecondsSinceEpoch,
        });
        return;
      }

      if (request.method == 'GET' && path == '/api/v1/manifest') {
        final files = await _buildLocalManifest(
          includeStates: account.syncReadingProgress,
          includeMistakes: account.syncMistakeBank,
        );
        final memory = await loadReadingMemory();
        await _sendJson(request.response, HttpStatus.ok, {
          'deviceId': account.deviceId,
          'deviceName': account.deviceName,
          'files': files.values.map((e) => e.toJson()).toList(),
          'readingMemory': memory.map((e) => e.toJson()).toList(),
        });
        return;
      }

      if (request.method == 'GET' && path == '/api/v1/file') {
        final key = request.uri.queryParameters['key'] ?? '';
        final file = await _resolveScopedFile(key);
        if (file == null || !await file.exists()) {
          await _sendJson(request.response, HttpStatus.notFound, {
            'error': 'File not found',
          });
          return;
        }
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.binary;
        await request.response.addStream(file.openRead());
        await request.response.close();
        return;
      }

      if (request.method == 'PUT' && path == '/api/v1/file') {
        final key = request.uri.queryParameters['key'] ?? '';
        final mtime = int.tryParse(
          request.uri.queryParameters['mtime'] ?? '',
        );
        final fromDevice =
            request.headers.value('x-bfly-device-name') ?? '局域网设备';
        final target = await _resolveScopedFile(key);
        if (target == null) {
          await _sendJson(request.response, HttpStatus.badRequest, {
            'error': 'Invalid file key',
          });
          return;
        }
        final bytes = await _readRequestBytes(request);
        await _writeFileAtomic(target, bytes, modifiedMs: mtime);
        final sha = sha256.convert(bytes).toString();
        await _updateLedgerEntry(key, sha);
        await _handleIncomingKeySideEffects(
          key,
          bytes,
          fromDeviceName: fromDevice,
        );
        await _sendJson(request.response, HttpStatus.ok, {
          'ok': true,
          'sha256': sha,
        });
        return;
      }

      if (request.method == 'POST' && path == '/api/v1/reading-memory') {
        final fromDevice =
            request.headers.value('x-bfly-device-name') ?? '局域网设备';
        final raw = utf8.decode(await _readRequestBytes(request));
        final decoded = jsonDecode(raw);
        final incoming = <LanReadingEntry>[];
        if (decoded is Map && decoded['entries'] is List) {
          for (final item in decoded['entries'] as List) {
            if (item is Map) {
              incoming.add(
                LanReadingEntry.fromJson(Map<String, dynamic>.from(item)),
              );
            }
          }
        }
        final outcome = await _mergeReadingMemoryList(
          incoming,
          notifyDeviceName: fromDevice,
        );
        onReadingMemoryMerged?.call(outcome.merged, outcome.activeEvent);
        await _sendJson(request.response, HttpStatus.ok, {
          'entries': outcome.merged.map((e) => e.toJson()).toList(),
        });
        return;
      }

      if (request.method == 'POST' && path == '/api/v1/notify') {
        final raw = utf8.decode(await _readRequestBytes(request));
        final decoded = jsonDecode(raw);
        final remoteHost = request.connectionInfo?.remoteAddress.address;
        if (decoded is Map && remoteHost != null && _isUsableLanIpv4(remoteHost)) {
          final peerId = decoded['deviceId'] as String? ?? '';
          if (peerId.isNotEmpty && peerId != account.deviceId) {
            final peer = LanSyncPeer(
              deviceId: peerId,
              deviceName: decoded['deviceName'] as String? ?? remoteHost,
              platform: decoded['platform'] as String? ?? 'Unknown',
              host: remoteHost,
              port: (decoded['port'] as num?)?.toInt() ?? defaultHttpPort,
              lastSeenMs: DateTime.now().millisecondsSinceEpoch,
            );
            onPeerPinged?.call(peer);
          }
        }
        await _sendJson(request.response, HttpStatus.ok, {'ok': true});
        return;
      }

      await _sendJson(request.response, HttpStatus.notFound, {
        'error': 'Unknown endpoint',
      });
    } catch (error) {
      await _sendJson(request.response, HttpStatus.internalServerError, {
        'error': error.toString(),
      });
    }
  }

  Future<Uint8List> _readRequestBytes(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  bool _isSafeScopedKey(String key) {
    if (key.isEmpty ||
        key.startsWith('/') ||
        key.contains('\\') ||
        key.endsWith('.lan_tmp')) {
      return false;
    }
    final segments = key.split('/');
    if (segments.length < 2) return false;
    for (final seg in segments) {
      if (seg.isEmpty || seg == '.' || seg == '..' || seg.startsWith('.')) {
        return false;
      }
    }
    final root = segments.first;
    return root == 'docs' || root == 'states' || root == 'mistakes';
  }

  Future<File?> _resolveScopedFile(String key) async {
    if (!_isSafeScopedKey(key)) return null;
    final slash = key.indexOf('/');
    final scope = key.substring(0, slash);
    final rel = key.substring(slash + 1);
    final Directory? baseDir;
    switch (scope) {
      case 'docs':
        baseDir = await _docsDir();
      case 'states':
        baseDir = await _statesDir();
      case 'mistakes':
        baseDir = await _mistakesDir();
      default:
        baseDir = null;
    }
    if (baseDir == null) return null;
    final basePath = baseDir.path.replaceAll('\\', '/');
    final candidatePath = '$basePath/$rel';
    return File(candidatePath);
  }

  Future<void> _writeFileAtomic(
    File target,
    Uint8List bytes, {
    int? modifiedMs,
  }) async {
    if (!await target.parent.exists()) {
      await target.parent.create(recursive: true);
    }
    final tmp = File('${target.path}.lan_tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    if (await target.exists()) {
      await target.delete();
    }
    await tmp.rename(target.path);
    if (modifiedMs != null && modifiedMs > 0) {
      try {
        await target.setLastModified(
          DateTime.fromMillisecondsSinceEpoch(modifiedMs),
        );
      } catch (_) {}
    }
  }

  Future<Map<String, LanFileMeta>> _buildLocalManifest({
    required bool includeStates,
    required bool includeMistakes,
  }) async {
    final result = <String, LanFileMeta>{};
    await _scanDirIntoManifest(result, 'docs', await _docsDir());
    if (includeStates) {
      await _scanDirIntoManifest(
        result,
        'states',
        await _statesDir(),
        parseStateTimestamp: true,
      );
    }
    if (includeMistakes) {
      final mistakesDir = await _mistakesDir();
      if (mistakesDir != null) {
        await _scanDirIntoManifest(result, 'mistakes', mistakesDir);
      }
    }
    return result;
  }

  Future<void> _scanDirIntoManifest(
    Map<String, LanFileMeta> out,
    String scope,
    Directory dir, {
    bool parseStateTimestamp = false,
  }) async {
    if (!await dir.exists()) return;
    final baseNormalized = dir.path.replaceAll('\\', '/');
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final full = entity.path.replaceAll('\\', '/');
      if (!full.startsWith('$baseNormalized/')) continue;
      final rel = full.substring(baseNormalized.length + 1);
      final key = '$scope/$rel';
      if (!_isSafeScopedKey(key)) continue;
      try {
        final stat = await entity.stat();
        final bytes = await entity.readAsBytes();
        final hash = sha256.convert(bytes).toString();
        int? stateUpdatedAtMs;
        if (parseStateTimestamp) {
          stateUpdatedAtMs = _extractStateUpdatedAtMs(bytes);
        }
        out[key] = LanFileMeta(
          key: key,
          sha256: hash,
          size: stat.size,
          modifiedMs: stat.modified.millisecondsSinceEpoch,
          stateUpdatedAtMs: stateUpdatedAtMs,
        );
      } catch (_) {}
    }
  }

  static int? _extractStateUpdatedAtMs(Uint8List bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map && decoded['updatedAt'] is String) {
        return DateTime.tryParse(
          decoded['updatedAt'] as String,
        )?.millisecondsSinceEpoch;
      }
    } catch (_) {}
    return null;
  }

  static String? docPathFromStateKey(String key) {
    if (!key.startsWith('states/path/')) return null;
    var b64 = key.substring('states/path/'.length);
    if (b64.endsWith('.json')) {
      b64 = b64.substring(0, b64.length - '.json'.length);
    }
    try {
      final decoded = utf8.decode(base64Url.decode(base64Url.normalize(b64)));
      if (decoded.startsWith(':')) {
        return normalizeSyncDocPath(decoded.substring(1));
      }
    } catch (_) {}
    return null;
  }

  static ({
    String? pageName,
    double? x,
    double? y,
    double? zoom,
    double? rotation,
  })
  _extractCameraFromStateBytes(Uint8List bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map) {
        final pageName = decoded['pageName'] as String?;
        final camera = decoded['camera'];
        if (camera is Map) {
          return (
            pageName: pageName,
            x: (camera['positionX'] as num?)?.toDouble(),
            y: (camera['positionY'] as num?)?.toDouble(),
            zoom: (camera['zoom'] as num?)?.toDouble(),
            rotation: (camera['rotation'] as num?)?.toDouble(),
          );
        }
        return (pageName: pageName, x: null, y: null, zoom: null, rotation: null);
      }
    } catch (_) {}
    return (pageName: null, x: null, y: null, zoom: null, rotation: null);
  }

  Future<void> _handleIncomingKeySideEffects(
    String key,
    Uint8List bytes, {
    required String fromDeviceName,
  }) async {
    if (key.startsWith('mistakes/')) {
      await MistakeBankService.instance.reloadFromDisk();
      onRemoteUpdate?.call(
        SyncedDocumentEvent(
          eventId: _nextEventId(),
          docPath: '',
          contentUpdated: false,
          stateUpdated: false,
          fromDeviceName: fromDeviceName,
        ),
      );
      return;
    }

    if (key.startsWith('docs/')) {
      final docPath = normalizeSyncDocPath(key.substring('docs/'.length));
      final isConflictCopy = docPath.contains('.conflict-');
      onRemoteUpdate?.call(
        SyncedDocumentEvent(
          eventId: _nextEventId(),
          docPath: docPath,
          contentUpdated: true,
          stateUpdated: false,
          fromDeviceName: fromDeviceName,
        ),
        newRecentPaths: isConflictCopy ? const [] : [docPath],
      );
      return;
    }

    if (key.startsWith('states/')) {
      final docPath = docPathFromStateKey(key);
      if (docPath != null) {
        final cam = _extractCameraFromStateBytes(bytes);
        onRemoteUpdate?.call(
          SyncedDocumentEvent(
            eventId: _nextEventId(),
            docPath: docPath,
            contentUpdated: false,
            stateUpdated: true,
            targetPageName: cam.pageName,
            cameraX: cam.x,
            cameraY: cam.y,
            zoom: cam.zoom,
            rotation: cam.rotation,
            fromDeviceName: fromDeviceName,
          ),
        );
      }
    }
  }

  Future<Map<String, String>> _loadLedger() async =>
      _metaLock.synchronized(() async {
        final dir = await _metaDir();
        final file = File('${dir.path}/lan_sync_ledger.json');
        if (!await file.exists()) return {};
        try {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is Map) {
            return decoded.map(
              (k, v) => MapEntry(k.toString(), v?.toString() ?? ''),
            );
          }
        } catch (_) {}
        return {};
      });

  Future<void> _saveLedger(Map<String, String> ledger) async =>
      _metaLock.synchronized(() async {
        final dir = await _metaDir();
        final file = File('${dir.path}/lan_sync_ledger.json');
        await file.writeAsString(jsonEncode(ledger), flush: true);
      });

  Future<void> _updateLedgerEntry(String key, String sha) async {
    final ledger = await _loadLedger();
    ledger[key] = sha;
    await _saveLedger(ledger);
  }

  Future<List<LanReadingEntry>> loadReadingMemory() async =>
      _metaLock.synchronized(() async {
        if (kIsWeb) return const [];
        final dir = await _metaDir();
        final file = File('${dir.path}/lan_sync_reading_memory.json');
        if (!await file.exists()) return const [];
        try {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is List) {
            final items = decoded
                .whereType<Map>()
                .map(
                  (e) => LanReadingEntry.fromJson(Map<String, dynamic>.from(e)),
                )
                .where((e) => e.docPath.isNotEmpty)
                .toList();
            items.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
            return items;
          }
        } catch (_) {}
        return const [];
      });

  Future<void> _saveReadingMemory(List<LanReadingEntry> entries) async =>
      _metaLock.synchronized(() async {
        if (kIsWeb) return;
        final dir = await _metaDir();
        final file = File('${dir.path}/lan_sync_reading_memory.json');
        await file.writeAsString(
          jsonEncode(entries.map((e) => e.toJson()).toList()),
          flush: true,
        );
      });

  Future<List<LanReadingEntry>> upsertReadingMemory(
    LanReadingEntry entry,
  ) async {
    final normalized = LanReadingEntry(
      docPath: normalizeSyncDocPath(entry.docPath),
      docName: entry.docName,
      pageName: entry.pageName,
      pageIndex: entry.pageIndex,
      totalPages: entry.totalPages,
      cameraX: entry.cameraX,
      cameraY: entry.cameraY,
      zoom: entry.zoom,
      rotation: entry.rotation,
      updatedAtMs: entry.updatedAtMs,
      deviceName: entry.deviceName,
    );
    final outcome = await _mergeReadingMemoryList([normalized]);
    return outcome.merged;
  }

  Future<({List<LanReadingEntry> merged, int addedCount, SyncedDocumentEvent? activeEvent})>
  _mergeReadingMemoryList(
    List<LanReadingEntry> incoming, {
    String? notifyDeviceName,
  }) async {
    final current = await loadReadingMemory();
    final map = <String, LanReadingEntry>{
      for (final item in current) normalizeSyncDocPath(item.docPath): item,
    };
    var changedCount = 0;
    LanReadingEntry? latestRemoteUpdate;
    for (final rawItem in incoming) {
      final normPath = normalizeSyncDocPath(rawItem.docPath);
      if (normPath.isEmpty) continue;
      final item = LanReadingEntry(
        docPath: normPath,
        docName: rawItem.docName,
        pageName: rawItem.pageName,
        pageIndex: rawItem.pageIndex,
        totalPages: rawItem.totalPages,
        cameraX: rawItem.cameraX,
        cameraY: rawItem.cameraY,
        zoom: rawItem.zoom,
        rotation: rawItem.rotation,
        updatedAtMs: rawItem.updatedAtMs,
        deviceName: rawItem.deviceName,
      );
      final existing = map[normPath];
      if (existing == null || item.updatedAtMs > existing.updatedAtMs) {
        map[normPath] = item;
        changedCount++;
        if (latestRemoteUpdate == null ||
            item.updatedAtMs > latestRemoteUpdate.updatedAtMs) {
          latestRemoteUpdate = item;
        }
      }
    }
    final merged = map.values.toList()
      ..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    final trimmed = merged.length > 100 ? merged.sublist(0, 100) : merged;
    if (changedCount > 0) {
      await _saveReadingMemory(trimmed);
    }

    SyncedDocumentEvent? activeEvent;
    if (notifyDeviceName != null && latestRemoteUpdate != null) {
      activeEvent = SyncedDocumentEvent(
        eventId: _nextEventId(),
        docPath: latestRemoteUpdate.docPath,
        contentUpdated: false,
        stateUpdated: true,
        targetPageName: latestRemoteUpdate.pageName,
        pageIndex: latestRemoteUpdate.pageIndex,
        cameraX: latestRemoteUpdate.cameraX,
        cameraY: latestRemoteUpdate.cameraY,
        zoom: latestRemoteUpdate.zoom,
        rotation: latestRemoteUpdate.rotation,
        fromDeviceName: latestRemoteUpdate.deviceName.isEmpty
            ? notifyDeviceName
            : latestRemoteUpdate.deviceName,
      );
    }
    return (merged: trimmed, addedCount: changedCount, activeEvent: activeEvent);
  }

  Future<LanSyncPeer> probePeer(
    String rawAddress,
    LanSyncAccount account,
  ) async {
    final trimmed = rawAddress.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('请输入对方设备的局域网 IP 地址');
    }
    var host = trimmed;
    var port = defaultHttpPort;
    final clean = trimmed.replaceFirst(RegExp(r'^https?://'), '');
    final colonIdx = clean.lastIndexOf(':');
    if (colonIdx > 0) {
      host = clean.substring(0, colonIdx).trim();
      final parsedPort = int.tryParse(clean.substring(colonIdx + 1).trim());
      if (parsedPort == null || parsedPort <= 0 || parsedPort > 65535) {
        throw const FormatException('端口号无效（范围 1~65535）');
      }
      port = parsedPort;
    } else {
      host = clean;
    }

    final client = http.Client();
    try {
      final uri = Uri.http('$host:$port', '/api/v1/health');
      final res = await client
          .get(uri, headers: {_authHeader: account.accountHash})
          .timeout(const Duration(seconds: 5));
      if (res.statusCode == HttpStatus.unauthorized) {
        throw StateError('对方设备拒绝认证：请确认两端填写的同步账号名与同步密码完全一致');
      }
      if (res.statusCode != HttpStatus.ok) {
        throw HttpException('连接失败（HTTP ${res.statusCode}）');
      }
      final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map;
      final peerId = body['deviceId'] as String? ?? '$host:$port';
      if (peerId == account.deviceId) {
        throw StateError('填写的是本机地址，请输入另一台设备的局域网 IP');
      }
      return LanSyncPeer(
        deviceId: peerId,
        deviceName: body['deviceName'] as String? ?? host,
        platform: body['platform'] as String? ?? 'Unknown',
        host: host,
        port: (body['port'] as num?)?.toInt() ?? port,
        lastSeenMs: DateTime.now().millisecondsSinceEpoch,
        isManual: true,
      );
    } finally {
      client.close();
    }
  }

  Future<void> pingPeers(
    List<LanSyncPeer> peers,
    LanSyncAccount account,
  ) async {
    if (kIsWeb || !account.isSignedIn || peers.isEmpty) return;
    final client = http.Client();
    try {
      final body = jsonEncode({
        'deviceId': account.deviceId,
        'deviceName': account.deviceName,
        'platform': _platformLabel,
        'port': _listeningPort,
      });
      for (final peer in peers) {
        try {
          await client
              .post(
                Uri.http(peer.address, '/api/v1/notify'),
                headers: {
                  _authHeader: account.accountHash,
                  'Content-Type': 'application/json',
                },
                body: body,
              )
              .timeout(const Duration(seconds: 3));
        } catch (_) {}
      }
    } finally {
      client.close();
    }
  }

  Future<LanSyncResult> syncWithPeer(
    LanSyncPeer peer,
    LanSyncAccount account,
  ) => _syncLock.synchronized(() async {
    if (kIsWeb || !account.isSignedIn) {
      return LanSyncResult(peerName: peer.deviceName);
    }

    final client = http.Client();
    final headers = <String, String>{
      _authHeader: account.accountHash,
      'x-bfly-device-name': account.deviceName,
    };

    try {
      final manifestRes = await client
          .get(Uri.http(peer.address, '/api/v1/manifest'), headers: headers)
          .timeout(const Duration(seconds: 12));
      if (manifestRes.statusCode == HttpStatus.unauthorized) {
        throw StateError('账号认证失败：请核对两端同步账号和密码');
      }
      if (manifestRes.statusCode != HttpStatus.ok) {
        throw HttpException('获取同步清单失败 (${manifestRes.statusCode})');
      }

      final manifestJson =
          jsonDecode(utf8.decode(manifestRes.bodyBytes)) as Map;
      final remoteFiles = <String, LanFileMeta>{};
      if (manifestJson['files'] is List) {
        for (final item in manifestJson['files'] as List) {
          if (item is Map) {
            final meta = LanFileMeta.fromJson(Map<String, dynamic>.from(item));
            if (meta.key.isNotEmpty) {
              remoteFiles[meta.key] = meta;
            }
          }
        }
      }

      final remoteMemory = <LanReadingEntry>[];
      if (manifestJson['readingMemory'] is List) {
        for (final item in manifestJson['readingMemory'] as List) {
          if (item is Map) {
            remoteMemory.add(
              LanReadingEntry.fromJson(Map<String, dynamic>.from(item)),
            );
          }
        }
      }

      final localFiles = await _buildLocalManifest(
        includeStates: account.syncReadingProgress,
        includeMistakes: account.syncMistakeBank,
      );
      final ledger = await _loadLedger();
      final allKeys = <String>{...localFiles.keys, ...remoteFiles.keys}.toList()
        ..sort();

      var uploaded = 0;
      var downloaded = 0;
      var conflicts = 0;
      var mistakesTouched = false;
      final newRecentPaths = <String>[];
      final updatedDocs = <String>{};
      final updatedStatesByDoc = <String, SyncedDocumentEvent>{};

      Future<void> pushKey(String key, LanFileMeta local) async {
        final file = await _resolveScopedFile(key);
        if (file == null || !await file.exists()) return;
        final bytes = await file.readAsBytes();
        final res = await client
            .put(
              Uri.http(peer.address, '/api/v1/file', {
                'key': key,
                'mtime': local.modifiedMs.toString(),
              }),
              headers: {...headers, 'Content-Type': 'application/octet-stream'},
              body: bytes,
            )
            .timeout(const Duration(seconds: 60));
        if (res.statusCode == HttpStatus.ok) {
          ledger[key] = local.sha256;
          uploaded++;
        }
      }

      Future<void> pullKey(String key, LanFileMeta remote) async {
        final target = await _resolveScopedFile(key);
        if (target == null) return;
        final res = await client
            .get(
              Uri.http(peer.address, '/api/v1/file', {'key': key}),
              headers: headers,
            )
            .timeout(const Duration(seconds: 60));
        if (res.statusCode != HttpStatus.ok) return;
        final bytes = res.bodyBytes;
        await _writeFileAtomic(target, bytes, modifiedMs: remote.modifiedMs);
        ledger[key] = sha256.convert(bytes).toString();
        downloaded++;

        if (key.startsWith('mistakes/')) {
          mistakesTouched = true;
        } else if (key.startsWith('docs/')) {
          final docPath = normalizeSyncDocPath(key.substring('docs/'.length));
          updatedDocs.add(docPath);
          if (!docPath.contains('.conflict-')) {
            newRecentPaths.add(docPath);
          }
        } else if (key.startsWith('states/')) {
          final docPath = docPathFromStateKey(key);
          if (docPath != null) {
            final cam = _extractCameraFromStateBytes(bytes);
            updatedStatesByDoc[docPath] = SyncedDocumentEvent(
              eventId: _nextEventId(),
              docPath: docPath,
              contentUpdated: false,
              stateUpdated: true,
              targetPageName: cam.pageName,
              cameraX: cam.x,
              cameraY: cam.y,
              zoom: cam.zoom,
              rotation: cam.rotation,
              fromDeviceName: peer.deviceName,
            );
          }
        }
      }

      for (final key in allKeys) {
        if (key.startsWith('states/') && !account.syncReadingProgress) continue;
        if (key.startsWith('mistakes/') && !account.syncMistakeBank) continue;

        final local = localFiles[key];
        final remote = remoteFiles[key];
        if (local != null && remote != null) {
          if (local.sha256 == remote.sha256) {
            ledger[key] = local.sha256;
            continue;
          }

          if (key == 'mistakes/index.json') {
            final mergedBytes = await _mergeMistakeIndexWithRemote(
              client,
              peer,
              headers,
            );
            if (mergedBytes != null) {
              final mergedSha = sha256.convert(mergedBytes).toString();
              ledger[key] = mergedSha;
              mistakesTouched = true;
              downloaded++;
              final putRes = await client
                  .put(
                    Uri.http(peer.address, '/api/v1/file', {
                      'key': key,
                      'mtime': DateTime.now().millisecondsSinceEpoch.toString(),
                    }),
                    headers: {
                      ...headers,
                      'Content-Type': 'application/octet-stream',
                    },
                    body: mergedBytes,
                  )
                  .timeout(const Duration(seconds: 20));
              if (putRes.statusCode == HttpStatus.ok) {
                uploaded++;
              }
            }
            continue;
          }

          if (key.startsWith('states/')) {
            final localTs = local.stateUpdatedAtMs ?? local.modifiedMs;
            final remoteTs = remote.stateUpdatedAtMs ?? remote.modifiedMs;
            if (localTs >= remoteTs) {
              await pushKey(key, local);
            } else {
              await pullKey(key, remote);
            }
            continue;
          }

          final baseSha = ledger[key];
          if (baseSha != null && remote.sha256 == baseSha) {
            await pushKey(key, local);
          } else if (baseSha != null && local.sha256 == baseSha) {
            await pullKey(key, remote);
          } else {
            // Both edited while offline -> preserve older version as conflict copy.
            if (key.startsWith('docs/')) {
              conflicts++;
              if (local.modifiedMs >= remote.modifiedMs) {
                await _saveRemoteAsConflictCopy(
                  client,
                  peer,
                  headers,
                  key,
                  peer.deviceName,
                );
                await pushKey(key, local);
              } else {
                await _saveLocalAsConflictCopy(key, account.deviceName);
                await pullKey(key, remote);
              }
            } else {
              if (local.modifiedMs >= remote.modifiedMs) {
                await pushKey(key, local);
              } else {
                await pullKey(key, remote);
              }
            }
          }
        } else if (local != null) {
          await pushKey(key, local);
        } else if (remote != null) {
          await pullKey(key, remote);
        }
      }

      await _saveLedger(ledger);
      if (mistakesTouched) {
        await MistakeBankService.instance.reloadFromDisk();
      }

      // Sync reading history memory bidirectionally.
      var readingMergedCount = 0;
      if (account.syncReadingProgress) {
        final localOutcome = await _mergeReadingMemoryList(remoteMemory);
        readingMergedCount = localOutcome.addedCount;
        try {
          final memRes = await client
              .post(
                Uri.http(peer.address, '/api/v1/reading-memory'),
                headers: {...headers, 'Content-Type': 'application/json'},
                body: jsonEncode({
                  'entries': localOutcome.merged.map((e) => e.toJson()).toList(),
                }),
              )
              .timeout(const Duration(seconds: 12));
          if (memRes.statusCode == HttpStatus.ok) {
            final memJson = jsonDecode(utf8.decode(memRes.bodyBytes));
            if (memJson is Map && memJson['entries'] is List) {
              final back = (memJson['entries'] as List)
                  .whereType<Map>()
                  .map(
                    (e) => LanReadingEntry.fromJson(
                      Map<String, dynamic>.from(e),
                    ),
                  )
                  .toList();
              final backOutcome = await _mergeReadingMemoryList(back);
              readingMergedCount += backOutcome.addedCount;
            }
          }
        } catch (_) {}
      }

      final events = <SyncedDocumentEvent>[];
      final allAffectedDocs = <String>{
        ...updatedDocs,
        ...updatedStatesByDoc.keys,
      };
      for (final docPath in allAffectedDocs) {
        final st = updatedStatesByDoc[docPath];
        events.add(
          SyncedDocumentEvent(
            eventId: _nextEventId(),
            docPath: docPath,
            contentUpdated: updatedDocs.contains(docPath),
            stateUpdated: st != null,
            targetPageName: st?.targetPageName,
            cameraX: st?.cameraX,
            cameraY: st?.cameraY,
            zoom: st?.zoom,
            rotation: st?.rotation,
            fromDeviceName: peer.deviceName,
          ),
        );
      }

      return LanSyncResult(
        uploaded: uploaded,
        downloaded: downloaded,
        conflicts: conflicts,
        readingMerged: readingMergedCount,
        updatedDocEvents: events,
        newRecentPaths: newRecentPaths,
        peerName: peer.deviceName,
      );
    } finally {
      client.close();
    }
  });

  Future<Uint8List?> _mergeMistakeIndexWithRemote(
    http.Client client,
    LanSyncPeer peer,
    Map<String, String> headers,
  ) async {
    try {
      final res = await client
          .get(
            Uri.http(peer.address, '/api/v1/file', {'key': 'mistakes/index.json'}),
            headers: headers,
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != HttpStatus.ok) return null;
      final localFile = await _resolveScopedFile('mistakes/index.json');
      if (localFile == null) return null;

      final localList = localFile.existsSync()
          ? (jsonDecode(await localFile.readAsString()) as List?) ?? const []
          : const [];
      final remoteList =
          (jsonDecode(utf8.decode(res.bodyBytes)) as List?) ?? const [];

      final byId = <String, MistakeEntry>{};
      for (final raw in [...localList, ...remoteList]) {
        if (raw is! Map) continue;
        final entry = MistakeEntry.fromJson(Map<String, dynamic>.from(raw));
        if (entry.id.isEmpty) continue;
        final existing = byId[entry.id];
        if (existing == null) {
          byId[entry.id] = entry;
        } else {
          final pickedMastery = entry.mastery.index >= existing.mastery.index
              ? entry.mastery
              : existing.mastery;
          final pickedNote = entry.note.length >= existing.note.length
              ? entry.note
              : existing.note;
          final pickedAi =
              entry.aiExplanation.length >= existing.aiExplanation.length
              ? entry.aiExplanation
              : existing.aiExplanation;
          byId[entry.id] = existing.copyWith(
            mastery: pickedMastery,
            note: pickedNote,
            aiExplanation: pickedAi,
          );
        }
      }
      final merged = byId.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final encoded = Uint8List.fromList(
        utf8.encode(jsonEncode(merged.map((e) => e.toJson()).toList())),
      );
      await _writeFileAtomic(localFile, encoded);
      return encoded;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveLocalAsConflictCopy(String key, String deviceName) async {
    final original = await _resolveScopedFile(key);
    if (original == null || !await original.exists()) return;
    final conflictKey = _conflictKey(key, deviceName);
    final conflictFile = await _resolveScopedFile(conflictKey);
    if (conflictFile == null) return;
    final bytes = await original.readAsBytes();
    await _writeFileAtomic(conflictFile, bytes);
  }

  Future<void> _saveRemoteAsConflictCopy(
    http.Client client,
    LanSyncPeer peer,
    Map<String, String> headers,
    String key,
    String deviceName,
  ) async {
    try {
      final res = await client
          .get(
            Uri.http(peer.address, '/api/v1/file', {'key': key}),
            headers: headers,
          )
          .timeout(const Duration(seconds: 60));
      if (res.statusCode != HttpStatus.ok) return;
      final conflictKey = _conflictKey(key, deviceName);
      final conflictFile = await _resolveScopedFile(conflictKey);
      if (conflictFile == null) return;
      await _writeFileAtomic(conflictFile, res.bodyBytes);
    } catch (_) {}
  }

  static String _conflictKey(String key, String deviceName) {
    final safeDev = deviceName
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    final tag = DateTime.now().toIso8601String().replaceAll(':', '').split('.').first;
    final dot = key.lastIndexOf('.');
    if (dot <= key.lastIndexOf('/')) {
      return '$key.conflict-$safeDev-$tag';
    }
    return '${key.substring(0, dot)}.conflict-${safeDev.isEmpty ? 'peer' : safeDev}-$tag${key.substring(dot)}';
  }
}
