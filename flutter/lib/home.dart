import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_tv/native_bridge.dart';
import 'package:open_tv/bottom_nav.dart';
import 'package:open_tv/channel_tile.dart';
import 'package:open_tv/continue_watching_row.dart';
import 'package:open_tv/favorite_list_bar.dart';
import 'package:open_tv/loading.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/channel_playlist.dart';
import 'package:open_tv/models/epg.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/home_manager.dart';
import 'package:open_tv/models/id_data.dart';
import 'package:open_tv/models/no_push_animation_material_page_route.dart';
import 'package:open_tv/models/node.dart';
import 'package:open_tv/models/node_type.dart';
import 'package:open_tv/models/sort_type.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:open_tv/programme_results.dart';
import 'package:open_tv/remote/play_on_tv.dart';
import 'package:open_tv/select_dialog.dart';
import 'package:open_tv/error.dart';
import 'package:open_tv/utils.dart';

class Home extends StatefulWidget {
  final HomeManager home;
  final bool firstLaunch;
  final bool tvMode;
  const Home({
    super.key,
    required this.home,
    this.firstLaunch = false,
    this.tvMode = false,
  });
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  Timer? _debounce;
  bool reachedMax = false;
  final int pageSize = 36;
  List<Channel> channels = [];
  // Favorite categories, shown above the channels in the Favorites view.
  List<Channel> favoriteGroups = [];
  TextEditingController searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final FocusNode _keywordsFocusNode = FocusNode(skipTraversal: true);
  final FocusNode _sortFocusNode = FocusNode(skipTraversal: true);
  final ScrollController _scrollController = ScrollController();
  int currentlyFocusedChannel = 0;
  bool isLoading = false;
  int? previousScroll;
  bool scrolledDeepEnough = false;
  bool showEpg = false;
  bool searchProgrammes = false;
  // Guide programmes matching the search, shown above the channels.
  List<ProgramMatch> programmes = [];
  // Now/next by channel id, for the loaded livestreams.
  final Map<int, EpgNowNext> epg = {};
  Timer? _epgTimer;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_scrollListener);
    _searchFocusNode.onKey = _handleSearchRawKey;
    _keywordsFocusNode.onKeyEvent = _handleKeywordsKeyEvent;
    _sortFocusNode.onKeyEvent = _handleSortKeyEvent;
    initializeAsync();
  }

  Future<void> initializeAsync() async {
    final startSettings = await NativeBridge.instance.getSettings();
    showEpg = startSettings.showEpg;
    searchProgrammes = startSettings.searchProgrammes;
    if (showEpg) {
      // Keeps progress bars moving and refetches programmes that have ended.
      _epgTimer = Timer.periodic(const Duration(minutes: 1), (_) {
        if (!mounted) return;
        setState(() {});
        _loadEpg(stale: true);
      });
    }
    if (widget.home.filters.sourceIds == null) {
      final sources = await NativeBridge.instance.getEnabledSourcesMinimal();
      widget.home.filters.sourceIds = sources;
    }
    if (widget.home.filters.mediaTypes == null ||
        widget.home.filters.sort == null) {
      final settings = await NativeBridge.instance.getSettings();
      widget.home.filters.mediaTypes ??= settings.getMediaTypes();
      widget.home.filters.sort ??= settings.defaultSort;
    }

    await load();
    if (!mounted) return;
    if (widget.firstLaunch) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Utils.maybeShowWhatsNew(context);
      });
    }
  }

  void showSortDialog() {
    showDialog(
      barrierDismissible: true,
      context: context,
      builder: (context) => SelectDialog(
        title: "Sort by",
        data: SortType.values
            .map((x) => IdData(id: x.index, data: sortTypeToString(x)))
            .toList(),
        action: (sort) {
          setState(() {
            widget.home.filters.sort = SortType.values[sort];
          });
          Navigator.of(context).pop();
          load(false);
        },
        previouslySelectedId: widget.home.filters.sort?.index,
      ),
    );
  }

  void scrollToTop() {
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeInOut,
    );
  }

  Future<void> load([bool more = false]) async {
    if (more) {
      widget.home.filters.page++;
    } else {
      widget.home.filters.page = 1;
    }
    await Error.tryAsyncNoLoading(() async {
      List<Channel> channels = await NativeBridge.instance.getChannels(
        widget.home.filters,
      );
      final favoriteGroups = !more && _showFavoriteGroups
          ? await NativeBridge.instance.getFavoriteGroups(widget.home.filters)
          : null;
      final programmes = !more && _searchesProgrammes
          ? await NativeBridge.instance.searchPrograms(widget.home.filters)
          : null;
      if (!mounted) return;
      if (!more) {
        setState(() {
          this.channels = channels;
          this.favoriteGroups = favoriteGroups ?? [];
          this.programmes = programmes ?? [];
        });
      } else {
        setState(() {
          this.channels.addAll(channels);
        });
      }
      reachedMax = channels.length < pageSize;
    });
    _loadEpg();
  }

  // Fetches now/next for loaded livestreams without one (or, with `stale`,
  // whose current programme has ended). Non-Xtream channels return nothing.
  Future<void> _loadEpg({bool stale = false}) async {
    if (!showEpg) return;
    final time = DateTime.now();
    final ids = channels
        .where((c) => c.mediaType == MediaType.livestream && c.id != null)
        .where((c) {
          final e = epg[c.id];
          if (e == null) return !stale;
          if (!stale) return false;
          return e.now != null
              ? !e.now!.isOnAt(time)
              : e.next?.startTime.isBefore(time) == true;
        })
        .map((c) => c.id!)
        .toList();
    if (ids.isEmpty) return;
    final result = await Error.tryAsyncNoLoading(
      () => NativeBridge.instance.getEpgNowNext(ids),
    );
    if (!mounted || result.data == null) return;
    setState(() {
      for (final id in ids) {
        // Remember channels without a guide so they aren't asked again.
        epg[id] = result.data![id] ?? EpgNowNext(channelId: id);
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _debounce?.cancel();
    _epgTimer?.cancel();
    _searchFocusNode.dispose();
    _keywordsFocusNode.dispose();
    _sortFocusNode.dispose();
    super.dispose();
  }

  void _scrollListener() async {
    final bool shouldShow = _scrollController.offset > 200;

    if (scrolledDeepEnough != shouldShow) {
      setState(() => scrolledDeepEnough = shouldShow);
    }

    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent * 0.75 &&
        !isLoading &&
        !reachedMax) {
      setState(() {
        isLoading = true;
      });
      await load(true);
      setState(() {
        isLoading = false;
      });
    }
  }

  void clearSearch() {
    widget.home.filters.query = null;
    searchController.clear();
  }

  bool _focusChannelsBelow() {
    return FocusScope.of(context).focusInDirection(TraversalDirection.down);
  }

  static const int _androidFlagSoftKeyboard = 0x2;

  bool _isFromSoftKeyboard(RawKeyEvent event) {
    final data = event.data;
    return data is RawKeyEventDataAndroid &&
        (data.flags & _androidFlagSoftKeyboard) != 0;
  }

  KeyEventResult _handleSearchRawKey(FocusNode node, RawKeyEvent event) {
    if (_isFromSoftKeyboard(event)) {
      return KeyEventResult.ignored;
    }
    if (event is RawKeyDownEvent) {
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.escape ||
          key == LogicalKeyboardKey.goBack) {
        bool moved = FocusScope.of(
          context,
        ).focusInDirection(TraversalDirection.down);
        if (!moved) {
          node.unfocus();
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        bool moved = FocusScope.of(
          context,
        ).focusInDirection(TraversalDirection.down);
        if (moved) {
          return KeyEventResult.handled;
        }
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        _keywordsFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleKeywordsKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.arrowLeft) {
        _searchFocusNode.requestFocus();
        searchController.selection = TextSelection.fromPosition(
          TextPosition(offset: searchController.text.length),
        );
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        _sortFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        bool moved = FocusScope.of(
          context,
        ).focusInDirection(TraversalDirection.down);
        if (moved) {
          return KeyEventResult.handled;
        }
      }
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleSortKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.arrowLeft) {
        _keywordsFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        bool moved = FocusScope.of(
          context,
        ).focusInDirection(TraversalDirection.down);
        if (moved) {
          return KeyEventResult.handled;
        }
      }
    }
    return KeyEventResult.ignored;
  }

  bool get _showContinueWatching =>
      widget.home.filters.viewType == ViewType.all &&
      widget.home.node == null &&
      (widget.home.filters.query ?? "").isEmpty;

  bool get _isFavoritesView =>
      widget.home.filters.viewType == ViewType.favorites &&
      widget.home.node == null;

  // Programmes are searched from All, Favorites and inside a category, when
  // livestreams are shown.
  bool get _searchesProgrammes =>
      searchProgrammes &&
      (widget.home.filters.query ?? "").trim().length >= 2 &&
      widget.home.filters.viewType != ViewType.history &&
      widget.home.filters.seriesId == null &&
      (widget.home.filters.viewType != ViewType.categories ||
          widget.home.filters.groupId != null) &&
      widget.home.filters.mediaTypes?.contains(MediaType.livestream) != false;

  // Favorite lists only hold channels, so categories show under "All".
  bool get _showFavoriteGroups =>
      _isFavoritesView && widget.home.filters.favoriteListId == null;

  Widget _sectionTitle(String title) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Text(title, style: Theme.of(context).textTheme.titleSmall),
    ),
  );

  Widget _tileGrid(
    List<Channel> items,
    int crossAxisCount,
    Widget Function(BuildContext context, int index) builder,
  ) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(10, 5, 10, 10),
      sliver: SliverGrid(
        delegate: SliverChildBuilderDelegate(builder, childCount: items.length),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          mainAxisExtent: 100,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
        ),
      ),
    );
  }

  ViewType getStartingView() {
    if (widget.home.filters.groupId != null) {
      return ViewType.categories;
    }
    return widget.home.filters.viewType;
  }

  void updateViewMode(ViewType type) {
    Navigator.of(context).pushAndRemoveUntil(
      NoPushAnimationMaterialPageRoute(
        builder: (context) => Home(
          tvMode: widget.tvMode,
          home: HomeManager(
            filters: Filters(
              viewType: type,
              mediaTypes: widget.home.filters.mediaTypes,
              sourceIds: widget.home.filters.sourceIds,
              sort: widget.home.filters.sort,
            ),
          ),
        ),
      ),
      (route) => false,
    );
  }

  void setNode(Node node) {
    final home = HomeManager(
      node: node,
      filters: Filters(
        viewType: ViewType.all,
        mediaTypes: widget.home.filters.mediaTypes,
        sourceIds: widget.home.filters.sourceIds,
        sort: widget.home.filters.sort,
      ),
    );
    if (widget.home.filters.groupId != null) {
      home.filters.groupId = widget.home.filters.groupId;
    } else if (node.type == NodeType.category) {
      home.filters.groupId = node.id;
    }
    if (node.type == NodeType.series) home.filters.seriesId = node.id;
    if (node.type == NodeType.season) {
      home.filters.seriesId = widget.home.filters.seriesId;
      home.filters.seasonId = node.id;
    }
    Navigator.of(context).push(
      NoPushAnimationMaterialPageRoute(
        builder: (context) => Home(home: home, tvMode: widget.tvMode),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.home.node != null
          ? AppBar(
              title: Text(widget.home.node.toString()),
              automaticallyImplyLeading: !widget.tvMode,
              leading: !widget.tvMode
                  ? IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.of(context).pop(),
                    )
                  : null,
            )
          : null,
      body: Loading(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final double width = constraints.maxWidth;
              final int crossAxisCount = (width / 350).floor().clamp(1, 3);
              return CustomScrollView(
                controller: _scrollController,
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              focusNode: _searchFocusNode,
                              style: TextStyle(
                                fontSize: Theme.of(
                                  context,
                                ).textTheme.titleMedium?.fontSize!,
                              ),
                              controller: searchController,
                              textInputAction: TextInputAction.search,
                              onEditingComplete: _focusChannelsBelow,
                              onChanged: (query) {
                                _debounce?.cancel();
                                _debounce = Timer(
                                  const Duration(milliseconds: 500),
                                  () {
                                    widget.home.filters.query = query;
                                    load(false);
                                  },
                                );
                              },
                              decoration: InputDecoration(
                                hintText: "Search...",
                                hintStyle: TextStyle(
                                  fontSize: Theme.of(
                                    context,
                                  ).textTheme.titleMedium?.fontSize!,
                                ),
                                prefixIcon: const Icon(Icons.search),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: BorderSide.none,
                                ),
                                suffixIcon: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      focusNode: _keywordsFocusNode,
                                      onPressed: () {
                                        widget.home.filters.useKeywords =
                                            !widget.home.filters.useKeywords;
                                        load(false);
                                      },
                                      icon: Icon(
                                        widget.home.filters.useKeywords
                                            ? Icons.label
                                            : Icons.label_outline,
                                      ),
                                    ),
                                    IconButton(
                                      focusNode: _sortFocusNode,
                                      onPressed: showSortDialog,
                                      icon:
                                          widget.home.filters.sort == null ||
                                              widget.home.filters.sort ==
                                                  SortType.provider
                                          ? const Icon(Icons.sort)
                                          : widget.home.filters.sort ==
                                                SortType.alphabeticalAsc
                                          ? const Icon(Icons.arrow_upward)
                                          : const Icon(Icons.arrow_downward),
                                    ),
                                  ],
                                ),
                                filled: true,
                              ),
                            ),
                          ),
                          if (!widget.tvMode && Platform.isAndroid)
                            const PlayOnTvButton(),
                        ],
                      ),
                    ),
                  ),
                  if (_showContinueWatching)
                    const SliverToBoxAdapter(child: ContinueWatchingRow()),
                  if (_isFavoritesView)
                    SliverToBoxAdapter(
                      child: FavoriteListBar(
                        selectedId: widget.home.filters.favoriteListId,
                        onSelected: (listId) {
                          setState(() {
                            widget.home.filters.favoriteListId = listId;
                          });
                          load(false);
                        },
                      ),
                    ),
                  if (programmes.isNotEmpty)
                    SliverToBoxAdapter(
                      child: ProgrammeResults(matches: programmes),
                    ),
                  if (favoriteGroups.isNotEmpty) ...[
                    _sectionTitle("Categories"),
                    _tileGrid(favoriteGroups, crossAxisCount, (context, index) {
                      return ChannelTile(
                        channel: favoriteGroups[index],
                        parentContext: context,
                        setNode: setNode,
                        onSelect: () {},
                        onFavoriteChanged: () => load(false),
                      );
                    }),
                    if (channels.isNotEmpty) _sectionTitle("Channels"),
                  ],
                  _tileGrid(channels, crossAxisCount, (context, index) {
                    final channel = channels[index];
                    return ChannelTile(
                      channel: channel,
                      parentContext: context,
                      setNode: setNode,
                      autofocus: index == currentlyFocusedChannel,
                      onSelect: () => currentlyFocusedChannel = index,
                      onFavoriteChanged: _isFavoritesView
                          ? () => load(false)
                          : null,
                      epg: epg[channel.id],
                      playlist: () => ChannelPlaylist.create(
                        filters: widget.home.filters,
                        channels: channels,
                        current: channel,
                        reachedEnd: reachedMax,
                      ),
                    );
                  }),
                ],
              );
            },
          ),
        ),
      ),
      bottomNavigationBar: !widget.tvMode
          ? BottomNav(
              startingView: getStartingView(),
              updateViewMode: updateViewMode,
              tvMode: widget.tvMode,
            )
          : null,
      floatingActionButton: !widget.tvMode
          ? IgnorePointer(
              ignoring: !scrolledDeepEnough,
              child: AnimatedOpacity(
                opacity: scrolledDeepEnough ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                child: FloatingActionButton(
                  onPressed: scrollToTop,
                  shape: const CircleBorder(),
                  tooltip: 'Scroll to Top',
                  child: const Icon(Icons.arrow_upward),
                ),
              ),
            )
          : null,
    );
  }
}
