import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:open_tv/error.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/channel_http_headers.dart';
import 'package:open_tv/models/channel_playlist.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/native_bridge.dart';
import 'package:open_tv/task_service.dart';

class ExoPlayerScreen extends StatefulWidget {
  final Channel channel;
  final Settings settings;
  final ChannelPlaylist? playlist;
  final bool catchup;
  const ExoPlayerScreen({
    super.key,
    required this.channel,
    required this.settings,
    this.playlist,
    this.catchup = false,
  });

  @override
  State<ExoPlayerScreen> createState() => _ExoPlayerScreenState();
}

class _ExoPlayerScreenState extends State<ExoPlayerScreen> {
  static const _viewType = "dev.fredol.open_tv/exoplayer";

  MethodChannel? _channel;
  // The item playing now; changes when switching channels or episodes.
  late Channel _current = widget.channel;
  Channel? _nextEpisode;
  bool _exiting = false;
  bool _ready = false;
  Map<String, dynamic> _creationParams = const {};

  bool get _isLive => widget.channel.mediaType == MediaType.livestream;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _init();
  }

  Future<ChannelHttpHeaders?> _getHeaders(Channel channel) async =>
      (await Error.tryAsyncNoLoading(() async {
        return await NativeBridge.instance.getChannelHeaders(channel.id!);
      })).data;

  Future<void> _init() async {
    final headers = await _getHeaders(widget.channel);
    final settings = widget.settings;
    final seconds = widget.channel.mediaType == MediaType.movie && !widget.catchup
        ? (await Error.tryAsyncNoLoading(() async {
            return await NativeBridge.instance.getMoviePosition(
              widget.channel.id!,
            );
          })).data
        : null;
    if (!mounted) return;
    setState(() {
      _creationParams = {
        "url": widget.channel.url,
        "isLive": _isLive,
        "startPositionMs": (seconds ?? 0) * 1000,
        "title": widget.channel.name,
        "image": widget.channel.image,
        "referer": headers?.referrer,
        "origin": headers?.httpOrigin,
        "userAgent": headers?.userAgent,
        "volumeBrightnessGestures": settings.volumeBrightnessGestures,
        "swipeToChangeChannel": settings.swipeToChangeChannel,
        "canSwitchChannel": widget.playlist != null,
        "doubleTapSeek": settings.doubleTapSeek,
        "seekSeconds": settings.seekSeconds,
        "pictureInPicture": settings.pictureInPicture,
        "keepAudioAfterPip": settings.keepAudioAfterPip,
        "isEpisode": widget.channel.isEpisode,
        "autoplayNext": settings.autoplayNextEpisode,
        "autoplayCountdown": settings.autoplayCountdownSeconds,
      };
      _ready = true;
    });
  }

  void _onPlatformViewCreated(int id) {
    _channel = MethodChannel("dev.fredol.open_tv/exoplayer_$id");
    _channel!.setMethodCallHandler((call) async {
      switch (call.method) {
        case "onBack":
          _onExit();
        case "switchChannel":
          return _switchChannel(call.arguments as int);
        case "nextEpisode":
          return _getNextEpisode(Map<String, dynamic>.from(call.arguments));
        case "playNext":
          _playNext();
      }
      return null;
    });
  }

  // Returns the parameters of the channel to play next, or null to stay.
  Future<Map<String, dynamic>?> _switchChannel(int delta) async {
    final playlist = widget.playlist;
    if (playlist == null || _exiting) return null;
    final channel = await playlist.step(delta);
    if (channel == null || !mounted) return null;
    final headers = await _getHeaders(channel);
    TaskService.instance.addLastWatched(channel.id!);
    _current = channel;
    return {
      "url": channel.url,
      "title": channel.name,
      "image": channel.image,
      "referer": headers?.referrer,
      "origin": headers?.httpOrigin,
      "userAgent": headers?.userAgent,
    };
  }

  // Called when an episode ended: records it as watched and returns the next
  // one, which native code offers with a countdown.
  Future<Map<String, dynamic>?> _getNextEpisode(
    Map<String, dynamic> args,
  ) async {
    final durationMs = (args["duration"] as num?)?.toInt() ?? 0;
    final positionMs = (args["position"] as num?)?.toInt() ?? durationMs;
    await TaskService.instance.setMoviePosition(
      _current.id!,
      positionMs ~/ 1000,
      durationMs ~/ 1000,
    );
    final next = (await Error.tryAsyncNoLoading(
      () => NativeBridge.instance.getNextEpisode(_current.id!),
    )).data;
    if (next == null || !mounted || _exiting) return null;
    _nextEpisode = next;
    final headers = await _getHeaders(next);
    final seconds = (await Error.tryAsyncNoLoading(
      () => NativeBridge.instance.getMoviePosition(next.id!),
    )).data;
    return {
      "url": next.url,
      "title": next.name,
      "image": next.image,
      "startPositionMs": (seconds ?? 0) * 1000,
      "referer": headers?.referrer,
      "origin": headers?.httpOrigin,
      "userAgent": headers?.userAgent,
    };
  }

  void _playNext() {
    final next = _nextEpisode;
    if (next == null) return;
    _nextEpisode = null;
    _current = next;
    TaskService.instance.addLastWatched(next.id!);
  }

  Future<void> _onExit() async {
    if (_exiting) return;
    _exiting = true;
    if (_current.mediaType == MediaType.movie &&
        !widget.catchup &&
        _channel != null) {
      try {
        final posMs = await _channel!.invokeMethod<int>("getPosition") ?? 0;
        final durationMs =
            await _channel!.invokeMethod<int>("getDuration") ?? 0;
        await TaskService.instance.setMoviePosition(
          _current.id!,
          posMs ~/ 1000,
          durationMs ~/ 1000,
        );
      } catch (_) {}
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _onExit();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _ready ? _buildPlatformView() : const SizedBox.shrink(),
      ),
    );
  }

  Widget _buildPlatformView() {
    return PlatformViewLink(
      viewType: _viewType,
      surfaceFactory: (context, controller) {
        return AndroidViewSurface(
          controller: controller as AndroidViewController,
          // Claim every gesture so drags (volume/brightness) reach the native view.
          gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
            Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
          },
          hitTestBehavior: PlatformViewHitTestBehavior.opaque,
        );
      },
      onCreatePlatformView: (params) {
        final controller = PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: _viewType,
          layoutDirection: TextDirection.ltr,
          creationParams: _creationParams,
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () => params.onFocusChanged(true),
        );
        controller.addOnPlatformViewCreatedListener(
          params.onPlatformViewCreated,
        );
        controller.addOnPlatformViewCreatedListener(_onPlatformViewCreated);
        controller.create();
        return controller;
      },
    );
  }
}
