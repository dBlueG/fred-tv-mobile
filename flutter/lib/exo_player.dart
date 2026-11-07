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
import 'package:open_tv/remote/remote_player_controller.dart';
import 'package:open_tv/task_service.dart';

class ExoPlayerScreen extends StatefulWidget {
  final Channel channel;
  final Settings settings;
  final ChannelPlaylist? playlist;
  final bool catchup;
  // Set on a TV playing for a phone. The channel isn't in this device's
  // database then, so nothing is looked up or saved.
  final RemotePlayerController? remote;
  const ExoPlayerScreen({
    super.key,
    required this.channel,
    required this.settings,
    this.playlist,
    this.catchup = false,
    this.remote,
  });

  // Closes the open player, if any, saving its position as leaving it does.
  static Future<void> closeActive() async =>
      _ExoPlayerScreenState._active?._close();

  @override
  State<ExoPlayerScreen> createState() => _ExoPlayerScreenState();
}

class _ExoPlayerScreenState extends State<ExoPlayerScreen> {
  static const _viewType = "dev.fredol.open_tv/exoplayer";
  static _ExoPlayerScreenState? _active;

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
    _active = this;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _init();
  }

  Future<ChannelHttpHeaders?> _getHeaders(Channel channel) async {
    final remote = widget.remote;
    if (remote != null) {
      return ChannelHttpHeaders(
        referrer: remote.media.referer,
        httpOrigin: remote.media.origin,
        userAgent: remote.media.userAgent,
      );
    }
    return (await Error.tryAsyncNoLoading(() async {
      return await NativeBridge.instance.getChannelHeaders(channel.id!);
    })).data;
  }

  Future<void> _init() async {
    final headers = await _getHeaders(widget.channel);
    final settings = widget.settings;
    final remote = widget.remote;
    final seconds =
        remote == null &&
            widget.channel.mediaType == MediaType.movie &&
            !widget.catchup
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
        "startPositionMs":
            remote?.media.startPositionMs ?? (seconds ?? 0) * 1000,
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
        "pictureInPicture": remote == null && settings.pictureInPicture,
        "keepAudioAfterPip": settings.keepAudioAfterPip,
        "isEpisode": widget.channel.isEpisode,
        "autoplayNext": remote == null && settings.autoplayNextEpisode,
        "autoplayCountdown": settings.autoplayCountdownSeconds,
      };
      _ready = true;
    });
  }

  void _onPlatformViewCreated(int id) {
    _channel = MethodChannel("dev.fredol.open_tv/exoplayer_$id");
    widget.remote?.attach(_channel!);
    _channel!.setMethodCallHandler((call) async {
      switch (call.method) {
        case "onBack":
          _onExit();
        case "onPipClosed":
          _onExit(interrupted: true);
        case "switchChannel":
          return _switchChannel(call.arguments as int);
        case "nextEpisode":
          return _getNextEpisode(Map<String, dynamic>.from(call.arguments));
        case "playNext":
          _playNext();
        case "playerState":
          widget.remote?.onNativeState(call.arguments as String);
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

  // Pausing first keeps it from being heard over whatever opens next.
  Future<void> _close() async {
    try {
      await _channel?.invokeMethod("pause");
    } catch (_) {}
    await _onExit();
  }

  // `interrupted`: the PiP window was dismissed, so the app is in the
  // background; the list is shown on return, with an offer to resume.
  Future<void> _onExit({bool interrupted = false}) async {
    if (_exiting) return;
    _exiting = true;
    if (_current.mediaType == MediaType.movie &&
        !widget.catchup &&
        widget.remote == null &&
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
    Navigator.of(context).pop(interrupted);
    _restoreSystemUi();
  }

  // Back to the device's own rotation setting. Listing all orientations
  // instead would follow the sensor even with auto-rotate off.
  void _restoreSystemUi() {
    SystemChrome.setPreferredOrientations([]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  @override
  void dispose() {
    if (identical(_active, this)) _active = null;
    // Also when the screen is closed some other way than _onExit.
    _restoreSystemUi();
    super.dispose();
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
