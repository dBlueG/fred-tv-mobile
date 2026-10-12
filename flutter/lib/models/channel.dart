import 'package:open_tv/models/media_type.dart';

class Channel {
  int? id;
  String name;
  int? groupId;
  String? group;
  String? image;
  String? url;
  MediaType mediaType;
  int sourceId;
  bool favorite;
  int? seriesId;
  int? streamId;
  // Set for series episodes.
  int? seasonId;
  bool tvArchive;
  // For categories: hidden by the parental PIN
  bool locked;

  Channel({
    this.id,
    required this.name,
    this.group,
    this.groupId,
    this.image,
    this.url,
    required this.mediaType,
    required this.sourceId,
    required this.favorite,
    this.seriesId,
    this.streamId,
    this.seasonId,
    this.tvArchive = false,
    this.locked = false,
  });

  bool get isEpisode => seasonId != null;
}
