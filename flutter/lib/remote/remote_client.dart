import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:open_tv/remote/protocol.dart';
import 'package:open_tv/remote/remote_store.dart';

enum RemoteConnection { disconnected, connecting, connected, reconnecting }

class RemoteConnectException implements Exception {
  final String message;
  const RemoteConnectException(this.message);
  @override
  String toString() => message;
}

// The TV forgot this phone and closed the link; pairing needs a new one.
class _PairAgain implements Exception {
  const _PairAgain();
}

// Asks the user for the code shown on the TV. `wrongCode`: the last one failed.
// Returns null to give up.
typedef AskPairingCode =
    Future<String?> Function(String tvName, bool wrongCode);

// The phone's end of the link. While connected, playback goes to the TV.
class RemoteClient {
  static final RemoteClient instance = RemoteClient();

  static const _connectTimeout = Duration(seconds: 5);
  static const _replyTimeout = Duration(seconds: 10);
  static const _pingInterval = Duration(seconds: 10);
  static const _reconnectDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
  ];

  final ValueNotifier<RemoteConnection> connection = ValueNotifier(
    RemoteConnection.disconnected,
  );
  final ValueNotifier<RemoteStatus> status = ValueNotifier(RemoteStatus.idle);
  // Errors reported by the TV, and losing the pairing.
  void Function(String message)? onMessage;

  RemoteStore? _store;
  String _phoneName = "Phone";
  SavedTv? _tv;
  WebSocket? _socket;
  Timer? _reconnectTimer;
  Future<bool>? _reconnecting;
  int _attempts = 0;
  // Bumped on every new connection or disconnect, to retire older ones.
  int _generation = 0;

  bool get active => connection.value != RemoteConnection.disconnected;
  bool get connected => connection.value == RemoteConnection.connected;
  String? get tvName => _tv?.name;
  String? get tvId => _tv?.id;

  // Connects to a TV, pairing first if it's new. Throws RemoteConnectException,
  // or returns false if the user cancelled pairing.
  Future<bool> connect({
    required RemoteStore store,
    required String host,
    int port = remotePort,
    required String phoneName,
    required AskPairingCode askCode,
  }) async {
    await disconnect();
    final generation = _generation;
    _store = store;
    _phoneName = phoneName;
    connection.value = RemoteConnection.connecting;
    try {
      final tv = await _open(host, port, generation, askCode);
      if (tv == null && generation == _generation) {
        connection.value = RemoteConnection.disconnected;
      }
      return tv != null;
    } catch (_) {
      if (generation == _generation) {
        connection.value = RemoteConnection.disconnected;
      }
      rethrow;
    }
  }

  Future<void> disconnect() async {
    _generation++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnecting = null;
    _attempts = 0;
    _tv = null;
    final socket = _socket;
    _socket = null;
    connection.value = RemoteConnection.disconnected;
    status.value = RemoteStatus.idle;
    await socket?.close();
  }

  // False when the TV can't be reached right now.
  Future<bool> play(RemoteMedia media) async {
    if (!connected && !await _reconnectNow()) return false;
    return _send({"type": "play", "media": media.toJson()});
  }

  void pause() => _send({"type": "pause"});
  void resume() => _send({"type": "resume"});
  void stop() => _send({"type": "stop"});

  bool _send(Map<String, dynamic> message) {
    final socket = _socket;
    if (socket == null || socket.readyState != WebSocket.open) return false;
    socket.add(jsonEncode(message));
    return true;
  }

  Future<SavedTv?> _open(
    String host,
    int port,
    int generation,
    AskPairingCode? askCode,
  ) async {
    final WebSocket socket;
    try {
      socket = await WebSocket.connect(
        "ws://${_hostForUri(host)}:$port",
      ).timeout(_connectTimeout);
    } catch (_) {
      throw const RemoteConnectException("Couldn't reach the TV");
    }
    socket.pingInterval = _pingInterval;
    final messages = StreamIterator<dynamic>(socket);
    try {
      final tv = await _handshake(messages, socket, host, port, askCode);
      if (tv == null || generation != _generation) {
        await messages.cancel();
        await socket.close();
        return null;
      }
      _tv = tv;
      _socket = socket;
      _attempts = 0;
      await _store!.saveTv(tv);
      connection.value = RemoteConnection.connected;
      _readLoop(messages, generation);
      return tv;
    } catch (e) {
      await messages.cancel();
      await socket.close();
      if (e is _PairAgain) return _open(host, port, generation, askCode);
      if (e is RemoteConnectException) rethrow;
      throw const RemoteConnectException("The TV didn't respond");
    }
  }

  Future<SavedTv?> _handshake(
    StreamIterator<dynamic> messages,
    WebSocket socket,
    String host,
    int port,
    AskPairingCode? askCode,
  ) async {
    final server = await _read(messages);
    if (server["type"] != "server") {
      throw const RemoteConnectException("That isn't a Fred TV");
    }
    final id = server["id"] as String;
    final name = server["name"] as String;
    final saved = _store!.tvById(id);
    if (saved != null) {
      socket.add(jsonEncode({"type": "hello", "token": saved.token}));
      final reply = await _read(messages);
      if (reply["type"] == "welcome") {
        return SavedTv(
          id: id,
          name: name,
          token: saved.token,
          host: host,
          port: port,
        );
      }
      await _store!.forgetTv(id);
      if (askCode == null) {
        throw const RemoteConnectException(
          "The TV no longer knows this phone. Connect again to pair",
        );
      }
      throw const _PairAgain();
    }
    if (askCode == null) {
      throw const RemoteConnectException("Not paired with this TV");
    }
    var wrongCode = false;
    while (true) {
      final code = await askCode(name, wrongCode);
      if (code == null) return null;
      socket.add(
        jsonEncode({"type": "pair", "code": code, "name": _phoneName}),
      );
      final reply = await _read(messages);
      switch (reply["type"]) {
        case "paired":
          return SavedTv(
            id: id,
            name: name,
            token: reply["token"] as String,
            host: host,
            port: port,
          );
        case "pairFailed" when reply["reason"] == "closed":
          throw const RemoteConnectException(
            "Open \"Pair a phone\" in Fred TV's settings on the TV",
          );
        case "pairFailed":
          wrongCode = true;
        default:
          throw const RemoteConnectException("The TV refused the connection");
      }
    }
  }

  Future<Map<String, dynamic>> _read(StreamIterator<dynamic> messages) async {
    if (!await messages.moveNext().timeout(_replyTimeout)) {
      throw const RemoteConnectException(
        "The TV closed the connection. Try again",
      );
    }
    return jsonDecode(messages.current as String) as Map<String, dynamic>;
  }

  Future<void> _readLoop(
    StreamIterator<dynamic> messages,
    int generation,
  ) async {
    try {
      while (await messages.moveNext()) {
        if (generation != _generation) return;
        final json = jsonDecode(messages.current as String);
        switch (json["type"]) {
          case "status":
            status.value = RemoteStatus.fromJson(json);
          case "error":
            onMessage?.call(json["message"] as String);
        }
      }
    } catch (_) {
      // Handled the same as the TV closing the connection.
    }
    if (generation != _generation) return;
    _socket = null;
    connection.value = RemoteConnection.reconnecting;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    final delay =
        _reconnectDelays[_attempts.clamp(0, _reconnectDelays.length - 1)];
    _attempts++;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () => _reconnectNow());
  }

  // Joins the attempt in progress, if any.
  Future<bool> _reconnectNow() => _reconnecting ??= () async {
    final generation = _generation;
    final tv = _tv;
    if (tv == null) return false;
    _reconnectTimer?.cancel();
    try {
      await _open(tv.host, tv.port, generation, null);
      return generation == _generation && connected;
    } on RemoteConnectException catch (e) {
      if (generation != _generation) return false;
      if (_store!.tvById(tv.id) == null) {
        onMessage?.call(e.message);
        await disconnect();
        return false;
      }
      _scheduleReconnect();
      return false;
    } finally {
      if (generation == _generation) _reconnecting = null;
    }
  }();

  String _hostForUri(String host) => host.contains(":") ? "[$host]" : host;
}
