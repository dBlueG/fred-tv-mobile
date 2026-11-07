import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:open_tv/error.dart';
import 'package:open_tv/exo_player.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/channel_playlist.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/native_bridge.dart';
import 'package:open_tv/player.dart';
import 'package:open_tv/remote/protocol.dart';
import 'package:open_tv/remote/remote_client.dart';
import 'package:open_tv/remote/remote_player_controller.dart';
import 'package:open_tv/resume_prompt.dart';
import 'package:open_tv/task_service.dart';

// Opens the player for a playable channel and returns when it is closed.
// `catchup`: a past programme of a livestream; it isn't added to history and
// no position is saved.
// The player pops with `true` when it closed because the app was left (the
// PiP window was dismissed); the app then offers to resume on return.
Future<void> openPlayer(
  BuildContext context,
  Channel channel, {
  ChannelPlaylist? playlist,
  bool catchup = false,
}) async {
  if (RemoteClient.instance.active) return _playOnTv(channel, catchup);
  final settings = await NativeBridge.instance.getSettings();
  if (!catchup) TaskService.instance.addLastWatched(channel.id!);
  if (!context.mounted) return;
  TaskService.instance.playerVisible.value = true;
  if (!catchup) ResumePrompt.playerOpened();
  final interrupted = await Navigator.push<bool>(
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
  if (interrupted != true) ResumePrompt.playerClosed();
}

// While connected to a TV, the phone only sends what to play. It never falls
// back to playing here, which could be loud and unexpected.
Future<void> _playOnTv(Channel channel, bool catchup) async {
  final url = channel.url;
  if (url == null) return;
  final headers = (await Error.tryAsyncNoLoading(
    () => NativeBridge.instance.getChannelHeaders(channel.id!),
  )).data;
  final seconds = channel.mediaType == MediaType.movie && !catchup
      ? (await Error.tryAsyncNoLoading(
          () => NativeBridge.instance.getMoviePosition(channel.id!),
        )).data
      : null;
  final sent = await RemoteClient.instance.play(
    RemoteMedia(
      url: url,
      title: channel.name,
      image: channel.image,
      isLive: channel.mediaType == MediaType.livestream,
      isEpisode: channel.isEpisode,
      startPositionMs: (seconds ?? 0) * 1000,
      referer: headers?.referrer,
      origin: headers?.httpOrigin,
      userAgent: headers?.userAgent,
    ),
  );
  if (!sent) {
    Error.showMessage(
      "Couldn't reach ${RemoteClient.instance.tvName ?? "the TV"}. "
      "Is Fred TV open on it?",
    );
    return;
  }
  if (!catchup) TaskService.instance.addLastWatched(channel.id!);
}

// On a TV: opens the player for what a phone sent. The future completes when
// the player closes.
Future<void> pushRemotePlayer(
  BuildContext context,
  RemotePlayerController remote,
  Settings settings,
) async {
  final media = remote.media;
  TaskService.instance.playerVisible.value = true;
  await Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => ExoPlayerScreen(
        channel: Channel(
          name: media.title,
          image: media.image,
          url: media.url,
          mediaType: media.isLive ? MediaType.livestream : MediaType.movie,
          sourceId: -1,
          favorite: false,
          seasonId: media.isEpisode ? -1 : null,
        ),
        settings: settings,
        remote: remote,
      ),
    ),
  );
  TaskService.instance.playerVisible.value = false;
}
