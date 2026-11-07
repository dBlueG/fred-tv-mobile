import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_tv/app_keys.dart';
import 'package:open_tv/generated/generated_proto.pb.dart' as gen;
import 'package:open_tv/task_banner.dart';
import 'package:open_tv/task_service.dart';
import 'package:open_tv/home.dart';
import 'package:open_tv/models/custom_shortcut.dart';
import 'package:open_tv/models/device_detector.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/home_manager.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/parental.dart';
import 'package:open_tv/error.dart';
import 'package:open_tv/remote/remote_client.dart';
import 'package:open_tv/remote/tv_remote.dart';
import 'package:open_tv/resume_prompt.dart';
import 'package:open_tv/utils.dart';
import 'package:open_tv/native_bridge.dart' as nb;
import 'package:open_tv/setup.dart';
import 'package:open_tv/tv_home.dart';
import 'package:path_provider/path_provider.dart';
import 'package:media_kit/media_kit.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isAndroid) {
    MediaKit.ensureInitialized();
  }
  final appDir = await getApplicationSupportDirectory();
  final tempDir = await getApplicationCacheDirectory();
  try {
    await nb.NativeBridge.instance.initialize(
      gen.InitMessage(dbPath: appDir.path, tempPath: tempDir.path),
    );
  } catch (e, stack) {
    if (!e.toString().contains(appDir.path)) {
      developer.log(
        "Failed to initialize NativeBridge",
        error: e,
        stackTrace: stack,
        name: "dev.fredol.open-tv",
      );
    }
  }
  final hasSources = await nb.NativeBridge.instance.hasSources();
  final settings = await nb.NativeBridge.instance.getSettings();
  ParentalControl.load(settings);
  final hasTouchScreen = await Utils.hasTouchScreen();
  final isTV = await DeviceDetector.isTV();
  runApp(
    MyApp(
      skipSetup: hasSources,
      settings: settings,
      hasTouchScreen: hasTouchScreen,
      isTV: isTV,
    ),
  );
  if (Platform.isAndroid) {
    RemoteClient.instance.onMessage = Error.showMessage;
    if (MyApp.usesTvMode(settings, isTV, hasTouchScreen)) {
      TvRemote.instance.startIfAllowed().catchError(
        (e) => debugPrint("Couldn't start phone control: $e"),
      );
    }
  }
  if (hasSources) ResumePrompt.init();
  if (hasSources && settings.refreshOnStart) {
    TaskService.instance.refreshAll();
  } else if (hasSources) {
    TaskService.instance.updateGuides();
  }
}

class MyApp extends StatelessWidget {
  final bool skipSetup;
  final Settings settings;
  final bool hasTouchScreen;
  final bool isTV;

  const MyApp({
    super.key,
    required this.skipSetup,
    required this.settings,
    required this.hasTouchScreen,
    required this.isTV,
  });

  bool get _isEditingText {
    final focus = FocusManager.instance.primaryFocus;
    return focus?.context?.findAncestorWidgetOfExactType<EditableText>() !=
        null;
  }

  bool get _showFocusOutline =>
      !hasTouchScreen ||
      Platform.isLinux ||
      Platform.isWindows ||
      Platform.isMacOS;

  static bool usesTvMode(Settings settings, bool isTV, bool hasTouchScreen) =>
      settings.forceTVMode ||
      isTV ||
      (!hasTouchScreen && (Platform.isAndroid || Platform.isIOS));

  bool get _isTvMode => usesTvMode(settings, isTV, hasTouchScreen);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fred TV',
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: scaffoldMessengerKey,
      builder: (context, child) {
        return CallbackShortcuts(
          bindings: {
            const CustomShortcut(
              SingleActivator(LogicalKeyboardKey.escape),
            ): () {
              if (_isEditingText) return;
              navigatorKey.currentState?.maybePop();
            },
            const CustomShortcut(
              SingleActivator(LogicalKeyboardKey.backspace),
            ): () {
              if (_isEditingText) return;
              navigatorKey.currentState?.maybePop();
            },
          },
          child: Stack(
            children: [
              child ?? const SizedBox.shrink(),
              TaskBanner(hasBottomNav: !_isTvMode),
            ],
          ),
        );
      },
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          surface: Colors.black,
          brightness: Brightness.dark,
          surfaceContainer: const Color.fromARGB(255, 29, 36, 41),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: ButtonStyle(
            side: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.focused) && _showFocusOutline) {
                return const BorderSide(
                  color: Colors.yellow, // yellow border
                  width: 4,
                );
              }
              return BorderSide.none;
            }),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: ButtonStyle(
            side: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.focused) && _showFocusOutline) {
                return const BorderSide(
                  color: Colors.yellow, // yellow border
                  width: 4,
                );
              }
              return null;
            }),
          ),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: ButtonStyle(
            side: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.focused) && _showFocusOutline) {
                return const BorderSide(
                  color: Colors.yellow, // yellow border
                  width: 4,
                );
              }
              return null;
            }),
          ),
        ),
        switchTheme: SwitchThemeData(
          trackOutlineColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused) && _showFocusOutline) {
              return Colors.yellow;
            }
            return null;
          }),
          trackOutlineWidth: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused) && _showFocusOutline) {
              return 4;
            }
            return null;
          }),
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.dark,
      debugShowCheckedModeBanner: false,
      home: skipSetup
          ? (_isTvMode
                ? const TvHome(firstLaunch: true)
                : Home(
                    firstLaunch: true,
                    home: HomeManager(
                      filters: Filters(viewType: settings.defaultView),
                    ),
                  ))
          : Setup(tvMode: _isTvMode),
    );
  }
}
