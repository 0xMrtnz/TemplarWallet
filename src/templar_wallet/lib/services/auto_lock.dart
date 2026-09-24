import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shared/widgets/list_rows.dart';
import '../theme/app_layout.dart';
import '../theme/app_scheme.dart';

/// When the unlocked vault locks itself again.
///
/// Every gate in the app used to be launch-only: once the passphrase was in,
/// a phone left unlocked in a pocket, or a desktop left at a café table, kept
/// balances, descriptors and the co-sign screen open until the process died.
/// The root of the app asks this policy on every return to the foreground
/// (and, on a desktop, after a stretch with no input) whether to lock.
class AutoLockPolicy {
  AutoLockPolicy._();

  static const _kSeconds = 'pref_auto_lock_seconds';

  /// Stored value meaning "never lock by itself".
  static const int never = -1;

  /// The choices the Settings row offers, in seconds.
  static const List<int> choices = [0, 60, 300, 900, never];

  /// Phones lock after a minute in the background — a phone changes hands
  /// and pockets; a desktop after a quarter of an hour without input.
  static int get platformDefault => AppLayout.isMobilePlatform ? 60 : 900;

  static Future<int> seconds() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_kSeconds) ?? platformDefault;
  }

  static Future<void> setSeconds(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kSeconds, value);
  }

  /// Whether a vault that went out of sight at [since] should be locked at
  /// [now] under a [seconds] setting.
  static bool due({required DateTime since, required DateTime now, required int seconds}) {
    if (seconds == never) return false;
    return now.difference(since).inSeconds >= seconds;
  }

  static String label(int seconds) => switch (seconds) {
        0 => 'Immediately',
        never => 'Never',
        60 => 'After 1 minute',
        final s when s % 60 == 0 => 'After ${s ~/ 60} minutes',
        final s => 'After $s seconds',
      };
}

/// Settings row for [AutoLockPolicy]: shows the current choice and opens a
/// short list to change it.
class AutoLockRow extends StatefulWidget {
  const AutoLockRow({super.key});

  @override
  State<AutoLockRow> createState() => _AutoLockRowState();
}

class _AutoLockRowState extends State<AutoLockRow> {
  int? _seconds;

  @override
  void initState() {
    super.initState();
    AutoLockPolicy.seconds().then((v) {
      if (mounted) setState(() => _seconds = v);
    });
  }

  Future<void> _pick() async {
    final current = _seconds ?? AutoLockPolicy.platformDefault;
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Lock the vault'),
        children: [
          for (final choice in AutoLockPolicy.choices)
            RadioListTile<int>(
              value: choice,
              // ignore: deprecated_member_use
              groupValue: current,
              title: Text(AutoLockPolicy.label(choice)),
              subtitle: choice == 0
                  ? const Text('As soon as the app leaves the screen')
                  : null,
              // ignore: deprecated_member_use
              onChanged: (v) => Navigator.of(ctx).pop(v),
            ),
        ],
      ),
    );
    if (picked == null) return;
    await AutoLockPolicy.setSeconds(picked);
    if (mounted) setState(() => _seconds = picked);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final seconds = _seconds;
    return ListRow(
      icon: Icons.timer_outlined,
      tint: s.success,
      title: 'Auto-lock',
      subtitle: seconds == null
          ? ' '
          : '${AutoLockPolicy.label(seconds)} away from the app',
      chevron: true,
      onTap: _pick,
    );
  }
}
