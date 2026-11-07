import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';

class DeviceDetector {
  static final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();

  static Future<bool> isTV() async {
    if (Platform.isAndroid) {
      return await _isAndroidTV();
    } else if (Platform.isIOS) {
      return await _isAppleTV();
    }
    return false;
  }

  // A name for this device, shown when pairing a phone with a TV.
  static Future<String> model() async {
    try {
      if (Platform.isAndroid) return (await _deviceInfo.androidInfo).model;
    } catch (_) {}
    return "Device";
  }

  static Future<bool> _isAndroidTV() async {
    final androidInfo = await _deviceInfo.androidInfo;
    return androidInfo.systemFeatures.contains('android.software.leanback');
  }

  static Future<bool> _isAppleTV() async {
    final iosInfo = await _deviceInfo.iosInfo;
    return iosInfo.model.toLowerCase().contains('appletv') ||
        iosInfo.utsname.machine.toLowerCase().contains('appletv');
  }
}
