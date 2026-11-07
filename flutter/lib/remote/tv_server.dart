import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:open_tv/remote/protocol.dart';
import 'package:open_tv/remote/remote_store.dart';

// What the server drives: the player screen in the app, a fake in tests.
abstract class RemotePlayerHost {
  // Returns an error to show on the phone, or null when playback started.
  Future<String?> play(RemoteMedia media);
  void pause();
  void resume();
  Future<void> stop();
  // Returns a summary to show on the phone.
  Future<String> addSources(List<RemoteSource> sources);
}

// The TV's end of the link. Only paired phones may send commands: stream links
// can contain the provider's username and password.
class TvServer {
  static const _maxPendingClients = 8;
  static const _maxCodeAttempts = 5;
  static const _authTimeout = Duration(minutes: 2);
  static const _pingInterval = Duration(seconds: 10);

  final RemoteStore store;
  final RemotePlayerHost host;
  final String name;
  final int port;

  // The code shown on the TV; null while pairing isn't open.
  final ValueNotifier<String?> pairingCode = ValueNotifier(null);
  // Name of the last phone paired while the code was shown.
  final ValueNotifier<String?> lastPaired = ValueNotifier(null);

  final _random = Random.secure();
  final _pending = <WebSocket>{};
  final _clients = <WebSocket>{};
  HttpServer? _server;
  int _wrongCodes = 0;
  RemoteStatus _status = RemoteStatus.idle;

  TvServer({
    required this.store,
    required this.host,
    required this.name,
    this.port = remotePort,
  });

  bool get running => _server != null;
  // The port actually bound; differs from `port` when that is 0 (tests).
  int get boundPort => _server?.port ?? port;

  Future<void> start() async {
    if (running) return;
    if (store.tvId == null) {
      store.tvId = _randomHex(8);
      await store.save();
    }
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server!.listen(_onRequest, onError: (_) {});
  }

  Future<void> stop() async {
    closePairing();
    final server = _server;
    _server = null;
    await server?.close(force: true);
    for (final socket in [..._pending, ..._clients]) {
      socket.close();
    }
    _pending.clear();
    _clients.clear();
  }

  void openPairing() {
    _wrongCodes = 0;
    lastPaired.value = null;
    pairingCode.value = _newCode();
  }

  void closePairing() => pairingCode.value = null;

  Future<void> forgetPhones() async {
    store.phones = [];
    await store.save();
    for (final socket in _clients) {
      socket.close();
    }
    _clients.clear();
  }

  void publishStatus(RemoteStatus status) {
    _status = status;
    for (final socket in _clients) {
      _send(socket, {"type": "status", ...status.toJson()});
    }
  }

  Future<void> _onRequest(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request) ||
        _pending.length >= _maxPendingClients) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final WebSocket socket;
    try {
      socket = await WebSocketTransformer.upgrade(request);
    } catch (_) {
      return;
    }
    socket.pingInterval = _pingInterval;
    _pending.add(socket);
    final authTimer = Timer(_authTimeout, () {
      if (_pending.contains(socket)) socket.close();
    });
    _send(socket, {"type": "server", "id": store.tvId, "name": name});
    socket.listen(
      (message) => _onMessage(socket, message),
      onError: (_) {},
      cancelOnError: true,
      onDone: () {
        authTimer.cancel();
        _pending.remove(socket);
        _clients.remove(socket);
      },
    );
  }

  void _onMessage(WebSocket socket, dynamic message) {
    try {
      if (message is! String || message.length > remoteMaxMessageChars) {
        throw const FormatException("Bad message");
      }
      final json = jsonDecode(message) as Map<String, dynamic>;
      final type = json["type"] as String?;
      if (_clients.contains(socket)) {
        _onCommand(socket, type, json);
      } else if (type == "hello") {
        _onHello(socket, json["token"] as String?);
      } else if (type == "pair") {
        _onPair(socket, json["code"] as String?, json["name"] as String?);
      } else {
        throw const FormatException("Not paired");
      }
    } catch (_) {
      socket.close();
    }
  }

  void _onHello(WebSocket socket, String? token) {
    final known =
        token != null && store.phones.any((p) => _sameText(p.token, token));
    if (!known) {
      _send(socket, {"type": "denied"});
      socket.close();
      return;
    }
    _accept(socket, {"type": "welcome"});
  }

  void _onPair(WebSocket socket, String? code, String? phoneName) {
    final expected = pairingCode.value;
    if (expected == null) {
      _send(socket, {"type": "pairFailed", "reason": "closed"});
      return;
    }
    if (code == null || !_sameText(code, expected)) {
      // A new code after a few misses, so the code can't simply be guessed.
      if (++_wrongCodes >= _maxCodeAttempts) {
        _wrongCodes = 0;
        pairingCode.value = _newCode();
      }
      _send(socket, {"type": "pairFailed", "reason": "code"});
      return;
    }
    final token = _randomHex(32);
    final name = phoneName ?? "Phone";
    store.phones = [...store.phones, PairedPhone(token: token, name: name)];
    store.save();
    _wrongCodes = 0;
    pairingCode.value = _newCode();
    lastPaired.value = name;
    _accept(socket, {"type": "paired", "token": token});
  }

  void _accept(WebSocket socket, Map<String, dynamic> reply) {
    _pending.remove(socket);
    _clients.add(socket);
    _send(socket, reply);
    _send(socket, {"type": "status", ..._status.toJson()});
  }

  void _onCommand(WebSocket socket, String? type, Map<String, dynamic> json) {
    switch (type) {
      case "play":
        final media = RemoteMedia.fromJson(
          json["media"] as Map<String, dynamic>,
        );
        host
            .play(media)
            .then(
              (error) => _sendError(socket, error),
              onError: (_) =>
                  _sendError(socket, "The TV couldn't start playback"),
            );
      case "pause":
        host.pause();
      case "resume":
        host.resume();
      case "stop":
        host.stop();
      case "pushSources":
        final sources = [
          for (final source in json["sources"] as List<dynamic>)
            RemoteSource.fromJson(source as Map<String, dynamic>),
        ];
        host
            .addSources(sources)
            .then(
              (summary) => _sendNotice(socket, summary),
              onError: (_) =>
                  _sendError(socket, "The TV couldn't add the sources"),
            );
      default:
        throw const FormatException("Unknown command");
    }
  }

  void _sendNotice(WebSocket socket, String message) =>
      _send(socket, {"type": "notice", "message": message});

  void _sendError(WebSocket socket, String? message) {
    if (message != null) _send(socket, {"type": "error", "message": message});
  }

  void _send(WebSocket socket, Map<String, dynamic> message) {
    if (socket.readyState == WebSocket.open) socket.add(jsonEncode(message));
  }

  String _newCode() => _random.nextInt(10000).toString().padLeft(4, "0");

  String _randomHex(int bytes) => List.generate(
    bytes,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, "0"),
  ).join();

  // Takes the same time wherever the first difference is.
  bool _sameText(String a, String b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return difference == 0;
  }
}
