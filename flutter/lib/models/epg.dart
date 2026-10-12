class EpgProgram {
  final String title;
  final String? description;
  // Unix seconds
  final int start;
  final int stop;
  final bool hasArchive;
  // Set when the programme can be replayed (catch-up).
  final String? catchupUrl;

  EpgProgram({
    required this.title,
    this.description,
    required this.start,
    required this.stop,
    this.hasArchive = false,
    this.catchupUrl,
  });

  DateTime get startTime => DateTime.fromMillisecondsSinceEpoch(start * 1000);
  DateTime get stopTime => DateTime.fromMillisecondsSinceEpoch(stop * 1000);

  bool isOnAt(DateTime time) =>
      !time.isBefore(startTime) && time.isBefore(stopTime);

  double progressAt(DateTime time) {
    final total = stop - start;
    if (total <= 0) return 0;
    return ((time.millisecondsSinceEpoch ~/ 1000 - start) / total).clamp(
      0.0,
      1.0,
    );
  }
}

class EpgNowNext {
  final int channelId;
  final EpgProgram? now;
  final EpgProgram? next;

  EpgNowNext({required this.channelId, this.now, this.next});

  bool get isEmpty => now == null && next == null;
}

String formatClock(DateTime time) =>
    "${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}";
