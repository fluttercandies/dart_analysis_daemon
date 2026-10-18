/// Exit-code policy for `dana check`, aligned with `dart analyze`.
///
/// `dart analyze` exits with 1 for errors and, by default, for warnings
/// (`--fatal-warnings` on, `--fatal-infos` off). Hints are never fatal.
library;

enum _Severity { error, warning, info, hint }

/// Maps both diagnostic encodings Dana can return: legacy analysis-server
/// strings (`ERROR`/`WARNING`/`INFO`) and LSP `DiagnosticSeverity` integers
/// (1 error, 2 warning, 3 information, 4 hint).
_Severity? _severityOf(Object? value) => switch (value) {
  'ERROR' || 1 => _Severity.error,
  'WARNING' || 2 => _Severity.warning,
  'INFO' || 3 => _Severity.info,
  4 => _Severity.hint,
  _ => null,
};

bool _isFatal(
  _Severity severity, {
  required bool fatalWarnings,
  required bool fatalInfos,
}) => switch (severity) {
  _Severity.error => true,
  _Severity.warning => fatalWarnings,
  _Severity.info => fatalInfos,
  _Severity.hint => false,
};

/// Whether [value] contains, at any depth, a diagnostic whose severity is
/// fatal under the given flags.
bool hasFatalDiagnostic(
  Object? value, {
  required bool fatalWarnings,
  required bool fatalInfos,
}) {
  bool visit(Object? node) {
    if (node is List) return node.any(visit);
    if (node is Map) {
      final severity = _severityOf(node['severity']);
      if (severity != null &&
          _isFatal(
            severity,
            fatalWarnings: fatalWarnings,
            fatalInfos: fatalInfos,
          )) {
        return true;
      }
      return node.values.any(visit);
    }
    return false;
  }

  return visit(value);
}

/// Exit code for a check response.
///
/// A structured daemon or bridge failure (`ok == false`) and an unsettled
/// bridge full check (`settled == false`) are always 1 so they can never look
/// successful to a shell gate, whatever diagnostics they carry.
int checkExitCode(
  Object? response, {
  bool fatalWarnings = true,
  bool fatalInfos = false,
}) {
  if (response is Map && response['ok'] == false) return 1;
  // An IDE bridge full check that stopped waiting while diagnostics were
  // still arriving may be incomplete; it must not pass a gate.
  if (response is Map && response['settled'] == false) return 1;
  return hasFatalDiagnostic(
        response,
        fatalWarnings: fatalWarnings,
        fatalInfos: fatalInfos,
      )
      ? 1
      : 0;
}

/// Largest bridge settle timeout accepted, matching the bridge's own bound.
const maxBridgeSettleTimeoutSeconds = 3600;

/// Resolves the bridge settle timeout from `--bridge-settle-timeout`
/// ([flag]) or `DANA_BRIDGE_SETTLE_TIMEOUT_SECONDS` ([environment]); the flag
/// wins. Returns null when neither is set, leaving the bridge default.
/// Throws [FormatException] for anything but an integer in
/// 1..[maxBridgeSettleTimeoutSeconds].
int? parseBridgeSettleTimeout(String? flag, String? environment) {
  final (source, raw) =
      flag != null
          ? ('--bridge-settle-timeout', flag)
          : ('DANA_BRIDGE_SETTLE_TIMEOUT_SECONDS', environment);
  if (raw == null || (flag == null && raw.isEmpty)) return null;
  final value = RegExp(r'^\d+$').hasMatch(raw) ? int.tryParse(raw) : null;
  if (value == null || value < 1 || value > maxBridgeSettleTimeoutSeconds) {
    throw FormatException(
      '$source must be an integer number of seconds in '
      '1..$maxBridgeSettleTimeoutSeconds, got "$raw".',
    );
  }
  return value;
}
