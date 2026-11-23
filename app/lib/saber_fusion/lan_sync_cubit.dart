import 'dart:async';
import 'dart:io';

import 'package:butterfly_api/butterfly_api.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lan_sync_models.dart';
import 'lan_sync_service.dart';

class LanSyncCubit extends Cubit<LanSyncState> {
  static const _prefUsername = 'saber_fusion.lan_sync.username';
  static const _prefDeviceName = 'saber_fusion.lan_sync.device_name';
  static const _prefDeviceId = 'saber_fusion.lan_sync.device_id';
  static const _prefPort = 'saber_fusion.lan_sync.port';
  static const _prefManualPeer = 'saber_fusion.lan_sync.manual_peer';
  static const _prefAutoSync = 'saber_fusion.lan_sync.auto_sync';
  static const _prefSyncReading = 'saber_fusion.lan_sync.sync_reading';
  static const _prefFollowPage = 'saber_fusion.lan_sync.follow_page';
  static const _prefSyncMistakes = 'saber_fusion.lan_sync.sync_mistakes';
  static const _securePassphrase = 'saber_fusion.lan_sync_passphrase';

  final LanSyncService _service;
  final FlutterSecureStorage _secureStorage;

  Timer? _periodicTimer;
  Timer? _autoSyncDebounce;
  bool _loaded = false;

  LanSyncCubit({
    LanSyncService? service,
    FlutterSecureStorage? secureStorage,
  }) : _service = service ?? LanSyncService(),
       _secureStorage = secureStorage ?? const FlutterSecureStorage(),
       super(const LanSyncState()) {
    _service.onPeerDiscovered = _onPeerDiscovered;
    _service.onPeerPinged = _onPeerPinged;
    _service.onRemoteUpdate = _onRemoteUpdate;
    _service.onReadingMemoryMerged = _onReadingMemoryMerged;
  }

  static String _defaultDeviceName() {
    if (kIsWeb) return 'Web 浏览器';
    try {
      if (Platform.isWindows) {
        final host = Platform.localHostname.trim();
        return host.isNotEmpty ? 'Windows ($host)' : 'Windows 电脑';
      }
      if (Platform.isAndroid) return 'Android 平板/手机';
      if (Platform.isMacOS) return 'Mac 设备';
      if (Platform.isLinux) return 'Linux 设备';
    } catch (_) {}
    return '学习设备';
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      var deviceId = prefs.getString(_prefDeviceId) ?? '';
      if (deviceId.isEmpty) {
        deviceId = createUniqueId();
        await prefs.setString(_prefDeviceId, deviceId);
      }
      final savedDeviceName = prefs.getString(_prefDeviceName) ?? '';
      final deviceName =
          savedDeviceName.isEmpty ? _defaultDeviceName() : savedDeviceName;
      final username = prefs.getString(_prefUsername) ?? '';
      final port =
          prefs.getInt(_prefPort) ?? LanSyncService.defaultHttpPort;
      final manualPeer = prefs.getString(_prefManualPeer) ?? '';
      final autoSyncOnEdit = prefs.getBool(_prefAutoSync) ?? true;
      final syncReadingProgress = prefs.getBool(_prefSyncReading) ?? true;
      final followRemotePage = prefs.getBool(_prefFollowPage) ?? true;
      final syncMistakeBank = prefs.getBool(_prefSyncMistakes) ?? true;

      var passphrase = '';
      try {
        passphrase = await _secureStorage.read(key: _securePassphrase) ?? '';
      } catch (_) {}

      final account = LanSyncAccount(
        username: username,
        passphrase: passphrase,
        deviceName: deviceName,
        deviceId: deviceId,
        port: port,
        manualPeerAddress: manualPeer,
        autoSyncOnEdit: autoSyncOnEdit,
        syncReadingProgress: syncReadingProgress,
        followRemotePage: followRemotePage,
        syncMistakeBank: syncMistakeBank,
      );

      final history = await _service.loadReadingMemory();
      if (isClosed) return;
      emit(state.copyWith(account: account, readingHistory: history));

      if (account.isSignedIn) {
        _installHooks();
        await _startRuntimeServices();
      }
    } catch (_) {}
  }

  void _installHooks() {
    LanSyncHooks.onDocumentSaved = (_) => _handleLocalEditEvent();
    LanSyncHooks.onDocumentStateSaved = (_, _, _, _, _, _) {
      if (state.account.syncReadingProgress) {
        _handleLocalEditEvent();
      }
    };
  }

  void _removeHooks() {
    LanSyncHooks.onDocumentSaved = null;
    LanSyncHooks.onDocumentStateSaved = null;
  }

  void _handleLocalEditEvent() {
    if (!state.account.isSignedIn || !state.account.autoSyncOnEdit || kIsWeb) {
      return;
    }
    _scheduleDebouncedAutoSync(const Duration(milliseconds: 1400));
  }

  void _scheduleDebouncedAutoSync(Duration delay) {
    _autoSyncDebounce?.cancel();
    _autoSyncDebounce = Timer(delay, () {
      unawaited(syncNow(silent: true));
    });
  }

  Future<void> _startRuntimeServices() async {
    if (kIsWeb || !state.account.isSignedIn) return;
    await _service.startServer(state.account);
    await _service.startDiscovery(state.account);
    final ips = await _service.getLocalIpv4Addresses();
    if (!isClosed) {
      emit(
        state.copyWith(
          serverRunning: _service.isServerRunning,
          listeningPort: _service.listeningPort,
          localAddresses: ips,
        ),
      );
    }

    if (state.account.manualPeerAddress.isNotEmpty) {
      unawaited(_probeSavedManualPeer());
    }

    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      if (isClosed || !state.account.isSignedIn) return;
      _pruneStalePeers();
      final latestIps = await _service.getLocalIpv4Addresses();
      if (!isClosed &&
          latestIps.join(',') != state.localAddresses.join(',')) {
        emit(state.copyWith(localAddresses: latestIps));
      }
      if (state.peers.isNotEmpty && !state.syncing) {
        unawaited(syncNow(silent: true));
      } else if (state.account.manualPeerAddress.isNotEmpty &&
          state.peers.isEmpty) {
        unawaited(_probeSavedManualPeer());
      }
    });
  }

  Future<void> _stopRuntimeServices() async {
    _periodicTimer?.cancel();
    _periodicTimer = null;
    _autoSyncDebounce?.cancel();
    _autoSyncDebounce = null;
    await _service.stopDiscovery();
    await _service.stopServer();
    if (!isClosed) {
      emit(
        state.copyWith(
          serverRunning: false,
          peers: const [],
        ),
      );
    }
  }

  Future<void> _probeSavedManualPeer() async {
    final addr = state.account.manualPeerAddress.trim();
    if (addr.isEmpty || !state.account.isSignedIn) return;
    try {
      final peer = await _service.probePeer(addr, state.account);
      if (isClosed) return;
      _upsertPeer(peer);
      if (!state.syncing) {
        unawaited(syncNow(peer: peer, silent: true));
      }
    } catch (_) {}
  }

  void _pruneStalePeers() {
    final cutoff = DateTime.now().millisecondsSinceEpoch - 25000;
    final filtered = state.peers
        .where((p) => p.isManual || p.lastSeenMs >= cutoff)
        .toList();
    if (filtered.length != state.peers.length && !isClosed) {
      emit(state.copyWith(peers: filtered));
    }
  }

  void _upsertPeer(LanSyncPeer peer) {
    if (isClosed) return;
    final list = state.peers.toList();
    final idx = list.indexWhere((p) => p.deviceId == peer.deviceId);
    if (idx >= 0) {
      final keepManual = list[idx].isManual || peer.isManual;
      list[idx] = peer.copyWith(isManual: keepManual);
    } else {
      list.add(peer);
    }
    emit(state.copyWith(peers: list));
  }

  void _onPeerDiscovered(LanSyncPeer peer) {
    final isNew = !state.peers.any((p) => p.deviceId == peer.deviceId);
    _upsertPeer(peer);
    if (isNew && state.account.isSignedIn && !state.syncing) {
      unawaited(syncNow(peer: peer, silent: true));
    }
  }

  void _onPeerPinged(LanSyncPeer peer) {
    _upsertPeer(peer);
    if (state.account.isSignedIn && !state.syncing) {
      unawaited(syncNow(peer: peer, silent: true));
    }
  }

  void _onRemoteUpdate(
    SyncedDocumentEvent event, {
    List<String> newRecentPaths = const [],
  }) {
    if (isClosed) return;
    final mergedRecent = <String>{
      ...state.recentSyncedPaths,
      ...newRecentPaths,
    }.toList();
    emit(
      state.copyWith(
        syncRevision: state.syncRevision + 1,
        recentSyncedPaths: mergedRecent,
        lastDocumentEvent: event.docPath.isEmpty ? state.lastDocumentEvent : event,
        lastSyncAt: DateTime.now(),
        lastSyncSummary: '已接收来自「${event.fromDeviceName}」的更新',
      ),
    );
  }

  void _onReadingMemoryMerged(
    List<LanReadingEntry> merged,
    SyncedDocumentEvent? activeEvent,
  ) {
    if (isClosed) return;
    emit(
      state.copyWith(
        readingHistory: merged,
        syncRevision: state.syncRevision + 1,
        lastDocumentEvent: activeEvent ?? state.lastDocumentEvent,
      ),
    );
  }

  Future<void> _savePrefs(
    Future<void> Function(SharedPreferences prefs) fn,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await fn(prefs);
    } catch (_) {}
  }

  Future<void> login({
    required String username,
    required String passphrase,
    required String deviceName,
    int port = LanSyncService.defaultHttpPort,
  }) async {
    final cleanUser = username.trim();
    final cleanPass = passphrase.trim();
    if (cleanUser.isEmpty || cleanPass.isEmpty) {
      emit(state.copyWith(lastError: '同步账号名与同步密码不能为空'));
      return;
    }
    final cleanDevice =
        deviceName.trim().isEmpty ? _defaultDeviceName() : deviceName.trim();
    final validPort =
        port > 0 && port <= 65535 ? port : LanSyncService.defaultHttpPort;

    var deviceId = state.account.deviceId;
    if (deviceId.isEmpty) {
      deviceId = createUniqueId();
    }

    final updated = state.account.copyWith(
      username: cleanUser,
      passphrase: cleanPass,
      deviceName: cleanDevice,
      deviceId: deviceId,
      port: validPort,
    );

    emit(state.copyWith(account: updated, lastError: null, peers: const []));

    await _savePrefs((prefs) async {
      await prefs.setString(_prefUsername, cleanUser);
      await prefs.setString(_prefDeviceName, cleanDevice);
      await prefs.setString(_prefDeviceId, deviceId);
      await prefs.setInt(_prefPort, validPort);
    });
    try {
      await _secureStorage.write(key: _securePassphrase, value: cleanPass);
    } catch (_) {}

    _installHooks();
    await _startRuntimeServices();
  }

  Future<void> logout() async {
    _removeHooks();
    await _stopRuntimeServices();
    final cleared = state.account.copyWith(
      username: '',
      passphrase: '',
    );
    emit(
      state.copyWith(
        account: cleared,
        lastSyncSummary: '',
        lastError: null,
        peers: const [],
      ),
    );
    await _savePrefs((prefs) async {
      await prefs.remove(_prefUsername);
    });
    try {
      await _secureStorage.delete(key: _securePassphrase);
    } catch (_) {}
  }

  Future<void> updateOptions({
    bool? autoSyncOnEdit,
    bool? syncReadingProgress,
    bool? followRemotePage,
    bool? syncMistakeBank,
  }) async {
    final updated = state.account.copyWith(
      autoSyncOnEdit: autoSyncOnEdit,
      syncReadingProgress: syncReadingProgress,
      followRemotePage: followRemotePage,
      syncMistakeBank: syncMistakeBank,
    );
    emit(state.copyWith(account: updated));
    await _savePrefs((prefs) async {
      await prefs.setBool(_prefAutoSync, updated.autoSyncOnEdit);
      await prefs.setBool(_prefSyncReading, updated.syncReadingProgress);
      await prefs.setBool(_prefFollowPage, updated.followRemotePage);
      await prefs.setBool(_prefSyncMistakes, updated.syncMistakeBank);
    });
    if (updated.isSignedIn && !kIsWeb) {
      await _service.startServer(updated);
    }
  }

  Future<bool> connectManualPeer(String rawAddress) async {
    if (!state.account.isSignedIn) {
      emit(state.copyWith(lastError: '请先登录局域网同步账号'));
      return false;
    }
    emit(state.copyWith(lastError: null));
    try {
      final peer = await _service.probePeer(rawAddress, state.account);
      final updatedAccount = state.account.copyWith(
        manualPeerAddress: peer.address,
      );
      emit(state.copyWith(account: updatedAccount));
      await _savePrefs((prefs) => prefs.setString(_prefManualPeer, peer.address));
      _upsertPeer(peer);
      await syncNow(peer: peer);
      return true;
    } catch (error) {
      emit(state.copyWith(lastError: _readableError(error)));
      return false;
    }
  }

  Future<void> clearManualPeer() async {
    final updated = state.account.copyWith(manualPeerAddress: '');
    final remaining = state.peers.where((p) => !p.isManual).toList();
    emit(state.copyWith(account: updated, peers: remaining));
    await _savePrefs((prefs) => prefs.remove(_prefManualPeer));
  }

  Future<void> syncNow({LanSyncPeer? peer, bool silent = false}) async {
    if (kIsWeb || !state.account.isSignedIn || state.syncing) return;

    var targets = peer != null ? [peer] : state.peers;
    if (targets.isEmpty && state.account.manualPeerAddress.isNotEmpty) {
      try {
        final manual = await _service.probePeer(
          state.account.manualPeerAddress,
          state.account,
        );
        _upsertPeer(manual);
        targets = [manual];
      } catch (error) {
        if (!silent && !isClosed) {
          emit(state.copyWith(lastError: _readableError(error)));
        }
        return;
      }
    }

    if (targets.isEmpty) {
      if (!silent && !isClosed) {
        emit(
          state.copyWith(
            lastError: '暂未发现同账号在线设备：请确认双端连在同一 Wi-Fi 并登录同一同步账号，或直接输入对方 IP',
          ),
        );
      }
      return;
    }

    emit(state.copyWith(syncing: true, lastError: silent ? state.lastError : null));
    var totalUp = 0;
    var totalDown = 0;
    var totalConflicts = 0;
    var totalReading = 0;
    final allRecent = <String>{...state.recentSyncedPaths};
    SyncedDocumentEvent? latestDocEvent;
    String? errorMsg;

    for (final targetPeer in targets) {
      try {
        final result = await _service.syncWithPeer(targetPeer, state.account);
        totalUp += result.uploaded;
        totalDown += result.downloaded;
        totalConflicts += result.conflicts;
        totalReading += result.readingMerged;
        allRecent.addAll(result.newRecentPaths);
        if (result.updatedDocEvents.isNotEmpty) {
          latestDocEvent = result.updatedDocEvents.last;
        }
      } catch (error) {
        errorMsg = _readableError(error);
      }
    }

    if (totalUp > 0 || totalReading > 0) {
      unawaited(_service.pingPeers(targets, state.account));
    }

    final latestHistory = await _service.loadReadingMemory();
    if (isClosed) return;

    final hasFileChanges =
        totalUp > 0 || totalDown > 0 || totalConflicts > 0 || totalReading > 0;
    final summary = errorMsg != null && !hasFileChanges
        ? state.lastSyncSummary
        : hasFileChanges
        ? '上传 $totalUp · 下载 $totalDown${totalConflicts > 0 ? ' · 保留冲突备份 $totalConflicts' : ''}${totalReading > 0 ? ' · 页码记忆 $totalReading' : ''}'
        : '已连接，双端已是最新一致';

    emit(
      state.copyWith(
        syncing: false,
        lastSyncAt: errorMsg == null || hasFileChanges
            ? DateTime.now()
            : state.lastSyncAt,
        lastSyncSummary: summary,
        lastError: (!silent || (errorMsg?.contains('认证') ?? false))
            ? errorMsg
            : null,
        readingHistory: latestHistory,
        syncRevision: (totalDown > 0 || totalReading > 0)
            ? state.syncRevision + 1
            : state.syncRevision,
        recentSyncedPaths: allRecent.toList(),
        lastDocumentEvent: latestDocEvent ?? state.lastDocumentEvent,
      ),
    );
  }

  Future<void> recordReadingMemory({
    required String docPath,
    required String docName,
    required String pageName,
    required int pageIndex,
    required int totalPages,
    required double cameraX,
    required double cameraY,
    required double zoom,
    required double rotation,
  }) async {
    if (docPath.trim().isEmpty) return;
    final cleanPath = normalizeSyncDocPath(docPath);
    final entry = LanReadingEntry(
      docPath: cleanPath,
      docName: docName.trim().isEmpty
          ? cleanPath.split('/').last.replaceFirst(RegExp(r'\.t?bfly$'), '')
          : docName.trim(),
      pageName: pageName,
      pageIndex: pageIndex,
      totalPages: totalPages,
      cameraX: cameraX,
      cameraY: cameraY,
      zoom: zoom,
      rotation: rotation,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      deviceName: state.account.deviceName.isEmpty
          ? _defaultDeviceName()
          : state.account.deviceName,
    );
    final merged = await _service.upsertReadingMemory(entry);
    if (isClosed) return;
    emit(state.copyWith(readingHistory: merged));

    if (state.account.isSignedIn && state.account.syncReadingProgress && !kIsWeb) {
      _scheduleDebouncedAutoSync(const Duration(seconds: 2));
    }
  }

  void clearRecentSyncedPaths() {
    if (state.recentSyncedPaths.isEmpty) return;
    emit(state.copyWith(recentSyncedPaths: const []));
  }

  static String _readableError(Object error) {
    final msg = error.toString();
    if (msg.contains('TimeoutException')) {
      return '连接超时：请检查双端是否在同一局域网或系统防火墙是否放行端口';
    }
    if (msg.contains('SocketException')) {
      return '无法连接对方设备：请确认对方已登录局域网同步账号且在同一 Wi-Fi';
    }
    return msg
        .replaceFirst('Bad state: ', '')
        .replaceFirst('FormatException: ', '')
        .replaceFirst('HttpException: ', '');
  }

  @override
  Future<void> close() async {
    _removeHooks();
    await _stopRuntimeServices();
    return super.close();
  }
}

LanSyncCubit? maybeLanSyncCubit(BuildContext context) {
  try {
    return BlocProvider.of<LanSyncCubit>(context);
  } catch (_) {
    return null;
  }
}
