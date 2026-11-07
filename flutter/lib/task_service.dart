import 'package:flutter/foundation.dart';
import 'package:open_tv/error.dart';
import 'package:open_tv/models/favorite_list.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/native_bridge.dart';

class SourcesAdded {
  final List<Source> added = [];
  final List<String> alreadyThere = [];
  final List<String> failed = [];
}

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
  static const _addSourcesLabel = "Adding sources";

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

  Future<bool> favoriteGroup(int groupId, bool value) async {
    if (busy) {
      notifyBusy();
      return false;
    }
    await NativeBridge.instance.favoriteGroup(groupId, value);
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

  // Adds sources and downloads their channels, leaving out those already here
  // by name or account. Returns null if something else is running. One source
  // failing doesn't stop the others.
  Future<SourcesAdded?> addSources(
    List<Source> sources,
    Set<String> lockedNames,
  ) async {
    if (busy) return null;
    runningTask.value = _addSourcesLabel;
    final result = SourcesAdded();
    try {
      for (final source in sources) {
        try {
          final existing = await NativeBridge.instance.getSources();
          if (existing.any((e) => _sameSource(e, source))) {
            result.alreadyThere.add(source.name);
            continue;
          }
          await NativeBridge.instance.processSource(source);
          if (lockedNames.contains(source.name)) {
            final sources = await NativeBridge.instance.getSources();
            final added = sources.firstWhere((s) => s.name == source.name);
            await NativeBridge.instance.setSourceLocked(added.id!, true);
            source.locked = true;
          }
          result.added.add(source);
        } catch (e) {
          debugPrint("Couldn't add source: $e");
          result.failed.add(source.name);
        }
      }
    } finally {
      runningTask.value = null;
    }
    if (result.added.isNotEmpty) updateGuides();
    return result;
  }

  bool _sameSource(Source a, Source b) =>
      a.name == b.name ||
      (a.sourceType == b.sourceType &&
          a.url == b.url &&
          a.username == b.username);

  Future<void> refreshAll() async {
    await _run(
      _refreshLabel,
      () => NativeBridge.instance.refreshAll(),
      "Successfully refreshed all sources",
    );
    updateGuides();
  }

  Future<void> refreshSource(Source source) async {
    await _run(
      _refreshLabel,
      () => NativeBridge.instance.refreshSource(source),
      "Source has been refreshed successfully",
    );
    updateGuides();
  }

  // Downloads programme guides in the background when programme search is on
  // and a guide is due (about twice a day, or never downloaded). Failures are
  // only logged: the next start tries again.
  Future<void> updateGuides({bool force = false}) async {
    try {
      if (!(await NativeBridge.instance.getSettings()).searchProgrammes) return;
      await NativeBridge.instance.updateGuides(force: force);
    } catch (e) {
      debugPrint("Programme guide update failed: $e");
    }
  }

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
