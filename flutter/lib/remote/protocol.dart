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
