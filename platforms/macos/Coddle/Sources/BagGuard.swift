import Foundation

/// The bag-guard sleep predicate, extracted as a pure free function so its
/// truth table can be exercised without any IOKit / AppKit state.
///
/// The guard releases keep-awake (thus *allowing* the Mac to sleep) only when
/// all of the following hold:
///   * we are "away" — the away engine's verdict, which already applies the
///     `awayAfterMinutes` delay and the offline backstop;
///   * the Mac is unattended — the lid is closed, the user has been idle past
///     `idleSeconds`, *or* the screen is locked; and
///   * when `requireBattery` is set, the Mac must be on battery (never on AC,
///     where there is no reason to force sleep).
///
/// An actively-used machine (lid open AND not idle AND unlocked) can never
/// satisfy the predicate, so keep-awake is never released under someone's hands.
func shouldAllowSleep(
    away: Bool,
    lidClosed: Bool,
    idle: Bool,
    screenLocked: Bool,
    onBattery: Bool,
    requireBattery: Bool
) -> Bool {
    var allow = away && (lidClosed || idle || screenLocked)
    if requireBattery { allow = allow && onBattery }
    return allow
}
