import 'dart:convert';
import 'dart:io';

import 'package:open_tv/remote/protocol.dart';
import 'package:path_provider/path_provider.dart';

class PairedPhone {
  final String token;
  final String name;
  const PairedPhone({required this.token, required this.name});

  Map<String, dynamic> toJson() => {"token": token, "name": name};
  factory PairedPhone.fromJson(Map<String, dynamic> json) =>
      PairedPhone(token: json["token"], name: json["name"]);
}

class SavedTv {
  final String id;
  final String name;
  final String token;
  final String host;
  final int port;
  const SavedTv({
    required this.id,
    required this.name,
    required this.token,
    required this.host,
    this.port = remotePort,
  });

  Map<String, dynamic> toJson() => {
    "id": id,
    "name": name,
    "token": token,
    "host": host,
    "port": port,
  };
  factory SavedTv.fromJson(Map<String, dynamic> json) => SavedTv(
    id: json["id"],
    name: json["name"],
    token: json["token"],
    host: json["host"],
    port: json["port"] ?? remotePort,
  );
}

// Pairing state, kept in its own file instead of Settings: it belongs to this
// device, so a backup must neither carry the tokens nor restore them elsewhere.
class RemoteStore {
  final File _file;
  bool allowControl = false;
  String? tvId;
  List<PairedPhone> phones = [];
  List<SavedTv> tvs = [];
  Future<void> _writes = Future.value();

  RemoteStore._(this._file);

  static Future<RemoteStore>? _shared;

  static Future<RemoteStore> shared() => _shared ??= () async {
    final dir = await getApplicationSupportDirectory();
    return load(File("${dir.path}/remote.json"));
  }();

  static Future<RemoteStore> load(File file) async {
    final store = RemoteStore._(file);
    try {
      final json = jsonDecode(await file.readAsString());
      store.allowControl = json["allowControl"] ?? false;
      store.tvId = json["tvId"];
      store.phones = [
        for (final p in json["phones"] ?? []) PairedPhone.fromJson(p),
      ];
      store.tvs = [for (final t in json["tvs"] ?? []) SavedTv.fromJson(t)];
    } catch (_) {
      // Missing or damaged: start over; the worst case is pairing again.
    }
    return store;
  }

  SavedTv? tvById(String id) {
    for (final tv in tvs) {
      if (tv.id == id) return tv;
    }
    return null;
  }

  Future<void> saveTv(SavedTv tv) {
    tvs = [
      for (final t in tvs)
        if (t.id != tv.id) t,
      tv,
    ];
    return save();
  }

  Future<void> forgetTv(String id) {
    tvs = [
      for (final t in tvs)
        if (t.id != id) t,
    ];
    return save();
  }

  // Written to the side first so a crash can't leave half a file behind.
  Future<void> save() {
    final json = jsonEncode({
      "allowControl": allowControl,
      "tvId": tvId,
      "phones": phones,
      "tvs": tvs,
    });
    return _writes = _writes.catchError((_) {}).then((_) async {
      final temp = File("${_file.path}.tmp");
      await temp.writeAsString(json, flush: true);
      await temp.rename(_file.path);
    });
  }
}
