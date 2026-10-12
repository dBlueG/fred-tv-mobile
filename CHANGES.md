# Changes

Changes made in this fork (`dBlueG/fred-tv-mobile`) on top of the upstream
project (`Fredolx/fred-tv-mobile`).

| # | Change | Date | Area |
|---|---|---|---|
| 1 | [Media notification and lock-screen controls](#1-media-notification-and-lock-screen-controls) | 2026-10-09 | Android player |
| 2 | [Picture-in-Picture](#2-picture-in-picture) | 2026-10-09 | Android player |
| 3 | [Debug and release builds install alongside the store app](#3-debug-and-release-builds-install-alongside-the-store-app) | 2026-10-09 | Android build |
| 4 | [Build toolchain upgrade for Java 25](#4-build-toolchain-upgrade-for-java-25) | 2026-10-09 | Android build |
| 5 | [Repository remotes](#5-repository-remotes) | 2026-10-09 | Git |
| 6 | [Volume and brightness gestures](#6-volume-and-brightness-gestures) | 2026-10-09 | Android player |
| 7 | [Multiple favorite lists](#7-multiple-favorite-lists) | 2026-10-09 | Rust core, Flutter UI |
| 8 | [Building the Rust core on Windows](#8-building-the-rust-core-on-windows) | 2026-10-09 | Build setup |
| 9 | [Faster Xtream refresh](#9-faster-xtream-refresh) | 2026-10-09 | Rust core |
| 10 | [Player settings, channel switching, double-tap seek, sleep timer](#10-player-settings-channel-switching-double-tap-seek-sleep-timer) | 2026-10-12 | Android player, settings |

Changes 1–4 and 6 only affect the Android app. iOS, macOS, Windows and Linux
use `media_kit` for playback, so their players are unchanged. Change 7 is in the
shared Rust core and Flutter UI; see its notes on other platforms.

Paths below are relative to the repository root. The Android player sources
live in `flutter/android/app/src/main/kotlin/com/example/open_tv/` (package
`dev.fredol.open_tv`).

---

## 1. Media notification and lock-screen controls

**Date:** 2026-10-09
**Status:** Tested on a vivo V2309 (Android 16)

### Problem

Playback continued in the background (audio only), but Android showed no media
controls in the notification shade or on the lock screen, as it does for other
media apps.

Background audio only worked by accident: nothing paused the `ExoPlayer` when
the app went to the background. Two pieces were missing:

- **No `MediaSession`.** Android builds the media notification, lock-screen
  controls, quick-settings media card and Bluetooth/headset button handling
  from a media session. Without one, the app was just "something making sound".
- **No foreground service.** A backgrounded app without one can be killed by the
  OS at any time, cutting playback.

### Solution

A Media3 `MediaSession` is created for each player and hosted in a new
`MediaSessionService`. Media3 then automatically:

- posts and updates the media notification (title, channel logo, play/pause),
- shows the same controls on the lock screen and routes headset buttons,
- promotes the service to the foreground while playing, and demotes it (with a
  dismissible notification) when paused.

### File changes

**`flutter/android/app/build.gradle`**
- Added `androidx.media3:media3-session` (same version as the other Media3 libraries).

**`flutter/android/app/src/main/AndroidManifest.xml`**
- Added permissions `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_MEDIA_PLAYBACK`
  (the latter is required on Android 14+). `POST_NOTIFICATIONS` is not needed,
  because media-session notifications are exempt from it.
- Declared the service:
  ```xml
  <service
      android:name=".PlaybackService"
      android:foregroundServiceType="mediaPlayback"
      android:exported="true">
      <intent-filter>
          <action android:name="androidx.media3.session.MediaSessionService" />
      </intent-filter>
  </service>
  ```
  The `mediaPlayback` type is mandatory on Android 14+. `exported` together with
  the intent filter lets system UI, Bluetooth, Android Auto, etc. find the session.

**`PlaybackService.kt`** (new)
- `onStartCommand` registers the active player's session with the service.
- `onGetSession` returns that session to controllers (system UI, Bluetooth, …).
- `onTaskRemoved` pauses playback and stops the service when the app is swiped
  away from Recents.
- The service does not own the player. It stays owned by `ExoPlayerView`, so the
  existing platform-view lifecycle is unchanged.

**`ExoPlayerView.kt`**
- New public `session: MediaSession`, built in `init` with:
  - a per-view ID (`exoplayer_<viewId>`), since Media3 requires unique IDs;
  - a session activity, so tapping the notification reopens the app.
- Starts `PlaybackService` after creating the session. This happens while the
  app is in the foreground, so background-start restrictions don't apply.
- `restrictedPlayer()` now takes the blocked command list directly, so it can be
  used with different rules for the in-app UI and the notification:
  - **In-app UI:** unchanged (no speed control, and for live streams no
    play/pause or seeking).
  - **Notification:** same, except **live streams keep play/pause** so
    background audio can be stopped. If a paused live stream falls behind the
    live window, the existing reconnect logic recovers it.
- `mediaItem()` replaces `MediaItem.fromUri(url)` and adds `MediaMetadata`
  (title and channel logo). It is also used on reconnect, so the metadata isn't lost.
- `dispose()` releases the session and stops the service, which removes the
  notification.

**`flutter/lib/exo_player.dart`**
- Passes `"image": widget.channel.image` to the native view for the notification artwork.

### Behavior

| Situation | Result |
|---|---|
| Any playback (foreground or background) | Media notification with title, logo, play/pause |
| Screen locked while playing | Audio continues; lock-screen controls shown |
| Live channel | Play/pause available, no seek |
| Tap notification | Returns to the app |
| Leave the player screen | Notification removed, service stopped |
| Swipe app away from Recents | Playback paused, service stopped |

### Release note

Google Play requires apps targeting Android 14+ that declare
`FOREGROUND_SERVICE_MEDIA_PLAYBACK` to fill in the foreground-service
declaration in the Play Console (justification: background media playback).

---

## 2. Picture-in-Picture

**Date:** 2026-10-09
**Status:** Tested on a vivo V2309 (Android 16). The Android 8–11 path is untested.

### Problem

The app had no Picture-in-Picture support on any platform.

### How PiP works on Android

- The activity must opt in with `android:supportsPictureInPicture="true"`.
- **Android 12+:** the app sets `PictureInPictureParams` with
  `setAutoEnterEnabled(true)` in advance, and the system enters PiP on Home.
- **Android 8–11:** the app must call `enterPictureInPictureMode()` from
  `onUserLeaveHint()`.
- Android 7 and below have no phone PiP; the code does nothing there.
- The aspect ratio must be between 1:2.39 and 2.39:1, otherwise Android throws
  `IllegalArgumentException`.

### File changes

**`flutter/android/app/src/main/AndroidManifest.xml`**
- `MainActivity` gets `android:supportsPictureInPicture="true"` and
  `android:resizeableActivity="true"`. The existing `configChanges` already
  covers screen size and layout, so entering or leaving PiP does not restart the
  activity, the Flutter engine or the player.

**`ExoPlayerView.kt`**
- New constructor callback `onPipStateChanged: () -> Unit`, called when
  play/pause state or video size changes and when the view is disposed.
- `wantsPlayback`: `player.playWhenReady`, so a stream that is briefly
  buffering still counts as playing.
- `pipAspectRatio()`: the video's display aspect ratio (including
  `pixelWidthHeightRatio`), clamped to the allowed range; `null` until the size is known.
- `onPipModeChanged(inPip)`: hides and disables the player controls in PiP, and
  re-enables them on return.
- `dispose()` calls `onPipStateChanged()` so auto-enter is switched off once the
  player closes. Otherwise pressing Home on other screens could still trigger PiP.

**`ExoPlayerViewFactory.kt`**
- Passes the `onPipStateChanged` callback through to each view.

**`MainActivity.kt`**
- Registers the factory with `::updatePipParams` as the callback.
- `updatePipParams()` (API 26+, only if the device has
  `FEATURE_PICTURE_IN_PICTURE`) calls `setPictureInPictureParams(...)`.
- `pipParams()` sets the aspect ratio and, on Android 12+, enables auto-enter
  only while a player is active and playing.
- `onUserLeaveHint()` enters PiP manually on Android 8–11.
- `onPictureInPictureModeChanged()` forwards the PiP state to the player.

### Behavior

| Situation | Result |
|---|---|
| Video playing, user presses Home | Enters PiP |
| Video paused, user presses Home | No PiP; app goes to background |
| In PiP | Video only; system PiP buttons available |
| Tap PiP window | Returns to full screen |
| Close the PiP window | Audio keeps playing; notification controls remain |
| Press Home outside the player | No PiP |

### Possible follow-ups

- **To stop playback when the PiP window is closed:** in
  `onPictureInPictureModeChanged(false)`, check whether the activity is no longer
  started (`lifecycle.currentState == CREATED`) and pause the player.
- **To disable PiP on Android TV:** add
  `!packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)` to `supportsPip()`.
- **vivo and other custom Android skins** may block PiP per app (Settings → Apps →
  Picture-in-picture) or restrict background playback through battery settings.

---

## 3. Debug and release builds install alongside the store app

**Date:** 2026-10-09

### Problem

The phone already had Fred TV installed, signed with a different key. Android
refused to install the debug build over it
(`INSTALL_FAILED_UPDATE_INCOMPATIBLE`), and uninstalling would have deleted the
app's data (sources, favorites, settings).

### Solution

**`flutter/android/app/build.gradle`**
```gradle
buildTypes {
    debug {
        // Installs side by side with the release app.
        applicationIdSuffix ".debug"
    }
    release {
        applicationIdSuffix ".release"
        ...
    }
}
```

- Debug builds (including `flutter run`) now use the package ID
  `dev.fredol.open_tv.debug`, so they install as a separate app with their own data.
- Release builds use `dev.fredol.open_tv.release`, so they also install next to
  the originally installed app instead of failing on the signing mismatch.
- All three apps are called "Fred TV" and have the same icon.
- Because the release package ID changed, a release build from this repo won't
  update an earlier release build that used `dev.fredol.open_tv`; it installs as
  a separate app with its own data.

### Note on release signing

The `release` build type still signs with the debug key
(`signingConfig = signingConfigs.debug`, from the upstream template). Release
APKs built from this repo therefore can't be uploaded to Google Play and can't
be installed over a properly signed copy of the app. To fix this, add a
`key.properties` file (kept out of git) and a release signing config.

---

## 4. Build toolchain upgrade for Java 25

**Date:** 2026-10-09
**Status:** Debug and release APKs build with Flutter 3.47.7 and Java 25. The debug build installs and launches on the vivo.

### Problem

Android Studio now bundles Java 25, and Flutter uses that JDK by default. The
project's Gradle 8.14 does not support Java 25, so every Android build failed:

```
Error resolving plugin [id: 'dev.flutter.flutter-plugin-loader', version: '1.0.0']
> 25.0.3
Gradle build failed due to Java/Gradle incompatibility.
```

Flutter also warned that support for the project's AGP and Kotlin versions
would be dropped soon.

### Solution

| Component | Before | After | File |
|---|---|---|---|
| Gradle wrapper | 8.14 | 9.8.1 | `flutter/android/gradle/wrapper/gradle-wrapper.properties` |
| Android Gradle Plugin | 8.13.2 | 9.4.1 | `flutter/android/settings.gradle` |
| Kotlin Gradle Plugin | 2.2.20 | 2.3.21 | `flutter/android/settings.gradle` |

Why all three had to change:

- Java 25 needs **Gradle 9.1+**.
- **Gradle 9.6+** removed an internal API that AGP 8.x depends on (tried; it fails
  with `relies on 'org.gradle.api.problems.internal.InternalProblems'`), so
  **AGP had to move to 9.x**.
- AGP 9.0.1+ and Kotlin 2.3.20+ are also the minimum versions that Flutter will
  keep supporting.

### Other files changed by the Flutter 3.47.7 tooling

- **`flutter/pubspec.lock`**: picked up the SDK-pinned package versions for
  Flutter 3.47.7 (`intl`, `matcher`, `meta`, `test_api`, `vector_math`).
- **`flutter/analysis_options.yaml`**: Flutter's automatic migration excludes
  `build/` and the platform folders from analysis.

### Known warning: built-in Kotlin

`android.builtInKotlin=false` and `android.newDsl=false` stay in
`flutter/android/gradle.properties`. These four plugins still apply the Kotlin
Gradle Plugin, so the app can't switch to AGP's built-in Kotlin yet:

- `device_info_plus`
- `file_picker`
- `package_info_plus`
- `wakelock_plus`

Flutter prints a warning about this. It doesn't block builds today, but a future
Flutter release will make it an error. Next step: upgrade these plugins (newer
versions exist) and then follow Flutter's
[built-in Kotlin migration guide](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-app-developers).

---

## 5. Repository remotes

**Date:** 2026-10-09

Local git configuration only; no files changed.

| Remote | URL | Purpose |
|---|---|---|
| `origin` | `https://github.com/dBlueG/fred-tv-mobile.git` | This fork (push here) |
| `upstream` | `https://github.com/Fredolx/fred-tv-mobile.git` | Original project |

To pull in upstream changes:

```sh
git fetch upstream
git merge upstream/main
```

---

## 6. Volume and brightness gestures

**Date:** 2026-10-09
**Branch:** `gestures-and-favorite-lists`

### Behavior

- **Right half of the screen, drag up/down:** media volume (the same volume the
  hardware buttons control).
- **Left half, drag up/down:** screen brightness, for this app only. No
  permission is needed, and the system brightness comes back when the player closes.
- Dragging the full screen height covers the whole range (0–100%).
- A small indicator (icon and level bar) shows in the middle of the screen while
  dragging and fades out 0.7 s after release. The volume icon switches to
  "muted" at 0%.
- Taps still show/hide the controls, and the buttons and seek bar work as before.
  A drag only counts once the finger has moved past the system touch slop, and
  mostly vertically (1.5× more vertical than horizontal).
- Drags that start in the top or bottom 8% of the screen are ignored, so they
  don't clash with the notification shade or gesture navigation.
- Gestures are off in Picture-in-Picture and on devices without a touchscreen
  (Android TV).

### File changes

**`PlayerGestureLayout.kt`** (new)
A `FrameLayout` that replaces the root of the player layout. It watches touches
in `onInterceptTouchEvent`. It only takes over a touch once it is clearly a
vertical drag, at which point the children get `ACTION_CANCEL`, so taps and
horizontal moves still reach the player and its controls. The seek bar asks
parents not to intercept while scrubbing, so it keeps working too. Reports
`onVerticalDragStart(leftSide)`, `onVerticalDrag(delta)` (fraction of height,
positive = up) and `onVerticalDragEnd()`.

**`PlayerGestureController.kt`** (new)
Applies the drags:
- Volume via `AudioManager.setStreamVolume(STREAM_MUSIC, …)`. The level is
  tracked as a float, so slow drags add up across volume steps.
- Brightness via the activity window's `screenBrightness` (minimum 1%). The
  starting value is the current override or, if none, the system brightness
  setting. `release()` resets it to `BRIGHTNESS_OVERRIDE_NONE`.
- Updates the indicator icon and level.

**`res/layout/exo_player_container.xml`**
The root is now `PlayerGestureLayout`. The indicator (`gesture_indicator`, with
an icon and a horizontal `ProgressBar`) is added above the `PlayerView`.

**`res/drawable/`** (new): `ic_player_volume.xml`, `ic_player_volume_off.xml`,
`ic_player_brightness.xml`, `bg_player_indicator.xml`.

**`ExoPlayerView.kt`**
- Takes the `Activity` (needed for the window brightness), creates the
  controller and connects it to the layout.
- Gestures are enabled only if the device has `FEATURE_TOUCHSCREEN`, and are
  turned off while in PiP.
- `dispose()` calls `gestures.release()` to restore system brightness.

**`ExoPlayerViewFactory.kt`, `MainActivity.kt`**
Pass the activity through to the player view.

**`flutter/lib/exo_player.dart`**
The platform view now registers an `EagerGestureRecognizer`, so Flutter hands
every touch (including vertical drags) to the native view instead of keeping
them for its own gesture arena.

---

## 7. Multiple favorite lists

**Date:** 2026-10-09
**Branch:** `gestures-and-favorite-lists`

### Behavior

- **The main Favorites view is unchanged** and shows every favorite. Being in
  any list also makes a channel a favorite.
- **List chips:** the Favorites screen has a row of chips under the search box:
  `All`, one chip per list, and `+ New list`. Tapping a chip shows only that list.
  This works with a TV remote too.
- **Managing lists:** long-press a list chip, or select it and press the `⋮`
  button, to **Rename** or **Delete** it. Deleting a list doesn't remove its
  channels from the main favorites.
- **Favoriting a channel** (long-press on a tile, or holding Select on a remote):
  - **No lists yet:** toggles the favorite instantly, as before.
  - **Lists exist:** opens a dialog with one checkbox per list (already ticked for
    the lists the channel is in), `+ New list` (creates a list and ticks it), and
    **Save**. If the channel is already a favorite, **Remove** takes it out of
    favorites and every list.
- On the Favorites screen, the grid reloads after a change, so a channel removed
  from the selected list disappears from it.
- The snackbar now says "Removed from favorites" or "Favorite lists updated"
  where appropriate. It used to say "Added to favorites" even when removing.
- **Source refresh:** a refresh deletes and re-creates a source's channels.
  Favorites were already re-matched by channel name afterwards, and list
  membership is now kept the same way.

### Data model

A third migration in `apply_main_migrations` (`src/sql.rs`):

```sql
CREATE TABLE "favorite_lists" (
  "id"   INTEGER PRIMARY KEY,
  "name" varchar(100) NOT NULL COLLATE NOCASE
);
CREATE TABLE "favorite_list_channels" (
  "list_id"    integer NOT NULL,
  "channel_id" integer NOT NULL,
  PRIMARY KEY (list_id, channel_id)
);
CREATE UNIQUE INDEX index_favorite_lists_name ON favorite_lists(name);
CREATE INDEX index_favorite_list_channels_channel_id ON favorite_list_channels(channel_id);
```

- `channels.favorite` still means "is a favorite", so existing favorites and
  the main view need no data changes.
- List names are unique regardless of case (`COLLATE NOCASE`).
- SQLite foreign keys are not enabled in this app (`PRAGMA foreign_keys` is never
  set), so `ON DELETE CASCADE` never runs. List entries are therefore removed in
  code whenever channels or lists are deleted.

### Rust core (`src/`)

**`sql.rs`**
- `get_favorite_lists`, `create_favorite_list`, `rename_favorite_list`,
  `delete_favorite_list`. Names are trimmed and must be non-empty and not
  already used.
- `get_channel_favorite_lists(channel_id)` and
  `set_channel_favorite_lists(channel_id, favorite, list_ids)`. The latter sets
  the favorite flag and replaces the channel's lists in one transaction; a
  non-favorite can't be in any list.
- `favorite_channel(id, false)` now also removes the channel from every list.
- `search()`: in the Favorites view, `Filters.favorite_list_id` limits results
  to that list.
- `delete_channels_by_source` (used by refresh) and `delete_source` remove the
  source's list entries first.
- `get_preserve` / `restore_preserve` save each favorite's list IDs before a
  refresh and re-add them, matched by channel name, afterwards.
- New test `test_favorite_lists::favorite_lists_flow` covers creating,
  validating, filtering, refreshing, renaming, removing, deleting a list and
  deleting a source against a real SQLite database.

**`types.rs`**: `FavoriteList`; `Filters.favorite_list_id`; `ChannelPreserve.list_ids`.

**`lib.rs`**: new FFI functions `get_favorite_lists`, `create_favorite_list`,
`rename_favorite_list`, `delete_favorite_list`, `get_channel_favorite_lists`,
`set_channel_favorite_lists`.

**`protocol/generated_proto.proto`**: messages `FavoriteList`,
`FavoriteListList`, `SetChannelFavoriteLists`, `RenameFavoriteList`, `IdList`;
`Filters.favorite_list_id`; three new `FFIResult` data types.

**Generated code:** `src/generated_proto.rs` and
`flutter/lib/generated/generated_proto.pb*.dart` regenerated with `protoc`
(Dart with `protoc_plugin` 25.0.0, which matches the app's `protobuf` 6.0.0;
25.1.0 requires `protobuf` 6.1). The six new functions were added to
`flutter/lib/generated/bindings.dart` by hand in ffigen's format, because the
existing file was generated on Linux and a Windows ffigen run would rewrite all of it.

**Android libraries:** `flutter/android/app/src/main/jniLibs/*/libfred_tv_lib.so`
rebuilt for arm64-v8a, armeabi-v7a and x86_64.

### Flutter (`flutter/lib/`)

- `models/favorite_list.dart` (new), `models/filters.dart` (`favoriteListId`),
  `extensions/proto_extensions.dart`.
- `native_bridge.dart`: wrappers for the six FFI functions.
- `task_service.dart`: write operations go through the "busy" check (blocked
  during a refresh, like favoriting already was). A `favoriteListsVersion`
  notifier lets the chip row reload when lists change anywhere.
- `favorite_lists_dialog.dart` (new): `FavoriteListsDialog` (checkboxes),
  `FavoriteListNameDialog` (name input with empty/duplicate checks), and
  `promptCreateFavoriteList`.
- `favorite_list_bar.dart` (new): the chip row with rename/delete actions.
- `channel_tile.dart`: the new favoriting flow; `onFavoriteChanged` callback.
- `home.dart`: shows the chip row on the top-level Favorites screen (phone and
  TV mode) and filters by the selected list.

### Other platforms

The Dart UI is shared, but each platform has its own prebuilt Rust library.
Only the Android libraries were rebuilt. Before shipping Linux or Windows, rebuild
their library (`cargo cmd build-linux` / `cargo cmd build-windows`; the Windows CI
workflow already builds from source). Until then, favoriting on those platforms
shows an error once a list exists, because the new functions are missing from
the old library.

---

## 8. Building the Rust core on Windows

**Date:** 2026-10-09

The repo's `cargo cmd` scripts assume Linux. To rebuild the Android libraries on
this Windows machine, the following was installed:

| Tool | Installed with | Why |
|---|---|---|
| Visual Studio 2022 Build Tools (C++ workload) | `winget` | Host linker for Rust build scripts and tests |
| Rust (`rustup`, stable) + `aarch64-linux-android`, `armv7-linux-androideabi`, `x86_64-linux-android` | `winget`, `rustup` | Compiler and Android targets |
| `cargo-ndk`, `protoc-gen-prost` | `cargo install` | Android builds, Rust protobuf generation |
| `protoc` 36 | `winget` (Google.Protobuf) | Protobuf compiler |
| `protoc_plugin` 25.0.0 | `dart pub global activate` | Dart protobuf generation |
| MSYS2 (`perl`, `make`) | `winget`, `pacman` | Building the vendored OpenSSL for Android needs a Unix-style Perl and make |
| LLVM, Strawberry Perl | `winget` | Installed while trying alternatives; not needed for the final build |

Commands (Git Bash; MSYS2 goes **last** in `PATH` so its `link.exe` doesn't
shadow the MSVC linker):

```sh
# Protobuf code
protoc --prost_opt=flat_output_dir=true --prost_out=src -I ./protocol/ generated_proto.proto
protoc --plugin=protoc-gen-dart="$LOCALAPPDATA/Pub/Cache/bin/protoc-gen-dart.bat" \
  --dart_out=flutter/lib/generated -I ./protocol/ generated_proto.proto

# Tests
cargo test

# Android libraries
export PATH="$HOME/.cargo/bin:$PATH:/c/msys64/usr/bin"
export ANDROID_NDK_HOME="$LOCALAPPDATA/Android/Sdk/ndk/29.0.14206865"
export OPENSSL_SRC_PERL="C:/msys64/usr/bin/perl.exe" MAKE="C:/msys64/usr/bin/make.exe"
cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 --platform 24 \
  -o flutter/android/app/src/main/jniLibs build --release
```

Known test failure: `m3u::test_m3u::test_get_channel_from_lines` (from upstream)
expects two different names for the same input line, so it can't pass. It is
unrelated to these changes.

---

## 9. Faster Xtream refresh

**Date:** 2026-10-09
**Branch:** `gestures-and-favorite-lists`

### Behavior

Refreshing an Xtream source (and loading series episodes) needs less data and
fewer connections. Nothing changes in the UI.

### File changes

**`Cargo.toml`**
Added the `gzip`, `brotli` and `deflate` features to `reqwest` for both the
Android (`native-tls-vendored`) and desktop (`rustls`) builds. The client now
sends `Accept-Encoding` and decompresses responses on its own. Xtream channel lists
are large JSON documents, so compressed responses are much smaller.

**`src/xtream.rs`**
- New `build_client(source)` creates one `reqwest::Client` with the source's
  user agent.
- `get_xtream` builds one client per refresh and passes it to the six parallel
  `get_xtream_http_data` requests. Before, each request built its own client,
  so none of them could share connections.
- `get_episodes` and `get_status` use `build_client` as well.

---

## 10. Player settings, channel switching, double-tap seek, sleep timer

**Date:** 2026-10-12
**Branch:** `player-and-home-features`
**Status:** Smoke-tested on the Android emulator (Pixel 9a image) against a mock
Xtream server; not yet tested on the vivo.

### Behavior

**New "Player" section in Settings** (Android only). Touch-only options are hidden
in TV mode.

| Setting | Default | Effect |
|---|---|---|
| Volume and brightness gestures | On | The drags from change 6 |
| Swipe to change channel | On | Horizontal swipe on a livestream |
| Double-tap to seek | On | Movies and episodes |
| Seek amount | 10 s | 10, 15 or 30 s; used by double-tap, the ⏪/⏩ buttons and D-pad seeking |
| Picture-in-picture | On | Off: Home leaves the player normally. Never used on Android TV |
| Keep playing after closing picture-in-picture | Off | Off: closing the PiP window pauses playback |

**Changing channel in the player (livestreams).**
- Swipe left for the next channel and right for the previous one. The channel
  name shows at the top for 2 s.
- Remote: Channel up/down (and Page up/down) always switch. D-pad up/down switch
  while the controls are hidden; while they're shown, they move between buttons.
  Up/Channel up = previous in the list, Down/Channel down = next.
- The list is the one the channel was opened from (All, a category, Favorites or a
  favorite list, History, search results), in the same order. Only livestreams
  are visited. More pages load as needed, and it wraps around once the whole list
  is loaded. Each channel switched to is added to History.

**Double-tap to seek (movies and episodes).** Double-tap the left or right 40% of
the screen to go back or forward. Further taps keep seeking, and a "+20 s"-style
indicator shows the total. The middle of the screen, the top bar and the bottom
controls area are left alone.

**Sleep timer.** New timer button in the player's bottom bar: Off, 15, 30, 45, 60,
90 or 120 minutes. The icon turns amber while a timer is set, and the dialog shows
the minutes left. When it fires, playback pauses and the screen is allowed to turn
off.

**Live play/pause.** Live streams now show the play button while paused (from the
notification, the sleep timer, or closing PiP). Resuming a live stream jumps to the
live edge. The button stays hidden while playing, as before.

**PiP follow-ups (from change 2).** Closing the PiP window pauses playback unless
"Keep playing…" is on. If a livestream was paused this way, it resumes when the app
is opened again, since it has no play button while playing. PiP is never entered on
Android TV (`FEATURE_LEANBACK`).

### File changes

**Settings plumbing:** six new optional fields in `Settings`
(`protocol/generated_proto.proto`, fields 9–14), regenerated
`src/generated_proto.rs` and `flutter/lib/generated/generated_proto.pb*.dart`,
`src/types.rs`, `src/lib.rs` (conversions), `src/settings.rs` (keys and an
`insert_opt` helper), `flutter/lib/models/settings.dart`,
`flutter/lib/extensions/proto_extensions.dart`. Android `.so` libraries rebuilt.

**`flutter/lib/settings_view.dart`**: "Player" section, seek amount dialog.

**`flutter/lib/models/channel_playlist.dart`** (new): the list the player can
switch in; `Filters.copy()` in `models/filters.dart`.

**`flutter/lib/home.dart`, `channel_tile.dart`**: build a `ChannelPlaylist` for the
tapped livestream and pass it to the player.

**`flutter/lib/exo_player.dart`**: passes the player settings and
`canSwitchChannel` in the creation params, and answers `switchChannel(delta)` from
native code with the next channel's URL, title, logo and HTTP headers.

**`PlayerGestureLayout.kt`**: also detects horizontal swipes (at least 15% of
the width) and double taps, each with its own enable flag. Fix: an intercepted
event is also delivered to `onTouchEvent`, so events are now de-duplicated (a
double tap was counted twice).

**`ExoPlayerView.kt`**:
- Reads the settings; seek increment from "Seek amount".
- `requestChannelSwitch` / `loadChannel`: asks Flutter for the next channel and
  swaps the media item. The HTTP headers are re-applied to the existing data
  source factory, and a pending reconnect is cancelled.
- `onDoubleTap`, the seek indicators, the sleep timer dialog and timer.
- `blockedCommands`: live streams no longer block play/pause; `updateLiveControls`
  shows the button only while paused; resuming live seeks to the default position.
- `keepScreenOn` follows `playWhenReady`.
- `pipAllowed`, `canEnterPip`, `onPipClosed`, `onHostResumed`.
- D-pad and channel keys switch channels (`channelKeyDelta`).

**`MainActivity.kt`**: uses `canEnterPip`. Detects a closed PiP window (PiP ends
while the activity is stopped, i.e. lifecycle state `CREATED`), and forwards
`onResume`.

**Layouts and resources:** `sleep_button` in `custom_player_control_view.xml`;
`channel_indicator` and the two seek indicators in `exo_player_container.xml`;
`ic_player_timer.xml`; `sleep_timer` string.

### Not covered

- The `media_kit` player (iOS, desktop) is unchanged. It has its own double-tap
  seek, but no channel switching or sleep timer.
- Sleep timer firing after 15 minutes was not waited out on the emulator; the
  dialog, countdown and pause path were checked.
