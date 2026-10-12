import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/sort_type.dart';
import 'package:open_tv/models/view_type.dart';

class Settings {
  ViewType defaultView;
  SortType defaultSort;
  bool refreshOnStart;
  bool showLivestreams;
  bool lowLatency;
  bool showMovies;
  bool showSeries;
  bool forceTVMode;
  // Player (Android)
  bool volumeBrightnessGestures;
  bool swipeToChangeChannel;
  bool doubleTapSeek;
  int seekSeconds;
  bool pictureInPicture;
  bool keepAudioAfterPip;
  bool autoplayNextEpisode;
  int autoplayCountdownSeconds;
  // Home
  bool showContinueWatching;
  bool showEpg;
  String? parentalPin;
  Settings({
    this.defaultView = ViewType.all,
    this.defaultSort = SortType.provider,
    this.refreshOnStart = false,
    this.showLivestreams = true,
    this.lowLatency = false,
    this.showMovies = true,
    this.showSeries = true,
    this.forceTVMode = false,
    this.volumeBrightnessGestures = true,
    this.swipeToChangeChannel = true,
    this.doubleTapSeek = true,
    this.seekSeconds = 10,
    this.pictureInPicture = true,
    this.keepAudioAfterPip = false,
    this.autoplayNextEpisode = true,
    this.autoplayCountdownSeconds = 10,
    this.showContinueWatching = true,
    this.showEpg = true,
    this.parentalPin,
  });

  static const seekSecondsOptions = [10, 15, 30];
  static const autoplayCountdownOptions = [5, 10, 15];

  List<MediaType> getMediaTypes() {
    return [
      if (showLivestreams) MediaType.livestream,
      if (showMovies) MediaType.movie,
      if (showSeries) MediaType.serie,
    ];
  }
}
