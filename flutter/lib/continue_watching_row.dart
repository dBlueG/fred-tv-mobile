import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:open_tv/error.dart';
import 'package:open_tv/models/continue_watching_item.dart';
import 'package:open_tv/native_bridge.dart';
import 'package:open_tv/playback.dart';
import 'package:open_tv/select_dialog.dart';
import 'package:open_tv/models/id_data.dart';
import 'package:open_tv/task_service.dart';

// Unfinished movies and episodes, newest first. Hidden when empty or turned
// off in Settings.
class ContinueWatchingRow extends StatefulWidget {
  const ContinueWatchingRow({super.key});

  @override
  State<ContinueWatchingRow> createState() => _ContinueWatchingRowState();
}

class _ContinueWatchingRowState extends State<ContinueWatchingRow> {
  List<ContinueWatchingItem> items = [];

  @override
  void initState() {
    super.initState();
    TaskService.instance.watchProgressVersion.addListener(load);
    TaskService.instance.runningTask.addListener(_reloadAfterTask);
    load();
  }

  @override
  void dispose() {
    TaskService.instance.watchProgressVersion.removeListener(load);
    TaskService.instance.runningTask.removeListener(_reloadAfterTask);
    super.dispose();
  }

  void _reloadAfterTask() {
    if (!TaskService.instance.busy) load();
  }

  Future<void> load() async {
    final result = await Error.tryAsyncNoLoading(() async {
      final settings = await NativeBridge.instance.getSettings();
      if (!settings.showContinueWatching) return <ContinueWatchingItem>[];
      return NativeBridge.instance.getContinueWatching();
    });
    if (!mounted || result.data == null) return;
    setState(() => items = result.data!);
  }

  Future<void> showActions(ContinueWatchingItem item) async {
    await showDialog(
      context: context,
      builder: (context) => SelectDialog(
        title: item.channel.name,
        data: [
          IdData(id: 0, data: "Play", icon: Icons.play_arrow),
          IdData(
            id: 1,
            data: "Remove from Continue Watching",
            icon: Icons.remove_circle_outline,
          ),
        ],
        action: (id) {
          Navigator.of(context).pop();
          if (id == 0) {
            openPlayer(this.context, item.channel);
          } else {
            TaskService.instance.removeMoviePosition(item.channel.id!);
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text("Continue watching", style: theme.textTheme.titleMedium),
        ),
        SizedBox(
          height: 150,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, index) => _ContinueWatchingCard(
              item: items[index],
              onTap: () => openPlayer(context, items[index].channel),
              onLongPress: () => showActions(items[index]),
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _ContinueWatchingCard extends StatelessWidget {
  final ContinueWatchingItem item;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ContinueWatchingCard({
    required this.item,
    required this.onTap,
    required this.onLongPress,
  });

  String _remaining() {
    final duration = item.duration;
    if (duration == null) return "";
    final minutes = ((duration - item.position) / 60).ceil();
    return minutes >= 60
        ? "${minutes ~/ 60} h ${minutes % 60} min left"
        : "$minutes min left";
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = [
      if (item.seriesName != null) item.seriesName!,
      _remaining(),
    ].where((s) => s.isNotEmpty).join(" · ");
    return SizedBox(
      width: 220,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        color: theme.colorScheme.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Container(
                  color: Colors.black26,
                  padding: const EdgeInsets.all(6),
                  child: item.channel.image != null
                      ? CachedNetworkImage(
                          imageUrl: item.channel.image!,
                          memCacheHeight: 300,
                          fit: BoxFit.contain,
                          errorWidget: (_, _, _) =>
                              const Icon(Icons.movie, size: 40, color: Colors.grey),
                        )
                      : const Icon(Icons.movie, size: 40, color: Colors.grey),
                ),
              ),
              if (item.progress != null)
                LinearProgressIndicator(value: item.progress, minHeight: 3),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.channel.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
