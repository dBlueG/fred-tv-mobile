import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:open_tv/catchup_view.dart';
import 'package:open_tv/models/epg.dart';
import 'package:open_tv/playback.dart';

// Search results from the downloaded programme guide, as a horizontal row
// above the matching channels. Tapping one shows its details, with Watch
// (the channel live) or Catch-up for past programmes kept in the archive.
class ProgrammeResults extends StatelessWidget {
  final List<ProgramMatch> matches;
  const ProgrammeResults({super.key, required this.matches});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            "Programmes",
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        SizedBox(
          height: 96,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            itemCount: matches.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) => _ProgrammeCard(
              match: matches[index],
              onTap: () => showProgrammeDetails(context, matches[index]),
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

// "Now, until 13:00", "Today 20:00", "Tomorrow 20:00", "Yesterday 18:00", or
// the date for other days.
String programmeTimeLabel(BuildContext context, EpgProgram program) {
  final now = DateTime.now();
  if (program.isOnAt(now)) return "Now, until ${formatClock(program.stopTime)}";
  final start = program.startTime;
  final days = DateUtils.dateOnly(
    start,
  ).difference(DateUtils.dateOnly(now)).inDays;
  final day = switch (days) {
    0 => "Today",
    1 => "Tomorrow",
    -1 => "Yesterday",
    _ => MaterialLocalizations.of(context).formatShortMonthDay(start),
  };
  return "$day ${formatClock(start)}";
}

Future<void> showProgrammeDetails(
  BuildContext context,
  ProgramMatch match,
) async {
  final program = match.program;
  final channel = match.channel;
  final ended = !program.stopTime.isAfter(DateTime.now());
  final action = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(program.title),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "${channel.name}\n${programmeTimeLabel(context, program)}"
              " – ${formatClock(program.stopTime)}",
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            if (program.description != null) ...[
              const SizedBox(height: 12),
              Text(program.description!),
            ],
            if (ended && !program.hasArchive) ...[
              const SizedBox(height: 12),
              const Text("This programme has ended."),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text("Close"),
        ),
        if (ended && program.hasArchive)
          TextButton(
            onPressed: () => Navigator.of(context).pop("catchup"),
            child: const Text("Catch-up"),
          ),
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop("watch"),
          child: const Text("Watch channel"),
        ),
      ],
    ),
  );
  if (!context.mounted) return;
  if (action == "watch") {
    await openPlayer(context, channel);
  } else if (action == "catchup") {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => CatchupView(channel: channel)),
    );
  }
}

class _ProgrammeCard extends StatelessWidget {
  final ProgramMatch match;
  final VoidCallback onTap;

  const _ProgrammeCard({required this.match, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final program = match.program;
    final onNow = program.isOnAt(DateTime.now());
    final secondary = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return SizedBox(
      width: 260,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        color: theme.colorScheme.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: InkWell(
          onTap: onTap,
          child: Row(
            children: [
              SizedBox(
                width: 64,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: match.channel.image != null
                      ? CachedNetworkImage(
                          imageUrl: match.channel.image!,
                          memCacheHeight: 150,
                          fit: BoxFit.contain,
                          errorWidget: (_, _, _) =>
                              const Icon(Icons.tv, color: Colors.grey),
                        )
                      : const Icon(Icons.tv, color: Colors.grey),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 8, 10, 8),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        program.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        match.channel.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: secondary,
                      ),
                      Row(
                        children: [
                          if (program.hasArchive)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Icon(
                                Icons.history,
                                size: 14,
                                color: secondary?.color,
                              ),
                            ),
                          Flexible(
                            child: Text(
                              programmeTimeLabel(context, program),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: onNow
                                  ? secondary?.copyWith(
                                      color: theme.colorScheme.primary,
                                    )
                                  : secondary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
