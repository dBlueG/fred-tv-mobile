import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/source_type.dart';

// Messages between the phone and Fred TV on an Android TV, as JSON text over a
// WebSocket on the local network. The TV sends "server" as soon as a client
// connects; the client then answers with "hello" (paired) or "pair" (new).
const remotePort = 47920;
const remoteServiceType = "_fredtv._tcp";
const remoteServiceIdAttribute = "id";

// Largest message a client may send; a play request is far smaller.
const remoteMaxMessageChars = 64 * 1024;

enum RemotePlayerState { idle, buffering, playing, paused, ended, error }

// What the TV should play. The TV doesn't need the source, so everything the
// player needs travels with the request.
class RemoteMedia {
  final String url;
  final String title;
  final String? image;
  final bool isLive;
  final bool isEpisode;
  final int startPositionMs;
  final String? referer;
  final String? origin;
  final String? userAgent;

  const RemoteMedia({
    required this.url,
    required this.title,
    this.image,
    this.isLive = false,
    this.isEpisode = false,
    this.startPositionMs = 0,
    this.referer,
    this.origin,
    this.userAgent,
  });

  Map<String, dynamic> toJson() => {
    "url": url,
    "title": title,
    "image": image,
    "isLive": isLive,
    "isEpisode": isEpisode,
    "startPositionMs": startPositionMs,
    "referer": referer,
    "origin": origin,
    "userAgent": userAgent,
  };

  // Throws on a malformed request.
  factory RemoteMedia.fromJson(Map<String, dynamic> json) => RemoteMedia(
    url: json["url"] as String,
    title: json["title"] as String,
    image: json["image"] as String?,
    isLive: json["isLive"] as bool? ?? false,
    isEpisode: json["isEpisode"] as bool? ?? false,
    startPositionMs: (json["startPositionMs"] as num?)?.toInt() ?? 0,
    referer: json["referer"] as String?,
    origin: json["origin"] as String?,
    userAgent: json["userAgent"] as String?,
  );
}

// A source sent to the TV, which downloads its channels itself.
class RemoteSource {
  final String name;
  final SourceType sourceType;
  final String url;
  final String? username;
  final String? password;
  final bool locked;

  const RemoteSource({
    required this.name,
    required this.sourceType,
    required this.url,
    this.username,
    this.password,
    this.locked = false,
  });

  // A local M3U file exists only on the phone, so it can't be sent.
  static bool canSend(Source source) =>
      source.sourceType != SourceType.m3u && source.url != null;

  factory RemoteSource.fromSource(Source source) => RemoteSource(
    name: source.name,
    sourceType: source.sourceType,
    url: source.url!,
    username: source.username,
    password: source.password,
    locked: source.locked,
  );

  Source toSource() => Source(
    name: name,
    sourceType: sourceType,
    url: url,
    username: username,
    password: password,
  );

  Map<String, dynamic> toJson() => {
    "name": name,
    "sourceType": sourceType.name,
    "url": url,
    "username": username,
    "password": password,
    "locked": locked,
  };

  // Throws on a malformed source, or one the TV shouldn't load: only web
  // addresses, so a message can't point it at a file on the TV.
  factory RemoteSource.fromJson(Map<String, dynamic> json) {
    final url = json["url"] as String;
    final type = SourceType.values.byName(json["sourceType"] as String);
    final scheme = Uri.parse(url).scheme;
    if (type == SourceType.m3u || (scheme != "http" && scheme != "https")) {
      throw const FormatException("Source can't be sent");
    }
    final name = (json["name"] as String).trim();
    if (name.isEmpty) throw const FormatException("Source has no name");
    return RemoteSource(
      name: name,
      sourceType: type,
      url: url,
      username: json["username"] as String?,
      password: json["password"] as String?,
      locked: json["locked"] as bool? ?? false,
    );
  }
}

class RemoteStatus {
  final RemotePlayerState state;
  final String? title;

  const RemoteStatus(this.state, [this.title]);

  static const idle = RemoteStatus(RemotePlayerState.idle);

  Map<String, dynamic> toJson() => {"state": state.name, "title": title};

  factory RemoteStatus.fromJson(Map<String, dynamic> json) => RemoteStatus(
    RemotePlayerState.values.firstWhere(
      (s) => s.name == json["state"],
      orElse: () => RemotePlayerState.idle,
    ),
    json["title"] as String?,
  );
}
