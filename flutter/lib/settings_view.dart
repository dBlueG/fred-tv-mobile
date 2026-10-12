import 'dart:convert';
import 'dart:io' show Platform;

import 'package:file_picker/file_picker.dart';

import 'package:flutter/material.dart';
import 'package:open_tv/extensions/int_extensions.dart';
import 'package:open_tv/native_bridge.dart';
import 'package:open_tv/bottom_nav.dart';
import 'package:open_tv/confirm_delete.dart';
import 'package:open_tv/donate_view.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/select_dialog.dart';
import 'package:open_tv/edit_dialog.dart';
import 'package:open_tv/home.dart';
import 'package:open_tv/locked_categories_view.dart';
import 'package:open_tv/parental.dart';
import 'package:open_tv/loading.dart';
import 'package:open_tv/models/home_manager.dart';
import 'package:open_tv/models/id_data.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/source_type.dart';
import 'package:open_tv/models/sort_type.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:open_tv/error.dart';
import 'package:open_tv/task_service.dart';
import 'package:open_tv/setup.dart';

class SettingsView extends StatefulWidget {
  final bool tvMode;
  const SettingsView({super.key, this.tvMode = false});

  @override
  State<SettingsView> createState() => _SettingsState();
}

class _SettingsState extends State<SettingsView> {
  Settings settings = Settings();
  List<Source> sources = [];
  bool loading = true;
  Future<Map<int, int>> expiriesFuture = NativeBridge.instance
      .getAllExpiries()
      .catchError((_) => <int, int>{});

  @override
  void initState() {
    super.initState();
    TaskService.instance.runningTask.addListener(reloadAfterTask);
    initAsync();
  }

  @override
  void dispose() {
    TaskService.instance.runningTask.removeListener(reloadAfterTask);
    super.dispose();
  }

  void reloadAfterTask() {
    if (!TaskService.instance.busy) reloadSources();
  }

  Future<void> initAsync() async {
    var results = await Future.wait([
      NativeBridge.instance.getSettings(),
      NativeBridge.instance.getSources(),
    ]);
    if (!mounted) return;
    setState(() {
      settings = results[0] as Settings;
      sources = results[1] as List<Source>;
      loading = false;
    });
  }

  void updateView(ViewType view) {
    if (view != ViewType.settings) {
      Navigator.pushAndRemoveUntil(
        context,
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => Home(
            tvMode: widget.tvMode,
            home: HomeManager(filters: Filters(viewType: view)),
          ),
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          transitionsBuilder: (context, animation, secondaryAnimation, child) =>
              child,
        ),
        (route) => false,
      );
    }
  }

  Future<void> showEditDialog(BuildContext context, final Source source) async {
    await showDialog(
      barrierDismissible: true,
      context: context,
      builder: (builder) => EditDialog(
        source: source,
        afterSave: reloadSources,
        parentContext: context,
      ),
    );
  }

  Future<void> _showDefaultViewDialog(BuildContext context) async {
    showDialog(
      barrierDismissible: true,
      context: context,
      builder: (BuildContext context) {
        return SelectDialog(
          title: "Default view",
          data: ViewType.values
              .take(4)
              .map((x) => IdData(id: x.index, data: viewTypeToString(x)))
              .toList(),
          action: (view) {
            setState(() {
              settings.defaultView = ViewType.values[view];
              updateSettings();
            });
            Navigator.of(context).pop();
          },
          previouslySelectedId: settings.defaultView.index,
        );
      },
    );
  }

  Future<void> _showDefaultSortDialog(BuildContext context) async {
    showDialog(
      barrierDismissible: true,
      context: context,
      builder: (BuildContext context) {
        return SelectDialog(
          title: "Default sort",
          data: SortType.values
              .map((x) => IdData(id: x.index, data: sortTypeToString(x)))
              .toList(),
          action: (sort) {
            setState(() {
              settings.defaultSort = SortType.values[sort];
              updateSettings();
            });
            Navigator.of(context).pop();
          },
          previouslySelectedId: settings.defaultSort.index,
        );
      },
    );
  }

  Future<void> _showSeekSecondsDialog(BuildContext context) async {
    showDialog(
      barrierDismissible: true,
      context: context,
      builder: (BuildContext context) {
        return SelectDialog(
          title: "Seek amount",
          data: Settings.seekSecondsOptions
              .map((x) => IdData(id: x, data: "$x seconds"))
              .toList(),
          action: (seconds) {
            setState(() {
              settings.seekSeconds = seconds;
              updateSettings();
            });
            Navigator.of(context).pop();
          },
          previouslySelectedId: settings.seekSeconds,
        );
      },
    );
  }

  Future<void> _showAutoplayCountdownDialog(BuildContext context) async {
    showDialog(
      barrierDismissible: true,
      context: context,
      builder: (BuildContext context) {
        return SelectDialog(
          title: "Countdown before the next episode",
          data: Settings.autoplayCountdownOptions
              .map((x) => IdData(id: x, data: "$x seconds"))
              .toList(),
          action: (seconds) {
            setState(() {
              settings.autoplayCountdownSeconds = seconds;
              updateSettings();
            });
            Navigator.of(context).pop();
          },
          previouslySelectedId: settings.autoplayCountdownSeconds,
        );
      },
    );
  }

  Future<void> exportBackup() async {
    await TaskService.instance.exportBackup((json) async {
      final date = DateTime.now().toIso8601String().substring(0, 10);
      final path = await FilePicker.platform.saveFile(
        dialogTitle: "Save backup",
        fileName: "fred-tv-backup-$date.json",
        bytes: utf8.encode(json),
      );
      return path != null;
    });
  }

  Future<void> restoreBackup() async {
    if (TaskService.instance.busy) {
      TaskService.instance.notifyBusy();
      return;
    }
    final result = await Error.tryAsyncNoLoading(() async {
      final picked = await FilePicker.platform.pickFiles(withData: true);
      final bytes = picked?.files.single.bytes;
      return bytes != null ? utf8.decode(bytes) : null;
    });
    final json = result.data;
    if (json == null || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Restore backup?"),
        content: const Text(
          "Settings will be replaced. Sources in the backup that aren't on "
          "this device are added and downloaded. Favorites, favorite lists, "
          "history and watch progress are merged with what's here.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text("Cancel"),
          ),
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text("Restore"),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await TaskService.instance.importBackup(json);
    if (!mounted) return;
    await initAsync();
  }

  Future<void> setPin() async {
    final pin = await ParentalControl.askNewPin(context);
    if (pin == null) return;
    setState(() => settings.parentalPin = pin);
    await updateSettings();
    ParentalControl.setPin(pin);
    if (mounted) setState(() {});
    Error.showMessage("PIN set. Choose what to lock below");
  }

  Future<void> changePin() async {
    if (!await ParentalControl.verify(context) || !mounted) return;
    await setPin();
  }

  Future<void> removePin() async {
    if (!await ParentalControl.verify(context)) return;
    setState(() => settings.parentalPin = null);
    await updateSettings();
    ParentalControl.setPin(null);
    if (mounted) setState(() {});
    Error.showMessage("PIN removed; locked content is visible again");
  }

  Future<void> openLockedCategories() async {
    if (!await ParentalControl.unlock(context) || !mounted) return;
    setState(() {});
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LockedCategoriesView()),
    );
  }

  Future<void> toggleLockedContent() async {
    if (ParentalControl.unlocked) {
      ParentalControl.lock();
      Error.showMessage("Locked content is hidden");
    } else if (!await ParentalControl.unlock(context)) {
      return;
    }
    if (mounted) setState(() {});
  }

  Future<void> toggleSourceLock(Source source) async {
    if (!await ParentalControl.unlock(context)) return;
    await Error.tryAsyncNoLoading(
      () => NativeBridge.instance.setSourceLocked(source.id!, !source.locked),
    );
    await reloadSources();
  }

  List<Widget> _parentalSettings() {
    if (!ParentalControl.hasPin) {
      return [
        const Divider(),
        _sectionTitle("Parental control"),
        ListTile(
          title: const Text("Set PIN"),
          subtitle: const Text("Hide chosen categories and sources behind a PIN"),
          leading: const Icon(Icons.lock_outline),
          onTap: setPin,
        ),
      ];
    }
    final unlocked = ParentalControl.unlocked;
    return [
      const Divider(),
      _sectionTitle("Parental control"),
      ListTile(
        title: Text(unlocked ? "Lock now" : "Show locked content"),
        subtitle: Text(
          unlocked
              ? "Locked content is visible until the app restarts"
              : "Locked categories and sources are hidden",
        ),
        leading: Icon(unlocked ? Icons.lock_open : Icons.lock),
        onTap: toggleLockedContent,
      ),
      ListTile(
        title: const Text("Locked categories"),
        leading: const Icon(Icons.category),
        onTap: openLockedCategories,
      ),
      const ListTile(
        title: Text("Locked sources"),
        subtitle: Text("Tap a source below and choose Lock"),
        leading: Icon(Icons.tv_off),
      ),
      ListTile(
        title: const Text("Change PIN"),
        leading: const Icon(Icons.password),
        onTap: changePin,
      ),
      ListTile(
        title: const Text("Remove PIN"),
        leading: const Icon(Icons.no_encryption_outlined),
        onTap: removePin,
      ),
    ];
  }

  List<Widget> _backupSettings() {
    return [
      const Divider(),
      _sectionTitle("Backup"),
      ListTile(
        title: const Text("Export backup"),
        subtitle: const Text(
          "Sources (including passwords), settings, favorites, history and "
          "watch progress",
        ),
        leading: const Icon(Icons.upload_file),
        onTap: exportBackup,
      ),
      ListTile(
        title: const Text("Restore backup"),
        leading: const Icon(Icons.restore),
        onTap: restoreBackup,
      ),
    ];
  }

  Widget _switchTile({
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool enabled = true,
  }) {
    return ListTile(
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle) : null,
      enabled: enabled,
      trailing: Switch(
        value: value,
        onChanged: enabled
            ? (bool value) {
                setState(() => onChanged(value));
                updateSettings();
              }
            : null,
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 10, top: 10, bottom: 10),
      child: Text(
        title,
        style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
      ),
    );
  }

  // Settings for the native Android player.
  List<Widget> _playerSettings() {
    if (!Platform.isAndroid) return [];
    final touch = !widget.tvMode;
    return [
      const Divider(),
      _sectionTitle("Player"),
      if (touch)
        _switchTile(
          title: "Volume and brightness gestures",
          subtitle: "Drag up or down on the right or left side",
          value: settings.volumeBrightnessGestures,
          onChanged: (v) => settings.volumeBrightnessGestures = v,
        ),
      if (touch)
        _switchTile(
          title: "Swipe to change channel",
          subtitle: "Swipe left or right on a livestream",
          value: settings.swipeToChangeChannel,
          onChanged: (v) => settings.swipeToChangeChannel = v,
        ),
      if (touch)
        _switchTile(
          title: "Double-tap to seek",
          subtitle: "Double-tap the left or right side of a movie or episode",
          value: settings.doubleTapSeek,
          onChanged: (v) => settings.doubleTapSeek = v,
        ),
      _switchTile(
        title: "Auto-play next episode",
        subtitle: "With a countdown when an episode ends",
        value: settings.autoplayNextEpisode,
        onChanged: (v) => settings.autoplayNextEpisode = v,
      ),
      ListTile(
        title: const Text("Next episode countdown"),
        subtitle: Text("${settings.autoplayCountdownSeconds} seconds"),
        enabled: settings.autoplayNextEpisode,
        onTap: () => _showAutoplayCountdownDialog(context),
      ),
      ListTile(
        title: const Text("Seek amount"),
        subtitle: Text("${settings.seekSeconds} seconds"),
        onTap: () => _showSeekSecondsDialog(context),
      ),
      if (touch)
        _switchTile(
          title: "Picture-in-picture",
          subtitle: "Keep watching in a small window when leaving the app",
          value: settings.pictureInPicture,
          onChanged: (v) => settings.pictureInPicture = v,
        ),
      if (touch)
        _switchTile(
          title: "Keep playing after closing picture-in-picture",
          subtitle: "Audio continues with controls in the notification",
          value: settings.keepAudioAfterPip,
          enabled: settings.pictureInPicture,
          onChanged: (v) => settings.keepAudioAfterPip = v,
        ),
    ];
  }

  Future<void> toggleSource(Source source) async {
    await Error.tryAsyncNoLoading(
      () => NativeBridge.instance.setSourceEnabled(source.id!, !source.enabled),
    );
    await reloadSources();
    if (!mounted) return;
    Error.showSnackBar(
      SnackBar(
        persist: false,
        content: Text("Source ${!source.enabled ? "enabled" : "disabled"}"),
        duration: const Duration(milliseconds: 500),
      ),
    );
  }

  Widget getSource(Source source, bool busy) {
    final subtitleStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Opacity(
      opacity: busy ? 0.4 : 1,
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        elevation: 5,
        child: ListTile(
          leading: Icon(
            source.locked && ParentalControl.hasPin
                ? Icons.lock
                : source.enabled
                ? Icons.tv
                : Icons.tv_off,
          ),
          horizontalTitleGap: 25,
          contentPadding: const EdgeInsets.symmetric(horizontal: 20),
          title: Text(source.name),
          subtitle: Text(source.sourceType.label),
          onTap: () => busy
              ? TaskService.instance.notifyBusy()
              : showSourceActions(source),
          trailing: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (source.lastUpdated != null)
                Text(
                  "Last updated: ${source.lastUpdated!.toTimeAgo()}",
                  style: subtitleStyle,
                ),
              if (source.sourceType == SourceType.xtream)
                FutureBuilder<Map<int, int>>(
                  future: expiriesFuture,
                  builder: (context, snapshot) {
                    if (snapshot.hasData &&
                        snapshot.data!.containsKey(source.id)) {
                      return Text(
                        "Expires: ${snapshot.data![source.id]!.toTimeUntil()}",
                        style: subtitleStyle,
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> refreshSource(Source source) =>
      TaskService.instance.refreshSource(source);

  Future<void> showSourceActions(Source source) async {
    final actions = <IdData<String>>[
      IdData(
        id: 0,
        data: source.enabled ? "Disable" : "Enable",
        icon: source.enabled ? Icons.tv_off : Icons.tv,
      ),
      if (source.sourceType != SourceType.m3u)
        IdData(id: 1, data: "Refresh", icon: Icons.refresh),
      if (!widget.tvMode) IdData(id: 2, data: "Edit", icon: Icons.edit),
      IdData(id: 3, data: "Delete", icon: Icons.delete),
      if (ParentalControl.hasPin)
        IdData(
          id: 4,
          data: source.locked ? "Unlock" : "Lock",
          icon: source.locked ? Icons.lock_open : Icons.lock,
        ),
    ];
    final name = source.name.length > 20
        ? "${source.name.substring(0, 20)}…"
        : source.name;
    await showDialog(
      barrierDismissible: true,
      context: context,
      builder: (context) => SelectDialog(
        title: "Select action for $name",
        data: actions,
        action: (id) {
          Navigator.of(context).pop();
          switch (id) {
            case 0:
              toggleSource(source);
            case 1:
              refreshSource(source);
            case 2:
              showEditDialog(context, source);
            case 3:
              showConfirmDeleteDialog(source);
            case 4:
              toggleSourceLock(source);
          }
        },
      ),
    );
  }

  Future<void> showConfirmDeleteDialog(Source source) async {
    await showDialog(
      barrierDismissible: true,
      context: context,
      builder: (builder) => ConfirmDelete(
        type: "source",
        name: source.name,
        confirm: () async {
          await TaskService.instance.deleteSource(source.id!);
          await reloadSources();
          if (!mounted) return;
          if (sources.isEmpty) {
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(
                builder: (context) => Setup(tvMode: widget.tvMode),
              ),
              (route) => false,
            );
          }
        },
      ),
    );
  }

  Future<void> reloadSources() async {
    await Error.tryAsyncNoLoading(
      () async => sources = await NativeBridge.instance.getSources(),
    );
    if (!mounted) return;
    setState(() {
      sources;
    });
  }

  Future<void> updateSettings() async {
    await Error.tryAsyncNoLoading(
      () => NativeBridge.instance.updateSettings(settings),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: TaskService.instance.runningTask,
      builder: (context, task, _) {
        final busy = task != null;
        return PopScope(
          canPop: !TaskService.instance.isDeletingSource,
          child: Scaffold(
            body: Visibility(
              visible: !loading,
              child: Loading(
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsetsDirectional.symmetric(
                      vertical: 10,
                    ),
                    child: ListView(
                      children: [
                        const SizedBox(height: 10),
                        const Padding(
                          padding: EdgeInsets.only(left: 10),
                          child: Text(
                            'Settings',
                            style: TextStyle(
                              fontSize: 30,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        ListTile(
                          title: const Text("Donate"),
                          subtitle: const Text(
                            "Fred TV needs your help! Consider donating ❤️",
                          ),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) =>
                                  DonateView(tvMode: widget.tvMode),
                            ),
                          ),
                        ),
                        if (!widget.tvMode)
                          ListTile(
                            title: const Text("Default view"),
                            subtitle: Text(
                              viewTypeToString(settings.defaultView),
                            ),
                            onTap: () => _showDefaultViewDialog(context),
                          ),
                        ListTile(
                          title: const Text("Default sort"),
                          subtitle: Text(
                            sortTypeToString(settings.defaultSort),
                          ),
                          onTap: () => _showDefaultSortDialog(context),
                        ),
                        ListTile(
                          title: const Text("Force TV Mode"),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Switch(
                                value: settings.forceTVMode,
                                onChanged: (bool value) {
                                  setState(() {
                                    settings.forceTVMode = value;
                                  });
                                  updateSettings();
                                },
                              ),
                            ],
                          ),
                        ),
                        if (!widget.tvMode)
                          ListTile(
                            title: const Text("Low latency livestreams"),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Switch(
                                  value: settings.lowLatency,
                                  onChanged: (bool value) {
                                    setState(() {
                                      settings.lowLatency = value;
                                    });
                                    updateSettings();
                                  },
                                ),
                              ],
                            ),
                          ),
                        ListTile(
                          title: const Text("Refresh sources on start"),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Switch(
                                value: settings.refreshOnStart,
                                onChanged: (bool value) {
                                  setState(() {
                                    settings.refreshOnStart = value;
                                  });
                                  updateSettings();
                                },
                              ),
                            ],
                          ),
                        ),
                        _switchTile(
                          title: "Show programme info",
                          subtitle: "Now and next on Xtream livestreams",
                          value: settings.showEpg,
                          onChanged: (v) => settings.showEpg = v,
                        ),
                        _switchTile(
                          title: "Show Continue Watching",
                          subtitle: "Unfinished movies and episodes on the home screen",
                          value: settings.showContinueWatching,
                          onChanged: (v) => settings.showContinueWatching = v,
                        ),
                        if (!widget.tvMode)
                          ListTile(
                            title: const Text("Show livestreams"),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Switch(
                                  value: settings.showLivestreams,
                                  onChanged: (bool value) {
                                    setState(() {
                                      settings.showLivestreams = value;
                                    });
                                    updateSettings();
                                  },
                                ),
                              ],
                            ),
                          ),
                        if (!widget.tvMode)
                          ListTile(
                            title: const Text("Show movies"),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Switch(
                                  value: settings.showMovies,
                                  onChanged: (bool value) {
                                    setState(() {
                                      settings.showMovies = value;
                                    });
                                    updateSettings();
                                  },
                                ),
                              ],
                            ),
                          ),
                        if (!widget.tvMode)
                          ListTile(
                            title: const Text("Show series"),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Switch(
                                  value: settings.showSeries,
                                  onChanged: (bool value) {
                                    setState(() {
                                      settings.showSeries = value;
                                    });
                                    updateSettings();
                                  },
                                ),
                              ],
                            ),
                          ),
                        ..._playerSettings(),
                        ..._parentalSettings(),
                        ..._backupSettings(),
                        const Divider(),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(left: 10),
                              child: Text(
                                'Sources',
                                style: TextStyle(
                                  fontSize: 30,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            Row(
                              children: [
                                IconButton(
                                  color: busy
                                      ? Theme.of(context).disabledColor
                                      : null,
                                  onPressed: () => busy
                                      ? TaskService.instance.notifyBusy()
                                      : TaskService.instance.refreshAll(),
                                  icon: const Icon(Icons.refresh),
                                ),
                                IconButton(
                                  color: busy
                                      ? Theme.of(context).disabledColor
                                      : null,
                                  onPressed: () => busy
                                      ? TaskService.instance.notifyBusy()
                                      : Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (context) => Setup(
                                              showAppBar: true,
                                              tvMode: widget.tvMode,
                                            ),
                                          ),
                                        ),
                                  icon: const Icon(Icons.add),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        ...sources.map((x) => getSource(x, busy)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            bottomNavigationBar: !widget.tvMode
                ? BottomNav(
                    updateViewMode: updateView,
                    startingView: ViewType.settings,
                    tvMode: widget.tvMode,
                  )
                : null,
          ),
        );
      },
    );
  }
}
