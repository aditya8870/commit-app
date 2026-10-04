/// What this release does and does not do.
class Features {
  const Features._();

  /// Real-money consequences. OFF in this release: no amount is chosen, shown
  /// or stored, a challenge cannot be ended early, and nothing can be
  /// charged. No payment provider is connected in any case.
  ///
  /// Not a constant only so tests can still exercise the dormant code.
  static bool payments = false;

  /// Public address of the privacy policy. Set at build time with
  /// `--dart-define=commitPrivacyUrl=https://...`. Empty hides the link.
  static const String privacyPolicyUrl = String.fromEnvironment(
    'commitPrivacyUrl',
  );
}
