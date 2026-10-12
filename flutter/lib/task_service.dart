import 'package:flutter/foundation.dart';
import 'package:open_tv/error.dart';
import 'package:open_tv/models/favorite_list.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/native_bridge.dart';

class TaskService {
  TaskService._();
  static final TaskService instance = TaskService._();

  final ValueNotifier<String?> runningTask = ValueNotifier(null);
  final ValueNotifier<bool> playerVisible = ValueNotifier(false);
  // Bumped whenever favorite lists are created, renamed or deleted.
  final ValueNotifier<int> favoriteListsVersion = ValueNotifier(0);
  // Bumped whenever a watch position is saved or removed.
  final ValueNotifier<int> watchProgressVersion = ValueNotifier(0);

  static const _refreshLabel = "Refresh in progress";
  static const _deleteSourceLabel = "Deleting source";
  static const _restoreLabel = "Restoring backup";

  bool get busy => runningTask.value != null;

  bool get isDeletingSource => runningTask.value == _deleteSourceLabel;

  void notifyBusy() => Error.showMessage("${runningTask.value}, please wait");

  Future<bool> favorite(int channelId, bool value) async {
    if (busy) {
      notifyBusy();
      return false;
    }
    await NativeBridge.instance.favorite(channelId, value);
    return true;
  }

  Future<bool> setChannelFavoriteLists(
    int channelId,
    bool favorite,
    List<int> listIds,
  ) async {
    if (busy) {
      notifyBusy();
      return false;
    }
    await NativeBridge.instance.setChannelFavoriteLists(
      channelId,
      favorite,
      listIds,
    );
    return true;
  }

  Future<FavoriteList?> createFavoriteList(String name) async {
    if (busy) {
      notifyBusy();
      return null;
    }
    final list = await NativeBridge.instance.createFavoriteList(name);
    favoriteListsVersion.value++;
    return list;
  }

  Future<bool> renameFavoriteList(int listId, String name) async {
    if (busy) {
      notifyBusy();
      return false;
    }
    await NativeBridge.instance.renameFavoriteList(listId, name);
    favoriteListsVersion.value++;
    return true;
  }

  Future<bool> deleteFavoriteList(int listId) async {
    if (busy) {
      notifyBusy();
      return false;
    }
    await NativeBridge.instance.deleteFavoriteList(listId);
    favoriteListsVersion.value++;
    return true;
  }

  Future<void> addLastWatched(int channelId) async {
    if (busy) return;
    await NativeBridge.instance.addLastWatched(channelId);
  }

  Future<void> setMoviePosition(
    int channelId,
    int position, [
    int? duration,
  ]) async {
    if (busy) return;
    await NativeBridge.instance.setMoviePosition(channelId, position, duration);
    watchProgressVersion.value++;
  }

  Future<void> removeMoviePosition(int channelId) async {
    if (busy) {
      notifyBusy();
      return;
    }
    await NativeBridge.instance.removeMoviePosition(channelId);
    watchProgressVersion.value++;
  }

  Future<void> exportBackup(Future<bool> Function(String json) save) async {
    if (busy) {
      notifyBusy();
      return;
    }
    await Error.tryAsyncNoLoading(() async {
      final json = await NativeBridge.instance.exportBackup();
      if (await save(json)) Error.showMessage("Backup saved");
    });
  }

  Future<void> importBackup(String json) async {
    if (busy) {
      notifyBusy();
      return;
    }
    runningTask.value = _restoreLabel;
    try {
      await Error.tryAsyncNoLoading(() async {
        final summary = await NativeBridge.instance.importBackup(json);
        favoriteListsVersion.value++;
        watchProgressVersion.value++;
        Error.showMessage(summary);
      });
    } finally {
      runningTask.value = null;
    }
  }

  Future<void> refreshAll() => _run(
    _refreshLabel,
    () => NativeBridge.instance.refreshAll(),
    "Successfully refreshed all sources",
  );

  Future<void> refreshSource(Source source) => _run(
    _refreshLabel,
    () => NativeBridge.instance.refreshSource(source),
    "Source has been refreshed successfully",
  );

  Future<void> deleteSource(int id) => _run(
    _deleteSourceLabel,
    () => NativeBridge.instance.deleteSource(id),
    "Successfully deleted source",
  );

  Future<void> _run(
    String label,
    Future<void> Function() task,
    String successMessage,
  ) async {
    if (busy) return;
    runningTask.value = label;
    try {
      await Error.tryAsyncNoLoading(task, true, successMessage);
    } finally {
      runningTask.value = null;
    }
  }
}
