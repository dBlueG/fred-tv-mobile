import 'package:flutter/material.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/epg.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/native_bridge.dart';
import 'package:open_tv/playback.dart';

// Past programmes of a channel that the provider keeps in its archive
// (Xtream `tv_archive`), newest first, plus what's on now and next.
class CatchupView extends StatefulWidget {
  final Channel channel;
  const CatchupView({super.key, required this.channel});

  @override
  State<CatchupView> createState() => _CatchupViewState();
}

class _CatchupViewState extends State<CatchupView> {
  static const _upcomingShown = 3;

  List<EpgProgram>? programs;
  String? error;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final result = await NativeBridge.instance.getEpgPrograms(
        widget.channel.id!,
      );
      if (mounted) setState(() => programs = result);
    } catch (e) {
      if (mounted) setState(() => error = "Couldn't load the programme guide");
    }
  }

  void playLive() => openPlayer(context, widget.channel);

  void playProgram(EpgProgram program) {
    openPlayer(
      context,
      Channel(
        id: widget.channel.id,
        name: "${widget.channel.name}: ${program.title}",
        image: widget.channel.image,
        url: program.catchupUrl,
        mediaType: MediaType.movie,
        sourceId: widget.channel.sourceId,
        favorite: false,
      ),
      catchup: true,
    );
  }

  String _dayLabel(DateTime day) {
    final today = DateUtils.dateOnly(DateTime.now());
    final diff = today.difference(DateUtils.dateOnly(day)).inDays;
    if (diff == 0) return "Today";
    if (diff == 1) return "Yesterday";
    return MaterialLocalizations.of(context).formatMediumDate(day);
  }

  Widget _programTile(EpgProgram program, {VoidCallback? onTap, bool autofocus = false}) {
    final time =
        "${formatClock(program.startTime)} – ${formatClock(program.stopTime)}";
    return ListTile(
      autofocus: autofocus,
      enabled: onTap != null,
      leading: Icon(onTap != null ? Icons.play_circle_outline : Icons.schedule),
      title: Text(program.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        program.description != null ? "$time\n${program.description}" : time,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: program.description != null,
      onTap: onTap,
    );
  }

  List<Widget> _buildList() {
    final now = DateTime.now();
    final all = programs!;
    final current = all.where((p) => p.isOnAt(now)).firstOrNull;
    final upcoming = all
        .where((p) => p.startTime.isAfter(now))
        .take(_upcomingShown)
        .toList();
    final past =
        all
            .where((p) => !p.stopTime.isAfter(now) && p.catchupUrl != null)
            .toList()
          ..sort((a, b) => b.start.compareTo(a.start));

    final children = <Widget>[
      ListTile(
        autofocus: true,
        leading: const Icon(Icons.live_tv),
        title: const Text("Watch live"),
        subtitle: current != null ? Text("Now: ${current.title}") : null,
        onTap: playLive,
      ),
    ];
    if (upcoming.isNotEmpty) {
      children.add(_header("Coming up"));
      children.addAll(upcoming.map((p) => _programTile(p)));
    }
    if (past.isEmpty) {
      children.add(
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            "No past programmes are available to watch.",
            textAlign: TextAlign.center,
          ),
        ),
      );
      return children;
    }
    String? lastDay;
    for (final program in past) {
      final day = _dayLabel(program.startTime);
      if (day != lastDay) {
        children.add(_header(day));
        lastDay = day;
      }
      children.add(_programTile(program, onTap: () => playProgram(program)));
    }
    return children;
  }

  Widget _header(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Catch-up: ${widget.channel.name}")),
      body: SafeArea(
        child: error != null
            ? Center(child: Text(error!))
            : programs == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(children: _buildList()),
      ),
    );
  }
}
