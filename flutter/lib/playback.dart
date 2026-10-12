import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:open_tv/exo_player.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/channel_playlist.dart';
import 'package:open_tv/native_bridge.dart';
import 'package:open_tv/player.dart';
import 'package:open_tv/task_service.dart';

// Opens the player for a playable channel and returns when it is closed.
// `catchup`: a past programme of a livestream; it isn't added to history and
// no position is saved.
Future<void> openPlayer(
  BuildContext context,
  Channel channel, {
  ChannelPlaylist? playlist,
  bool catchup = false,
}) async {
  final settings = await NativeBridge.instance.getSettings();
  if (!catchup) TaskService.instance.addLastWatched(channel.id!);
  if (!context.mounted) return;
  TaskService.instance.playerVisible.value = true;
  await Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => Platform.isAndroid
          ? ExoPlayerScreen(
              channel: channel,
              settings: settings,
              playlist: playlist,
              catchup: catchup,
            )
          : Player(channel: channel, settings: settings, catchup: catchup),
    ),
  );
  TaskService.instance.playerVisible.value = false;
}
