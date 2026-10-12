import 'package:open_tv/models/channel.dart';

class ContinueWatchingItem {
  final Channel channel;
  // Seconds
  final int position;
  final int? duration;
  final String? seriesName;

  ContinueWatchingItem({
    required this.channel,
    required this.position,
    this.duration,
    this.seriesName,
  });

  double? get progress => duration != null && duration! > 0
      ? (position / duration!).clamp(0.0, 1.0)
      : null;
}
