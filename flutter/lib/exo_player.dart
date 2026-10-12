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
  const ExoPlayerScreen({
    super.key,
    required this.channel,
    required this.settings,
    this.playlist,
  });

  @override
  State<ExoPlayerScreen> createState() => _ExoPlayerScreenState();
}

class _ExoPlayerScreenState extends State<ExoPlayerScreen> {
  static const _viewType = "dev.fredol.open_tv/exoplayer";

  MethodChannel? _channel;
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
    final seconds = widget.channel.mediaType == MediaType.movie
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
    return {
      "url": channel.url,
      "title": channel.name,
      "image": channel.image,
      "referer": headers?.referrer,
      "origin": headers?.httpOrigin,
      "userAgent": headers?.userAgent,
    };
  }

  Future<void> _onExit() async {
    if (_exiting) return;
    _exiting = true;
    if (widget.channel.mediaType == MediaType.movie && _channel != null) {
      try {
        final posMs = await _channel!.invokeMethod<int>("getPosition") ?? 0;
        await TaskService.instance.setMoviePosition(
          widget.channel.id!,
          posMs ~/ 1000,
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
