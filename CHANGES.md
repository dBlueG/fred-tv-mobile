# Changes

Changes made in this fork (`dBlueG/fred-tv-mobile`) on top of the upstream
project (`Fredolx/fred-tv-mobile`).

| # | Change | Date | Area |
|---|---|---|---|
| 1 | [Media notification and lock-screen controls](#1-media-notification-and-lock-screen-controls) | 2026-10-09 | Android player |
| 2 | [Picture-in-Picture](#2-picture-in-picture) | 2026-10-09 | Android player |
| 3 | [Debug builds install alongside the release app](#3-debug-builds-install-alongside-the-release-app) | 2026-10-09 | Android build |
| 4 | [Build toolchain upgrade for Java 25](#4-build-toolchain-upgrade-for-java-25) | 2026-10-09 | Android build |
| 5 | [Repository remotes](#5-repository-remotes) | 2026-10-09 | Git |

Only the Android app is affected. iOS, macOS, Windows and Linux use `media_kit`
for playback and are unchanged.

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

## 3. Debug builds install alongside the release app

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
    ...
}
```

- Debug builds (including `flutter run`) now use the package ID
  `dev.fredol.open_tv.debug`, so they install as a separate app with their own data.
- Release builds keep `dev.fredol.open_tv`.
- Both apps are called "Fred TV" and have the same icon.

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
