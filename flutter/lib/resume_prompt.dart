import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_tv/app_keys.dart';
import 'package:open_tv/error.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:open_tv/native_bridge.dart';
import 'package:open_tv/playback.dart';
import 'package:open_tv/task_service.dart';
import 'package:path_provider/path_provider.dart';

// Offers to resume playback when the app comes back after being left while
// the player was open: the PiP window was closed, or the app was swiped away
// or killed. A marker file exists while the player is open, so this also
// works after the process was restarted. The last watched item is the first
// one in History.
class ResumePrompt {
  static File? _marker;
  static AppLifecycleListener? _listener;

  static Future<File> _file() async => _marker ??= File(
    "${(await getApplicationSupportDirectory()).path}/player_open",
  );

  // Call once at start; offers to resume if the last session was cut short.
  static void init() {
    _listener ??= AppLifecycleListener(onResume: offer);
    WidgetsBinding.instance.addPostFrameCallback((_) => offer());
  }

  static Future<void> playerOpened() async {
    try {
      await (await _file()).create();
    } catch (_) {}
  }

  // The user closed the player themselves; nothing to resume.
  static Future<void> playerClosed() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  static Future<void> offer() async {
    if (TaskService.instance.playerVisible.value) return;
    try {
      final file = await _file();
      if (!await file.exists()) return;
      await file.delete();
    } catch (_) {
      return;
    }
    final channel = await _lastWatched();
    if (channel == null) return;
    Error.showSnackBar(
      SnackBar(
        persist: false,
        duration: const Duration(seconds: 12),
        content: Text(
          "Resume ${channel.name}?",
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        action: const SnackBarAction(label: "Resume", onPressed: _resume),
      ),
    );
  }

  // Looked up again on tap, as a refresh may have replaced the channel.
  static Future<void> _resume() async {
    final channel = await _lastWatched();
    final context = navigatorKey.currentContext;
    if (channel == null || context == null || !context.mounted) return;
    await openPlayer(context, channel);
  }

  static Future<Channel?> _lastWatched() async {
    final result = await Error.tryAsyncNoLoading(() async {
      final channels = await NativeBridge.instance.getChannels(
        Filters(
          viewType: ViewType.history,
          sourceIds: await NativeBridge.instance.getEnabledSourcesMinimal(),
          mediaTypes: [MediaType.livestream, MediaType.movie, MediaType.serie],
        ),
      );
      return channels.isEmpty ? null : channels.first;
    });
    return result.data;
  }
}
