import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/sort_type.dart';
import 'package:open_tv/models/view_type.dart';

class Filters {
  String? query;
  List<int>? sourceIds;
  List<MediaType>? mediaTypes;
  ViewType viewType;
  int page;
  int? seriesId;
  int? seasonId;
  int? groupId;
  int? favoriteListId;
  bool useKeywords;
  SortType? sort;

  Filters({
    this.query,
    this.sourceIds,
    this.mediaTypes,
    required this.viewType,
    this.page = 1,
    this.seriesId,
    this.seasonId,
    this.groupId,
    this.favoriteListId,
    this.useKeywords = false,
    this.sort,
  });

  Filters copy() => Filters(
    query: query,
    sourceIds: sourceIds != null ? List.of(sourceIds!) : null,
    mediaTypes: mediaTypes != null ? List.of(mediaTypes!) : null,
    viewType: viewType,
    page: page,
    seriesId: seriesId,
    seasonId: seasonId,
    groupId: groupId,
    favoriteListId: favoriteListId,
    useKeywords: useKeywords,
    sort: sort,
  );
}
