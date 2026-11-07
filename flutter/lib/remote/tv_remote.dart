import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/material.dart';
import 'package:open_tv/app_keys.dart';
import 'package:open_tv/exo_player.dart';
import 'package:open_tv/models/device_detector.dart';
import 'package:open_tv/native_bridge.dart';
import 'package:open_tv/playback.dart';
import 'package:open_tv/remote/protocol.dart';
import 'package:open_tv/remote/remote_player_controller.dart';
import 'package:open_tv/remote/remote_store.dart';
import 'package:open_tv/remote/tv_server.dart';

// The phone control feature on a TV: runs the server, advertises it on the
// network and opens the player for what a phone sends.
class TvRemote implements RemotePlayerHost {
  static final TvRemote instance = TvRemote._();
  TvRemote._();

  TvServer? _server;
  BonsoirBroadcast? _broadcast;
  RemotePlayerController? _player;
  Future<void> _queue = Future.value();

  TvServer? get server => _server;
  String get serverName => _server?.name ?? "Fred TV";
  bool get running => _server?.running == true;

  Future<RemoteStore> get _store => RemoteStore.shared();

  Future<bool> get allowed async => (await _store).allowControl;
  Future<int> get pairedPhones async => (await _store).phones.length;

  Future<void> startIfAllowed() async {
    if (await allowed) await _start();
  }

  // Throws if the server can't start (the port is taken).
  Future<void> setAllowed(bool allow) async {
    final store = await _store;
    store.allowControl = allow;
    await store.save();
    if (allow) {
      await _start();
    } else {
      await _stop();
    }
  }

  Future<void> forgetPhones() async {
    final store = await _store;
    if (_server != null) {
      await _server!.forgetPhones();
    } else {
      store.phones = [];
      await store.save();
    }
  }

  Future<void> _start() async {
    if (running) return;
    final server = _server ??= TvServer(
      store: await _store,
      host: this,
      name: "Fred TV · ${await DeviceDetector.model()}",
    );
    await server.start();
    await _advertise(server);
  }

  Future<void> _stop() async {
    await _broadcast?.stop();
    _broadcast = null;
    await _server?.stop();
  }

  // Phones can still connect by address if discovery isn't available.
  Future<void> _advertise(TvServer server) async {
    try {
      final broadcast = BonsoirBroadcast(
        service: BonsoirService(
          name: server.name,
          type: remoteServiceType,
          port: server.boundPort,
          attributes: {remoteServiceIdAttribute: server.store.tvId!},
        ),
      );
      await broadcast.initialize();
      await broadcast.start();
      _broadcast = broadcast;
    } catch (e) {
      debugPrint("Couldn't advertise on the network: $e");
    }
  }

  // One at a time, so a quick second request can't leave two players open.
  @override
  Future<String?> play(RemoteMedia media) {
    final result = _queue.then((_) => _open(media));
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<String?> _open(RemoteMedia media) async {
    final context = navigatorKey.currentContext;
    final state = WidgetsBinding.instance.lifecycleState;
    if (context == null ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      return "Open Fred TV on the TV first";
    }
    final settings = await NativeBridge.instance.getSettings();
    await ExoPlayerScreen.closeActive();
    if (!context.mounted) return "Open Fred TV on the TV first";
    late final RemotePlayerController controller;
    controller = RemotePlayerController(
      media: media,
      onState: (state) {
        if (identical(_player, controller)) {
          _server?.publishStatus(RemoteStatus(state, media.title));
        }
      },
    );
    _player = controller;
    _server?.publishStatus(
      RemoteStatus(RemotePlayerState.buffering, media.title),
    );
    pushRemotePlayer(context, controller, settings).whenComplete(() {
      if (identical(_player, controller)) {
        _player = null;
        _server?.publishStatus(RemoteStatus.idle);
      }
    });
    // So that the screen exists if another request needs to close it.
    await WidgetsBinding.instance.endOfFrame;
    return null;
  }

  @override
  void pause() => _player?.pause();

  @override
  void resume() => _player?.resume();

  @override
  Future<void> stop() async => await _player?.close();
}
