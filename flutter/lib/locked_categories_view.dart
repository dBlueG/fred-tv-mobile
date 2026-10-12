import 'dart:async';

import 'package:flutter/material.dart';
import 'package:open_tv/error.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/sort_type.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:open_tv/native_bridge.dart';

// Lets the user choose which categories the parental PIN hides. Only opened
// while unlocked, so locked categories are listed too.
class LockedCategoriesView extends StatefulWidget {
  const LockedCategoriesView({super.key});

  @override
  State<LockedCategoriesView> createState() => _LockedCategoriesViewState();
}

class _LockedCategoriesViewState extends State<LockedCategoriesView> {
  static const _pageSize = 36;

  final _scrollController = ScrollController();
  final List<Channel> categories = [];
  Map<int, String> sourceNames = {};
  Filters? filters;
  bool reachedEnd = false;
  bool loading = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      if (_scrollController.position.pixels >=
          _scrollController.position.maxScrollExtent * 0.75) {
        load(more: true);
      }
    });
    init();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> init() async {
    final sources = await NativeBridge.instance.getSources();
    sourceNames = {for (final s in sources) s.id!: s.name};
    filters = Filters(
      viewType: ViewType.categories,
      sourceIds: sources.map((s) => s.id!).toList(),
      mediaTypes: [MediaType.livestream, MediaType.movie, MediaType.serie],
      sort: SortType.alphabeticalAsc,
    );
    await load();
  }

  Future<void> load({bool more = false}) async {
    final filters = this.filters;
    if (filters == null || loading || (more && reachedEnd)) return;
    loading = true;
    filters.page = more ? filters.page + 1 : 1;
    final result = await Error.tryAsyncNoLoading(
      () => NativeBridge.instance.getChannels(filters),
    );
    loading = false;
    if (!mounted || result.data == null) return;
    setState(() {
      if (!more) categories.clear();
      categories.addAll(result.data!);
      reachedEnd = result.data!.length < _pageSize;
    });
  }

  Future<void> toggle(Channel category, bool locked) async {
    final result = await Error.tryAsyncNoLoading(
      () => NativeBridge.instance.setGroupLocked(category.id!, locked),
    );
    if (result.success && mounted) setState(() => category.locked = locked);
  }

  @override
  Widget build(BuildContext context) {
    final showSource = sourceNames.length > 1;
    return Scaffold(
      appBar: AppBar(title: const Text("Locked categories")),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                decoration: InputDecoration(
                  hintText: "Search categories...",
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (query) {
                  _debounce?.cancel();
                  _debounce = Timer(const Duration(milliseconds: 400), () {
                    filters?.query = query;
                    load();
                  });
                },
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                "Locked categories are hidden everywhere until the PIN is "
                "entered.",
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                itemCount: categories.length,
                itemBuilder: (context, index) {
                  final category = categories[index];
                  return SwitchListTile(
                    title: Text(category.name),
                    subtitle: showSource
                        ? Text(sourceNames[category.sourceId] ?? "")
                        : null,
                    secondary: Icon(
                      category.locked ? Icons.lock : Icons.lock_open,
                    ),
                    value: category.locked,
                    onChanged: (locked) => toggle(category, locked),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
