import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:fixnum/fixnum.dart';
import 'package:protobuf/protobuf.dart' as $pb;

import 'generated/generated_proto.pb.dart' as pb;
import 'generated/bindings.dart' as ffi;
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/continue_watching_item.dart';
import 'package:open_tv/models/epg.dart';
import 'package:open_tv/models/favorite_list.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/extensions/proto_extensions.dart';
import 'package:open_tv/models/channel_http_headers.dart';

class NativeBridge {
  static NativeBridge? _instance;

  final ffi.RustLibBindings _bindings;
  int _nextTaskId = 0;
  final Map<int, Completer<pb.FFIResult>> _pendingRequests = {};
  late final NativeCallable<Void Function(Uint64, Pointer<Uint8>, Size)>
  _globalCallback;

  static NativeBridge get instance => _instance ??= NativeBridge._internal(
    ffi.RustLibBindings(_openDynamicLibrary()),
  );

  static DynamicLibrary _openDynamicLibrary() {
    if (Platform.isAndroid || Platform.isLinux) {
      return DynamicLibrary.open("libfred_tv_lib.so");
    }
    if (Platform.isIOS || Platform.isMacOS) {
      return DynamicLibrary.process();
    }
    if (Platform.isWindows) {
      return DynamicLibrary.open("fred_tv_lib.dll");
    }
    return DynamicLibrary.open("libfred_tv_lib.so");
  }

  NativeBridge._internal(this._bindings) {
    _globalCallback =
        NativeCallable<Void Function(Uint64, Pointer<Uint8>, Size)>.listener((
          int taskId,
          Pointer<Uint8> ptr,
          int len,
        ) {
          final completer = _pendingRequests.remove(taskId);
          if (completer == null) return;

          try {
            final Uint8List copiedBytes;
            try {
              final u8List = ptr.asTypedList(len);
              copiedBytes = Uint8List.fromList(u8List);
            } finally {
              _bindings.free_message(ptr, len);
            }
            final result = pb.FFIResult.fromBuffer(copiedBytes);
            completer.complete(result);
          } catch (e, stackTrace) {
            completer.completeError(e, stackTrace);
          }
        });
  }

  Future<pb.FFIResult> _executeAsync(
    void Function(int taskId, ffi.FfiCallback callback) ffiAction,
  ) async {
    final taskId = _nextTaskId++;
    final completer = Completer<pb.FFIResult>();
    _pendingRequests[taskId] = completer;
    ffiAction(taskId, _globalCallback.nativeFunction);
    final result = await completer.future;
    if (!result.success) {
      throw Exception(
        result.hasErrorMessage() ? result.errorMessage : "Unknown FFI error",
      );
    }
    return result;
  }

  Future<pb.FFIResult> _executeWithMsg<T extends $pb.GeneratedMessage>(
    T request,
    void Function(
      int taskId,
      Pointer<Uint8> ptr,
      int len,
      ffi.FfiCallback callback,
    )
    ffiAction,
  ) async {
    final pbBytes = request.writeToBuffer();
    final nativeBuffer = malloc.allocate<Uint8>(pbBytes.length);

    try {
      final pointerList = nativeBuffer.asTypedList(pbBytes.length);
      pointerList.setAll(0, pbBytes);

      return await _executeAsync((id, cb) {
        ffiAction(id, nativeBuffer, pbBytes.length, cb);
      });
    } finally {
      malloc.free(nativeBuffer);
    }
  }

  Future<void> initialize(pb.InitMessage init) async {
    await _executeWithMsg(init, (id, ptr, len, cb) {
      _bindings.initialize(id, cb, ptr, len);
    });
  }

  Future<void> processSource(Source source) async {
    await _executeWithMsg(source.toProto(), (id, ptr, len, cb) {
      _bindings.process_source(id, cb, ptr, len);
    });
  }

  Future<void> refreshSource(Source source) async {
    await _executeWithMsg(source.toProto(), (id, ptr, len, cb) {
      _bindings.refresh_source(id, cb, ptr, len);
    });
  }

  Future<void> updateSource(Source source) async {
    await _executeWithMsg(source.toProto(), (id, ptr, len, cb) {
      _bindings.update_source(id, cb, ptr, len);
    });
  }

  Future<void> setSourceEnabled(int sourceId, bool enabled) async {
    await _executeWithMsg(
      pb.SetSourceEnabled(sourceId: Int64(sourceId), enabled: enabled),
      (id, ptr, len, cb) {
        _bindings.set_source_enabled(id, cb, ptr, len);
      },
    );
  }

  Future<void> deleteSource(int id) async {
    await _executeWithMsg(pb.IdMessage(value: Int64(id)), (id, ptr, len, cb) {
      _bindings.delete_source(id, cb, ptr, len);
    });
  }

  Future<List<Source>> getSources() async {
    final result = await _executeAsync((id, cb) {
      _bindings.get_sources(id, cb);
    });
    return result.sourceList.sources.map((s) => s.toDomain()).toList();
  }

  Future<List<int>> getEnabledSourcesMinimal() async {
    final result = await _executeAsync((id, cb) {
      _bindings.get_enabled_sources_minimal(id, cb);
    });
    return result.enabledSourcesMinimal.listId.map((e) => e.toInt()).toList();
  }

  Future<bool> hasSources() async {
    final result = await _executeAsync((id, cb) {
      _bindings.has_sources(id, cb);
    });
    return result.boolMessage.value;
  }

  Future<List<Channel>> getChannels(Filters filters) async {
    final result = await _executeWithMsg(filters.toProto(), (id, ptr, len, cb) {
      _bindings.get_channels(id, cb, ptr, len);
    });
    return result.channelList.channels.map((c) => c.toDomain()).toList();
  }

  Future<void> favorite(int channelId, bool isFavorite) async {
    await _executeWithMsg(
      pb.ToggleFavorite(channelId: Int64(channelId), favorite: isFavorite),
      (id, ptr, len, cb) {
        _bindings.favorite(id, cb, ptr, len);
      },
    );
  }

  Future<List<FavoriteList>> getFavoriteLists() async {
    final result = await _executeAsync((id, cb) {
      _bindings.get_favorite_lists(id, cb);
    });
    return result.favoriteLists.lists.map((l) => l.toDomain()).toList();
  }

  Future<FavoriteList> createFavoriteList(String name) async {
    final result = await _executeWithMsg(pb.StrMessage(value: name), (
      id,
      ptr,
      len,
      cb,
    ) {
      _bindings.create_favorite_list(id, cb, ptr, len);
    });
    return result.favoriteList.toDomain();
  }

  Future<void> renameFavoriteList(int listId, String name) async {
    await _executeWithMsg(
      pb.RenameFavoriteList(id: Int64(listId), name: name),
      (id, ptr, len, cb) {
        _bindings.rename_favorite_list(id, cb, ptr, len);
      },
    );
  }

  Future<void> deleteFavoriteList(int listId) async {
    await _executeWithMsg(pb.IdMessage(value: Int64(listId)), (
      id,
      ptr,
      len,
      cb,
    ) {
      _bindings.delete_favorite_list(id, cb, ptr, len);
    });
  }

  Future<List<int>> getChannelFavoriteLists(int channelId) async {
    final result = await _executeWithMsg(pb.IdMessage(value: Int64(channelId)), (
      id,
      ptr,
      len,
      cb,
    ) {
      _bindings.get_channel_favorite_lists(id, cb, ptr, len);
    });
    return result.idList.ids.map((i) => i.toInt()).toList();
  }

  Future<void> setChannelFavoriteLists(
    int channelId,
    bool favorite,
    List<int> listIds,
  ) async {
    await _executeWithMsg(
      pb.SetChannelFavoriteLists(
        channelId: Int64(channelId),
        favorite: favorite,
        listIds: listIds.map(Int64.new),
      ),
      (id, ptr, len, cb) {
        _bindings.set_channel_favorite_lists(id, cb, ptr, len);
      },
    );
  }

  Future<Settings> getSettings() async {
    final result = await _executeAsync((id, cb) {
      _bindings.get_settings(id, cb);
    });
    return result.settings.toDomain();
  }

  Future<void> updateSettings(Settings settings) async {
    await _executeWithMsg(settings.toProto(), (id, ptr, len, cb) {
      _bindings.update_settings(id, cb, ptr, len);
    });
  }

  Future<void> addLastWatched(int id) async {
    await _executeWithMsg(pb.IdMessage(value: Int64(id)), (id, ptr, len, cb) {
      _bindings.add_last_watched(id, cb, ptr, len);
    });
  }

  Future<void> setMoviePosition(
    int channelId,
    int position, [
    int? duration,
  ]) async {
    await _executeWithMsg(
      pb.MoviePosition(
        channelId: Int64(channelId),
        position: Int64(position),
        duration: duration != null && duration > 0 ? Int64(duration) : null,
      ),
      (id, ptr, len, cb) {
        _bindings.set_movie_position(id, cb, ptr, len);
      },
    );
  }

  Future<void> removeMoviePosition(int channelId) async {
    await _executeWithMsg(pb.IdMessage(value: Int64(channelId)), (
      id,
      ptr,
      len,
      cb,
    ) {
      _bindings.remove_movie_position(id, cb, ptr, len);
    });
  }

  Future<List<ContinueWatchingItem>> getContinueWatching(
    bool includeLocked,
  ) async {
    final result = await _executeWithMsg(
      pb.BoolMessage(value: includeLocked),
      (id, ptr, len, cb) {
        _bindings.get_continue_watching(id, cb, ptr, len);
      },
    );
    return result.continueWatching.items.map((i) => i.toDomain()).toList();
  }

  Future<Channel?> getNextEpisode(int channelId) async {
    final result = await _executeWithMsg(pb.IdMessage(value: Int64(channelId)), (
      id,
      ptr,
      len,
      cb,
    ) {
      _bindings.get_next_episode(id, cb, ptr, len);
    });
    return result.hasChannel() ? result.channel.toDomain() : null;
  }

  Future<void> setGroupLocked(int groupId, bool locked) async {
    await _executeWithMsg(
      pb.SetLocked(id: Int64(groupId), locked: locked),
      (id, ptr, len, cb) {
        _bindings.set_group_locked(id, cb, ptr, len);
      },
    );
  }

  Future<void> setSourceLocked(int sourceId, bool locked) async {
    await _executeWithMsg(
      pb.SetLocked(id: Int64(sourceId), locked: locked),
      (id, ptr, len, cb) {
        _bindings.set_source_locked(id, cb, ptr, len);
      },
    );
  }

  // Now/next for the Xtream livestreams among these channels, by channel id.
  Future<Map<int, EpgNowNext>> getEpgNowNext(List<int> channelIds) async {
    final result = await _executeWithMsg(
      pb.IdList(ids: channelIds.map(Int64.new)),
      (id, ptr, len, cb) {
        _bindings.get_epg_now_next(id, cb, ptr, len);
      },
    );
    return {
      for (final item in result.epgNowNext.items)
        item.channelId.toInt(): item.toDomain(),
    };
  }

  // The channel's guide, including programmes available for catch-up.
  Future<List<EpgProgram>> getEpgPrograms(int channelId) async {
    final result = await _executeWithMsg(
      pb.IdMessage(value: Int64(channelId)),
      (id, ptr, len, cb) {
        _bindings.get_epg_programs(id, cb, ptr, len);
      },
    );
    return result.epgPrograms.programs.map((p) => p.toDomain()).toList();
  }

  Future<String> exportBackup() async {
    final result = await _executeAsync((id, cb) {
      _bindings.export_backup(id, cb);
    });
    return result.strMessage.value;
  }

  // Returns a summary of what was restored.
  Future<String> importBackup(String json) async {
    final result = await _executeWithMsg(pb.StrMessage(value: json), (
      id,
      ptr,
      len,
      cb,
    ) {
      _bindings.import_backup(id, cb, ptr, len);
    });
    return result.strMessage.value;
  }

  Future<int?> getMoviePosition(int id) async {
    final result = await _executeWithMsg(pb.IdMessage(value: Int64(id)), (
      id,
      ptr,
      len,
      cb,
    ) {
      _bindings.get_movie_position(id, cb, ptr, len);
    });
    return result.hasMoviePosition() && result.moviePosition.hasPosition()
        ? result.moviePosition.position.toInt()
        : null;
  }

  Future<ChannelHttpHeaders?> getChannelHeaders(int id) async {
    final result = await _executeWithMsg(pb.IdMessage(value: Int64(id)), (
      id,
      ptr,
      len,
      cb,
    ) {
      _bindings.get_channel_headers(id, cb, ptr, len);
    });
    return result.hasHeaders() ? result.headers.toDomain() : null;
  }

  Future<void> getEpisodes(
    int seriesId,
    int sourceId,
    String? fallbackImage,
  ) async {
    final msg = pb.GetEpisodes(
      seriesId: Int64(seriesId),
      sourceId: Int64(sourceId),
      fallbackImage: fallbackImage,
    );
    await _executeWithMsg(msg, (id, ptr, len, cb) {
      _bindings.get_episodes(id, cb, ptr, len);
    });
  }

  Future<void> clearHistory() async {
    await _executeAsync((id, cb) {
      _bindings.clear_history(id, cb);
    });
  }

  Future<void> refreshAll() async {
    await _executeAsync((id, cb) {
      _bindings.refresh_all(id, cb);
    });
  }

  Future<bool> sourceNameExists(String name) async {
    final result = await _executeWithMsg(pb.StrMessage(value: name), (
      id,
      ptr,
      len,
      cb,
    ) {
      _bindings.source_name_exists(id, cb, ptr, len);
    });
    return result.boolMessage.value;
  }

  Future<bool> shouldShowWhatsNew(String? currentVersion) async {
    final result = await _executeWithMsg(
      pb.OptStrMessage(value: currentVersion),
      (id, ptr, len, cb) {
        _bindings.should_show_whats_new(id, cb, ptr, len);
      },
    );
    return result.boolMessage.value;
  }

  Future<void> updateLastSeenVersion(String version) async {
    await _executeWithMsg(pb.StrMessage(value: version), (id, ptr, len, cb) {
      _bindings.update_last_seen_version(id, cb, ptr, len);
    });
  }

  Future<Map<int, int>> getAllExpiries() async {
    final result = await _executeAsync((id, cb) {
      _bindings.get_all_expiries(id, cb);
    });
    return result.expiries.expiries.map(
      (key, value) => MapEntry(key.toInt(), value.toInt()),
    );
  }

  void dispose() {
    _globalCallback.close();
    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError("NativeBridge was disposed."));
      }
    }
    _pendingRequests.clear();
    _instance = null;
  }
}
