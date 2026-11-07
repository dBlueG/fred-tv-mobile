import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_tv/remote/protocol.dart';
import 'package:open_tv/remote/tv_remote.dart';
import 'package:open_tv/remote/tv_server.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// Shown on the TV to pair a phone: turns phone control on and shows the code.
class ReadyForPhone extends StatefulWidget {
  const ReadyForPhone({super.key});

  @override
  State<ReadyForPhone> createState() => _ReadyForPhoneState();
}

class _ReadyForPhoneState extends State<ReadyForPhone> {
  TvServer? server;
  List<String> addresses = [];
  bool failed = false;

  @override
  void initState() {
    super.initState();
    // A screensaver would count as leaving the app, and the phone couldn't play.
    WakelockPlus.enable().catchError((_) {});
    _start();
  }

  Future<void> _start() async {
    try {
      await TvRemote.instance.setAllowed(true);
    } catch (e) {
      debugPrint("Couldn't start phone control: $e");
      if (mounted) setState(() => failed = true);
      return;
    }
    final found = await _localAddresses();
    if (!mounted) return;
    setState(() {
      server = TvRemote.instance.server;
      addresses = found;
    });
    server?.openPairing();
  }

  Future<List<String>> _localAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      return [
        for (final interface in interfaces)
          for (final address in interface.addresses) address.address,
      ];
    } catch (_) {
      return [];
    }
  }

  @override
  void dispose() {
    server?.closePairing();
    WakelockPlus.disable().catchError((_) {});
    super.dispose();
  }

  String _addressLine() => addresses.map((a) => "$a:$remotePort").join("   ");

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final server = this.server;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("Ready for phone", style: theme.textTheme.headlineMedium),
                const SizedBox(height: 12),
                if (failed)
                  const Text("Couldn't start phone control on this TV")
                else if (server == null)
                  const CircularProgressIndicator()
                else ...[
                  Text(
                    "On your phone, tap the Play on TV button and choose "
                    "\"${server.name}\". Enter this code when asked:",
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  ValueListenableBuilder<String?>(
                    valueListenable: server.pairingCode,
                    builder: (context, code, _) => Text(
                      code ?? "----",
                      style: theme.textTheme.displayLarge?.copyWith(
                        letterSpacing: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (addresses.isNotEmpty)
                    Text(
                      "If the TV isn't listed, enter its address: "
                      "${_addressLine()}",
                      textAlign: TextAlign.center,
                    ),
                  const SizedBox(height: 12),
                  ValueListenableBuilder<String?>(
                    valueListenable: server.lastPaired,
                    builder: (context, phone, _) => phone == null
                        ? const SizedBox.shrink()
                        : Text(
                            "Paired with $phone. Keep Fred TV open and pick "
                            "something on your phone.",
                            textAlign: TextAlign.center,
                            style: TextStyle(color: theme.colorScheme.primary),
                          ),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  autofocus: true,
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text("Done"),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
