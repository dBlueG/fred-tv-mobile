import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_tv/models/settings.dart';

// Parental PIN state. Locked categories and sources are hidden from every list
// until the PIN is entered; they stay visible until the app restarts or
// "Lock now" is pressed.
class ParentalControl {
  static String? _pin;
  static bool _unlocked = false;

  static void load(Settings settings) => _pin = settings.parentalPin;

  static bool get hasPin => _pin != null && _pin!.isNotEmpty;

  // Whether locked content should be shown.
  static bool get unlocked => !hasPin || _unlocked;

  static void setPin(String? pin) {
    _pin = pin;
    _unlocked = pin != null;
  }

  static void lock() => _unlocked = false;

  // Asks for the PIN unless already unlocked. Returns true once unlocked.
  static Future<bool> unlock(BuildContext context) async {
    if (unlocked) return true;
    return verify(context);
  }

  // Always asks for the PIN (e.g. before changing it). Unlocks on success.
  static Future<bool> verify(BuildContext context) async {
    if (!hasPin) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _PinDialog(
        title: "Enter PIN",
        validate: (pin) => pin == _pin ? null : "Wrong PIN",
      ),
    );
    if (ok == true) _unlocked = true;
    return ok == true;
  }

  // Asks for a new PIN twice. Returns it, or null if cancelled.
  static Future<String?> askNewPin(BuildContext context) async {
    String? first;
    final firstOk = await showDialog<bool>(
      context: context,
      builder: (_) => _PinDialog(
        title: "Choose a PIN",
        message: "4 to 8 digits",
        validate: (pin) {
          if (pin.length < 4) return "Use at least 4 digits";
          first = pin;
          return null;
        },
      ),
    );
    if (firstOk != true || first == null || !context.mounted) return null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _PinDialog(
        title: "Confirm PIN",
        validate: (pin) => pin == first ? null : "The PINs don't match",
      ),
    );
    return confirmed == true ? first : null;
  }
}

class _PinDialog extends StatefulWidget {
  final String title;
  final String? message;
  // Returns an error message, or null if the PIN is accepted.
  final String? Function(String pin) validate;

  const _PinDialog({required this.title, required this.validate, this.message});

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final controller = TextEditingController();
  final focusNode = FocusNode();
  String? error;

  @override
  void dispose() {
    controller.dispose();
    focusNode.dispose();
    super.dispose();
  }

  void submit() {
    final result = widget.validate(controller.text);
    if (result == null) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => error = result);
      controller.clear();
      // Submitting unfocuses the field; keep it ready for another try.
      focusNode.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: controller,
        focusNode: focusNode,
        autofocus: true,
        obscureText: true,
        maxLength: 8,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => submit(),
        decoration: InputDecoration(
          helperText: widget.message,
          errorText: error,
          counterText: "",
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text("Cancel"),
        ),
        TextButton(onPressed: submit, child: const Text("OK")),
      ],
    );
  }
}
