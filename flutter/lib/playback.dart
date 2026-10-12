import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:open_tv/exo_player.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/channel_playlist.dart';
import 'package:open_tv/native_bridge.dart';
import 'package:open_tv/player.dart';
import 'package:open_tv/task_service.dart';

// Opens the player for a playable channel and returns when it is closed.
Future<void> openPlayer(
  BuildContext context,
  Channel channel, {
  ChannelPlaylist? playlist,
}) async {
  final settings = await NativeBridge.instance.getSettings();
  TaskService.instance.addLastWatched(channel.id!);
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
            )
          : Player(channel: channel, settings: settings),
    ),
  );
  TaskService.instance.playerVisible.value = false;
}
