/// Documentation-screenshot mode.
///
/// `--dart-define=TEMPLAR_SHOTS=true` (debug only, used by
/// `integration_test/screenshots_test.dart`) tells the UI it is being
/// photographed for the manuals: the red "MOCK DATA" strip is suppressed so
/// the guides show the wallet as a tester sees it. Nothing else changes, and
/// the flag is a compile-time constant — false in every shipped build.
const bool kShotMode = bool.fromEnvironment('TEMPLAR_SHOTS');
