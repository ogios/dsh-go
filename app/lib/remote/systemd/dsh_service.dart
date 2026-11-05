import 'package:dsh_client/dsh_client.dart';

import '../../l10n/l10n.dart';
import '../link_status.dart';
import '../ssh/remote_shell.dart';

const _tag = 'DSHAPP';

/// A DSH user service reachable through the SSH tunnel.
class RemoteDshEndpoint {
  const RemoteDshEndpoint({required this.port, required this.token, this.pid, this.reused = false, this.home});

  final int port;
  final String token;
  final int? pid;
  final bool reused;

  /// Remote home used to resolve the default cwd for new sessions.
  final String? home;

  String get authority => '127.0.0.1:$port';
}

/// Controls an installed systemd user service and reads its launch URL.
class DshService {
  DshService(
    this.shell, {
    String unit = 'dsh-web',
    this.workingDirectory,
    this.startTimeout = const Duration(seconds: 60),
  }) : unit = normalizeUnit(unit);

  final RemoteShell shell;
  final String unit;

  /// Default cwd for new sessions; the service defines its own working directory.
  final String? workingDirectory;
  final Duration startTimeout;

  static bool isValidUnit(String unit) => RegExp(r'^[A-Za-z0-9:_.@-]+$').hasMatch(unit);

  static String normalizeUnit(String unit) {
    final name = unit.trim();
    if (!isValidUnit(name)) throw ArgumentError.value(unit, 'unit');
    return name.endsWith('.service') ? name : '$name.service';
  }

  String? resolvedWorkingDirectory(String? home) => absolutePath(workingDirectory, home);

  Future<RemoteDshEndpoint> ensureRunning({bool forceRestart = false, void Function(String)? onDetail}) async {
    onDetail?.call(appL10n.remoteBootstrapStarting);
    final seconds = startTimeout.inSeconds.clamp(1, 60).toInt();
    final result = await shell.run(
      'unit=${shQuote(unit)}\nforceRestart=${forceRestart ? 1 : 0}\nseconds=$seconds\n$_ensureScript',
      timeout: Duration(seconds: seconds + 20),
    );
    final values = _tagged(result.stdout);
    final parsed = DshLaunchUrl.tryParse(values['url']?.last ?? '');
    if (result.ok && parsed != null && parsed.baseUri.port > 0 && parsed.baseUri.port <= 65535) {
      final reused = values.containsKey('reused');
      if (reused) onDetail?.call(appL10n.remoteBootstrapReusePort(parsed.baseUri.port));
      return RemoteDshEndpoint(
        port: parsed.baseUri.port,
        token: parsed.token,
        pid: int.tryParse(values['pid']?.last ?? ''),
        reused: reused,
        home: values['home']?.last,
      );
    }
    throw _error(result, values);
  }

  Future<void> stopService() => _control('stop');

  Future<void> restartService() async {
    await ensureRunning(forceRestart: true);
  }

  Future<void> _control(String action) async {
    final result = await shell.run(
      'systemctl --user $action -- ${shQuote(unit)}\n'
      'status=\$?\nprintf \'$_tag status %s\\n\' "\$status"\nexit "\$status"\n',
    );
    if (!result.ok) throw _error(result, _tagged(result.stdout));
  }

  /// Returns journal text with launch tokens removed for display or diagnostics.
  Future<String> logTail(int lines) async {
    final result = await shell.run(
      'log=\$(journalctl --user -u ${shQuote(unit)} -o cat -n ${lines.clamp(1, 2000)} --no-pager)\n'
      'status=\$?\nprintf \'%s\\n\' "\$log" | sed \'s/^/$_tag log /\'\nexit "\$status"\n',
    );
    final values = _tagged(result.stdout);
    if (!result.ok) throw _error(result, values);
    return redactTokens((values['log'] ?? []).join('\n'));
  }

  static Map<String, List<String>> _tagged(String stdout) {
    final values = <String, List<String>>{};
    for (final line in stdout.split('\n')) {
      if (!line.startsWith('$_tag ')) continue;
      final rest = line.substring(_tag.length + 1);
      final space = rest.indexOf(' ');
      final key = space < 0 ? rest : rest.substring(0, space);
      final value = space < 0 ? '' : rest.substring(space + 1);
      (values[key] ??= []).add(value);
    }
    return values;
  }

  HostLinkError _error(RemoteExecResult result, Map<String, List<String>> values) {
    final stderr = result.stderr.trim();
    final detail = redactTokens([
      if (result.exitCode != null) appL10n.remoteExitCode(result.exitCode!),
      if (stderr.isNotEmpty) stderr,
      ...?values['log'],
    ].join('\n'));
    if (RegExp(r'Failed to connect to (user scope )?bus', caseSensitive: false).hasMatch(stderr)) {
      return HostLinkError(HostLinkErrorKind.serviceStartFailed, appL10n.remoteErrUserBus, detail: detail);
    }
    if (values.containsKey('catfailed') &&
        RegExp(r'could not be found|No such file', caseSensitive: false).hasMatch(stderr)) {
      return HostLinkError(HostLinkErrorKind.unitNotFound, appL10n.remoteErrUnitNotFound, detail: detail);
    }
    if (!result.stdout.contains(_tag) &&
        RegExp(r"'sh' is not recognized|sh: (command )?not found|command not found: sh").hasMatch(stderr)) {
      return HostLinkError(HostLinkErrorKind.noShell, appL10n.remoteErrNoShell, detail: detail);
    }
    return HostLinkError(
      values.containsKey('timeout') ? HostLinkErrorKind.dshTimeout : HostLinkErrorKind.serviceStartFailed,
      values.containsKey('timeout') ? appL10n.remoteErrDshStartTimeout : appL10n.remoteErrDshStart,
      detail: detail,
    );
  }

  static String redactTokens(String text) => text.replaceAll(RegExp(r'token=[^\s&"\x27<>]+'), 'token=•••');

  static String? absolutePath(String? path, String? home) {
    final p = path?.trim();
    if (p == null || p.isEmpty) return null;
    if (home == null || home.isEmpty) return p;
    if (p == '~') return home;
    if (p.startsWith('~/')) {
      return '${home.endsWith('/') ? home.substring(0, home.length - 1) : home}/${p.substring(2)}';
    }
    return p;
  }

  static const _ensureScript = r'''
printf 'DSHAPP home %s\n' "$HOME"
if ! systemctl --user cat -- "$unit" >/dev/null; then
  printf 'DSHAPP catfailed\n'
  exit 1
fi
read_state() {
  # Query each property separately because systemctl does not preserve -p order.
  active=$(systemctl --user show -p ActiveState --value -- "$unit") || return 1
  sub=$(systemctl --user show -p SubState --value -- "$unit") || return 1
  pid=$(systemctl --user show -p MainPID --value -- "$unit") || return 1
}
invocation=''
journal() {
  if [ -n "$invocation" ]; then
    journalctl --user -u "$unit" -o cat -n 200 --no-pager "_SYSTEMD_INVOCATION_ID=$invocation"
  else
    journalctl --user -u "$unit" -o cat -n 200 --no-pager
  fi
}
tail_log() {
  printf '%s\n' "$log" | tail -n 20 | sed 's/^/DSHAPP log /'
}
launch_line() {
  line=$(printf '%s\n' "$log" | grep -E 'https?://[^ ]*[?&]token=' | tail -n 1)
}
emit_endpoint() {
  printf 'DSHAPP pid %s\nDSHAPP url %s\n' "$pid" "$line"
}
read_state || exit 1
if [ "$forceRestart" = 0 ] && [ "$active" = active ]; then
  log=$(journal) || exit 1
  launch_line
  if [ -n "$line" ]; then
    printf 'DSHAPP reused\n'
    emit_endpoint
    exit 0
  fi
fi
if [ "$forceRestart" = 1 ] || [ "$active" = active ]; then
  action=restart
else
  action=start
fi
if ! systemctl --user "$action" -- "$unit"; then
  log=$(journal)
  tail_log
  exit 1
fi
# Journal persists across restarts; only accept the new service invocation.
invocation=$(systemctl --user show -p InvocationID --value -- "$unit") || exit 1
if [ -z "$invocation" ]; then
  log=$(journal)
  tail_log
  printf 'DSHAPP log systemctl did not report InvocationID\n'
  exit 1
fi
i=0
while :; do
  log=$(journal) || exit 1
  read_state || { tail_log; exit 1; }
  if [ "$active" != active ] && [ "$active" != activating ]; then
    printf 'DSHAPP log service state: %s/%s\n' "$active" "$sub"
    tail_log
    exit 1
  fi
  launch_line
  if [ "$active" = active ] && [ -n "$line" ]; then
    emit_endpoint
    exit 0
  fi
  if [ "$i" -ge "$seconds" ]; then
    printf 'DSHAPP timeout\n'
    tail_log
    exit 1
  fi
  sleep 1
  i=$((i+1))
done
''';
}
