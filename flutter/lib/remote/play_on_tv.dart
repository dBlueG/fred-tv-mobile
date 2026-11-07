import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/material.dart';
import 'package:open_tv/models/device_detector.dart';
import 'package:open_tv/remote/protocol.dart';
import 'package:open_tv/remote/remote_client.dart';
import 'package:open_tv/remote/remote_store.dart';

// Opens the list of TVs. Lights up while connected to one.
class PlayOnTvButton extends StatelessWidget {
  const PlayOnTvButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<RemoteConnection>(
      valueListenable: RemoteClient.instance.connection,
      builder: (context, connection, _) {
        final connected = connection == RemoteConnection.connected;
        return IconButton(
          tooltip: "Play on TV",
          color: connected ? Theme.of(context).colorScheme.primary : null,
          icon: Icon(connected ? Icons.cast_connected : Icons.cast),
          onPressed: () => showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            builder: (_) => const _PlayOnTvSheet(),
          ),
        );
      },
    );
  }
}

class _Tv {
  final String? id;
  final String name;
  final String host;
  final int port;
  final bool saved;
  final bool discovered;
  const _Tv({
    this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.saved,
    required this.discovered,
  });
}

class _PlayOnTvSheet extends StatefulWidget {
  const _PlayOnTvSheet();

  @override
  State<_PlayOnTvSheet> createState() => _PlayOnTvSheetState();
}

class _PlayOnTvSheetState extends State<_PlayOnTvSheet> {
  final client = RemoteClient.instance;
  // By service name, which is all a "lost" event is sure to carry.
  final Map<String, BonsoirService> found = {};
  BonsoirDiscovery? discovery;
  StreamSubscription? discoverySubscription;
  RemoteStore? store;
  bool connecting = false;
  String? error;

  @override
  void initState() {
    super.initState();
    RemoteStore.shared().then((value) {
      if (mounted) setState(() => store = value);
    });
    _discover();
  }

  Future<void> _discover() async {
    try {
      final discovery = BonsoirDiscovery(type: remoteServiceType);
      await discovery.initialize();
      if (!mounted) {
        await discovery.stop();
        return;
      }
      this.discovery = discovery;
      discoverySubscription = discovery.eventStream!.listen((event) {
        switch (event) {
          case BonsoirDiscoveryServiceFoundEvent():
            event.service.resolve(discovery.serviceResolver);
          case BonsoirDiscoveryServiceResolvedEvent():
          case BonsoirDiscoveryServiceUpdatedEvent():
            final service = event.service;
            if (service != null && mounted) {
              setState(() => found[service.name] = service);
            }
          case BonsoirDiscoveryServiceLostEvent():
            if (mounted) setState(() => found.remove(event.service.name));
          default:
        }
      });
      await discovery.start();
    } catch (e) {
      // The address can still be entered by hand.
      debugPrint("Couldn't search for TVs: $e");
    }
  }

  @override
  void dispose() {
    discoverySubscription?.cancel();
    discovery?.stop().catchError((_) {});
    super.dispose();
  }

  String? _addressOf(BonsoirService service) {
    final addresses = service.hostAddresses;
    if (addresses.isEmpty) return null;
    return addresses.firstWhere(
      (a) => !a.contains(":"),
      orElse: () => addresses.first,
    );
  }

  // Saved TVs first; the address found on the network wins over the saved one.
  List<_Tv> _tvs() {
    final discovered = <String, BonsoirService>{};
    final unknownIds = <BonsoirService>[];
    for (final service in found.values) {
      final id = service.attributes[remoteServiceIdAttribute];
      if (_addressOf(service) == null) continue;
      if (id != null) {
        discovered[id] = service;
      } else {
        unknownIds.add(service);
      }
    }
    final tvs = <_Tv>[];
    for (final saved in store?.tvs ?? <SavedTv>[]) {
      final service = discovered.remove(saved.id);
      tvs.add(
        _Tv(
          id: saved.id,
          name: saved.name,
          host: service != null ? _addressOf(service)! : saved.host,
          port: service?.port ?? saved.port,
          saved: true,
          discovered: service != null,
        ),
      );
    }
    for (final entry in [...discovered.values, ...unknownIds]) {
      tvs.add(
        _Tv(
          id: entry.attributes[remoteServiceIdAttribute],
          name: entry.name,
          host: _addressOf(entry)!,
          port: entry.port,
          saved: false,
          discovered: true,
        ),
      );
    }
    return tvs;
  }

  Future<void> _connect(String host, int port) async {
    final store = this.store;
    if (store == null || connecting) return;
    setState(() {
      connecting = true;
      error = null;
    });
    try {
      final connected = await client.connect(
        store: store,
        host: host,
        port: port,
        phoneName: await DeviceDetector.model(),
        askCode: _askCode,
      );
      if (connected && mounted) Navigator.of(context).pop();
    } on RemoteConnectException catch (e) {
      if (mounted) setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => connecting = false);
    }
  }

  Future<String?> _askCode(String tvName, bool wrongCode) {
    return showDialog<String>(
      context: context,
      builder: (context) => _TextDialog(
        title: "Pair with $tvName",
        label: "Code shown on the TV",
        errorText: wrongCode ? "That code didn't match, try again" : null,
        action: "Pair",
        keyboardType: TextInputType.number,
        maxLength: 4,
      ),
    );
  }

  Future<void> _enterAddress() async {
    final text = await showDialog<String>(
      context: context,
      builder: (context) => const _TextDialog(
        title: "TV address",
        label: "For example 192.168.1.20",
        action: "Connect",
        keyboardType: TextInputType.url,
      ),
    );
    final value = text?.trim();
    if (value == null || value.isEmpty) return;
    final uri = Uri.tryParse("ws://$value");
    if (uri == null || uri.host.isEmpty) {
      setState(() => error = "That doesn't look like an address");
      return;
    }
    await _connect(uri.host, uri.hasPort ? uri.port : remotePort);
  }

  Future<void> _forget(_Tv tv) async {
    if (tv.id == client.tvId) await client.disconnect();
    await store?.forgetTv(tv.id!);
    if (mounted) setState(() {});
  }

  Future<void> _disconnect() async {
    await client.disconnect();
    if (mounted) Navigator.of(context).pop();
  }

  Widget _tile(_Tv tv) {
    final current = client.tvId == tv.id && client.active;
    return ListTile(
      leading: Icon(current ? Icons.cast_connected : Icons.tv),
      title: Text(tv.name),
      subtitle: Text(
        current
            ? "Connected. It keeps playing if you disconnect"
            : tv.discovered
            ? (tv.saved ? "Paired" : "Tap to pair")
            : "Paired, not found on this network",
      ),
      onTap: connecting
          ? null
          : current
          ? _disconnect
          : () => _connect(tv.host, tv.port),
      trailing: tv.saved
          ? IconButton(
              tooltip: "Forget this TV",
              icon: const Icon(Icons.delete_outline),
              onPressed: connecting ? null : () => _forget(tv),
            )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tvs = _tvs();
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text("Play on TV", style: theme.textTheme.titleLarge),
            ),
            if (connecting) const LinearProgressIndicator(),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            ...tvs.map(_tile),
            if (tvs.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  "Looking for TVs on this Wi-Fi. On the TV, open Fred TV, go "
                  "to Settings and choose \"Pair a phone\".",
                ),
              ),
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text("Enter the TV's address"),
              onTap: connecting ? null : _enterAddress,
            ),
          ],
        ),
      ),
    );
  }
}

class _TextDialog extends StatefulWidget {
  final String title;
  final String label;
  final String? errorText;
  final String action;
  final TextInputType keyboardType;
  final int? maxLength;
  const _TextDialog({
    required this.title,
    required this.label,
    this.errorText,
    required this.action,
    required this.keyboardType,
    this.maxLength,
  });

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  final controller = TextEditingController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: controller,
        autofocus: true,
        autocorrect: false,
        keyboardType: widget.keyboardType,
        maxLength: widget.maxLength,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          labelText: widget.label,
          errorText: widget.errorText,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text("Cancel"),
        ),
        TextButton(onPressed: _submit, child: Text(widget.action)),
      ],
    );
  }
}

// Above the bottom navigation while connected to a TV.
class RemoteBar extends StatelessWidget {
  static const height = 64.0;

  const RemoteBar({super.key});

  String _subtitle(
    RemoteConnection connection,
    RemoteStatus status,
    String tv,
  ) {
    if (connection == RemoteConnection.reconnecting) {
      return "Reconnecting to $tv…";
    }
    return switch (status.state) {
      RemotePlayerState.idle => "Connected. Pick something to play",
      RemotePlayerState.buffering => "Loading on $tv",
      RemotePlayerState.playing => "Playing on $tv",
      RemotePlayerState.paused => "Paused on $tv",
      RemotePlayerState.ended => "Finished on $tv",
      RemotePlayerState.error => "Trouble playing on $tv",
    };
  }

  @override
  Widget build(BuildContext context) {
    final client = RemoteClient.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([client.connection, client.status]),
      builder: (context, _) {
        final connection = client.connection.value;
        if (connection != RemoteConnection.connected &&
            connection != RemoteConnection.reconnecting) {
          return const SizedBox.shrink();
        }
        final status = client.status.value;
        final tv = client.tvName ?? "the TV";
        final linked = connection == RemoteConnection.connected;
        final hasMedia = status.state != RemotePlayerState.idle;
        final paused = status.state == RemotePlayerState.paused;
        final theme = Theme.of(context);
        return Material(
          color: theme.colorScheme.surfaceContainer,
          child: SizedBox(
            height: height,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Icon(
                  linked ? Icons.cast_connected : Icons.cast,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        status.title ?? tv,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      Text(
                        _subtitle(connection, status, tv),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (linked && hasMedia) ...[
                  IconButton(
                    tooltip: paused ? "Resume" : "Pause",
                    icon: Icon(paused ? Icons.play_arrow : Icons.pause),
                    onPressed: paused ? client.resume : client.pause,
                  ),
                  IconButton(
                    tooltip: "Stop",
                    icon: const Icon(Icons.stop),
                    onPressed: client.stop,
                  ),
                ],
                IconButton(
                  tooltip: "Disconnect",
                  icon: const Icon(Icons.close),
                  onPressed: client.disconnect,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
