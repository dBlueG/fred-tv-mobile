import 'package:fixnum/fixnum.dart';
import 'package:open_tv/generated/generated_proto.pb.dart' as pb;
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/continue_watching_item.dart';
import 'package:open_tv/models/favorite_list.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/sort_type.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:open_tv/models/channel_http_headers.dart';
import 'package:open_tv/models/source_type.dart';

extension ChannelProtoExtension on pb.Channel {
  Channel toDomain() => Channel(
    id: hasId() ? id.toInt() : null,
    name: name,
    group: hasGroup() ? group : null,
    groupId: hasGroupId() ? groupId.toInt() : null,
    image: hasImage() ? image : null,
    url: hasUrl() ? url : null,
    mediaType: MediaType.values[mediaType],
    sourceId: sourceId.toInt(),
    favorite: favorite,
    seriesId: hasSeriesId() ? seriesId.toInt() : null,
    streamId: hasStreamId() ? streamId.toInt() : null,
    seasonId: hasSeasonId() ? seasonId.toInt() : null,
    tvArchive: hasTvArchive() && tvArchive,
  );
}

extension ContinueWatchingProtoExtension on pb.ContinueWatchingItem {
  ContinueWatchingItem toDomain() => ContinueWatchingItem(
    channel: channel.toDomain(),
    position: position.toInt(),
    duration: hasDuration() ? duration.toInt() : null,
    seriesName: hasSeriesName() ? seriesName : null,
  );
}

extension SourceProtoExtension on pb.Source {
  Source toDomain() => Source(
    id: hasId() ? id.toInt() : null,
    name: name,
    url: hasUrl() ? url : null,
    urlOrigin: hasUrlOrigin() ? urlOrigin : null,
    username: hasUsername() ? username : null,
    password: hasPassword() ? password : null,
    sourceType: SourceType.values[sourceType],
    lastUpdated: hasLastUpdated() ? lastUpdated.toInt() : null,
    enabled: enabled,
  );
}

extension SourceDomainExtension on Source {
  pb.Source toProto() => pb.Source(
    id: id != null ? Int64(id!) : null,
    name: name,
    url: url,
    urlOrigin: urlOrigin,
    username: username,
    password: password,
    sourceType: sourceType.index,
    enabled: enabled,
  );
}

extension FiltersDomainExtension on Filters {
  pb.Filters toProto() => pb.Filters(
    query: query,
    sourceIds: sourceIds?.map(Int64.new) ?? [],
    mediaTypes: mediaTypes?.map((m) => pb.MediaType.valueOf(m.index)!) ?? [],
    viewType: pb.ViewType.valueOf(viewType.index),
    page: page,
    seriesId: seriesId != null ? Int64(seriesId!) : null,
    season: seasonId != null ? Int64(seasonId!) : null,
    groupId: groupId != null ? Int64(groupId!) : null,
    favoriteListId: favoriteListId != null ? Int64(favoriteListId!) : null,
    useKeywords: useKeywords,
    sort: sort?.index ?? SortType.provider.index,
  );
}

extension SettingsProtoExtension on pb.Settings {
  Settings toDomain() => Settings(
    defaultView: hasDefaultView() ? ViewType.values[defaultView] : ViewType.all,
    defaultSort: hasDefaultSort()
        ? SortType.values[defaultSort]
        : SortType.provider,
    refreshOnStart: hasRefreshOnStart() ? refreshOnStart : false,
    lowLatency: hasUseStreamCaching() ? !useStreamCaching : false,
    forceTVMode: hasForceTvMode() ? forceTvMode : false,
    showLivestreams: hasShowLivestreams() ? showLivestreams : true,
    showMovies: hasShowMovies() ? showMovies : true,
    showSeries: hasShowSeries() ? showSeries : true,
    volumeBrightnessGestures: hasVolumeBrightnessGestures()
        ? volumeBrightnessGestures
        : true,
    swipeToChangeChannel: hasSwipeToChangeChannel()
        ? swipeToChangeChannel
        : true,
    doubleTapSeek: hasDoubleTapSeek() ? doubleTapSeek : true,
    seekSeconds: hasSeekSeconds() ? seekSeconds : 10,
    pictureInPicture: hasPictureInPicture() ? pictureInPicture : true,
    keepAudioAfterPip: hasKeepAudioAfterPip() ? keepAudioAfterPip : false,
    showContinueWatching: hasShowContinueWatching()
        ? showContinueWatching
        : true,
    autoplayNextEpisode: hasAutoplayNextEpisode() ? autoplayNextEpisode : true,
    autoplayCountdownSeconds: hasAutoplayCountdownSeconds()
        ? autoplayCountdownSeconds
        : 10,
  );
}

extension SettingsDomainExtension on Settings {
  pb.Settings toProto() => pb.Settings(
    defaultView: defaultView.index,
    defaultSort: defaultSort.index,
    refreshOnStart: refreshOnStart,
    useStreamCaching: !lowLatency,
    forceTvMode: forceTVMode,
    showLivestreams: showLivestreams,
    showMovies: showMovies,
    showSeries: showSeries,
    volumeBrightnessGestures: volumeBrightnessGestures,
    swipeToChangeChannel: swipeToChangeChannel,
    doubleTapSeek: doubleTapSeek,
    seekSeconds: seekSeconds,
    pictureInPicture: pictureInPicture,
    keepAudioAfterPip: keepAudioAfterPip,
    showContinueWatching: showContinueWatching,
    autoplayNextEpisode: autoplayNextEpisode,
    autoplayCountdownSeconds: autoplayCountdownSeconds,
  );
}

extension ChannelHttpHeadersProtoExtension on pb.ChannelHttpHeaders {
  ChannelHttpHeaders toDomain() => ChannelHttpHeaders(
    id: hasId() ? id.toInt() : null,
    channelId: hasChannelId() ? channelId.toInt() : null,
    referrer: hasReferrer() ? referrer : null,
    userAgent: hasUserAgent() ? userAgent : null,
    httpOrigin: hasHttpOrigin() ? httpOrigin : null,
    ignoreSSL: hasIgnoreSsl() ? ignoreSsl.toString() : null,
  );
}

extension FavoriteListProtoExtension on pb.FavoriteList {
  FavoriteList toDomain() => FavoriteList(id: id.toInt(), name: name);
}
