import 'package:flutter/services.dart';
import 'package:open_tv/remote/protocol.dart';

// Connects a player screen on the TV to the phone that opened it.
class RemotePlayerController {
  final RemoteMedia media;
  final void Function(RemotePlayerState state) onState;

  MethodChannel? _channel;
  Future<void> Function()? _close;

  RemotePlayerController({required this.media, required this.onState});

  void attach(MethodChannel channel, Future<void> Function() close) {
    _channel = channel;
    _close = close;
  }

  void onNativeState(String state) => onState(
    RemotePlayerState.values.firstWhere(
      (s) => s.name == state,
      orElse: () => RemotePlayerState.buffering,
    ),
  );

  void pause() => _invoke("pause");
  void resume() => _invoke("resume");
  Future<void> close() async => await _close?.call();

  void _invoke(String method) {
    _channel?.invokeMethod(method).catchError((_) {});
  }
}
