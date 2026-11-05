import 'dart:io';

import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/ssh/remote_shell.dart';
import 'package:dsh_app/remote/systemd/dsh_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _systemctl = r'''#!/bin/sh
printf 'systemctl' >> "$HOME/argv"
printf ' <%s>' "$@" >> "$HOME/argv"
printf '\n' >> "$HOME/argv"
[ "$1" = --user ] || exit 2
shift
case "$1" in
  cat)
    if [ "$MODE" = missing ]; then
      echo 'Unit dsh-web.service could not be found.' >&2
      exit 1
    fi
    echo '# unit file'
    ;;
  show)
    case "$3" in
      ActiveState) cat "$HOME/state" ;;
      SubState)
        case "$(cat "$HOME/state")" in
          active) echo running ;;
          *) echo dead ;;
        esac
        ;;
      MainPID) echo 4242 ;;
      InvocationID) echo new-invocation ;;
      *) exit 2 ;;
    esac
    ;;
  start|restart)
    if [ "$MODE" = bus ]; then
      echo "${BUS_ERROR:-Failed to connect to user scope bus: No medium found}" >&2
      exit 1
    fi
    if [ "$MODE" = start-failure ]; then
      echo 'Job failed; consult journal' >&2
      exit 1
    fi
    echo active > "$HOME/state"
    echo 0 > "$HOME/polls"
    if [ "$MODE" = crash ]; then echo failed > "$HOME/state"; fi
    ;;
  stop)
    if [ "$MODE" = stop-failure ]; then echo 'Access denied' >&2; exit 1; fi
    echo inactive > "$HOME/state"
    ;;
  *) exit 2 ;;
esac
''';

const _journalctl = r'''#!/bin/sh
printf 'journalctl' >> "$HOME/argv"
printf ' <%s>' "$@" >> "$HOME/argv"
printf '\n' >> "$HOME/argv"
if [ "$MODE" = journal-failure ]; then echo 'Journal unavailable' >&2; exit 1; fi
polls=$(cat "$HOME/polls")
polls=$((polls+1))
echo "$polls" > "$HOME/polls"
scoped=0
for arg in "$@"; do
  [ "$arg" = _SYSTEMD_INVOCATION_ID=new-invocation ] && scoped=1
done
if [ "$scoped" = 0 ] && [ "$MODE" != no-token ] && [ "$MODE" != no-token-once ]; then
  echo 'dsh web: http://127.0.0.1:3000/?token=old-token'
fi
echo 'DSHAPP pid 1'
echo 'startup diagnostic'
case "$MODE" in
  silent|no-token|start-failure) exit 0 ;;
  crash) echo 'EACCES during startup: token=secret+/=='; exit 0 ;;
  delayed|bus|missing) [ "$polls" -ge 2 ] || exit 0 ;;
esac
if [ "$MODE" = no-token-once ] && [ "$scoped" = 0 ]; then exit 0; fi
printf '%s\n' "${LAUNCH_LINE:-dsh web: http://127.0.0.1:41234/?token=launch-tok}"
''';

void main() {
  late Directory home;
  late Map<String, String> env;

  setUp(() {
    home = Directory.systemTemp.createTempSync('dsh-service-test-');
    final bin = Directory('${home.path}/bin')..createSync();
    for (final entry in {'systemctl': _systemctl, 'journalctl': _journalctl, 'sleep': '#!/bin/sh\nexit 0\n'}.entries) {
      final file = File('${bin.path}/${entry.key}')..writeAsStringSync(entry.value);
      final result = Process.runSync('chmod', ['+x', file.path]);
      expect(result.exitCode, 0);
    }
    File('${home.path}/state').writeAsStringSync('inactive\n');
    File('${home.path}/polls').writeAsStringSync('0\n');
    env = {'HOME': home.path, 'PATH': '${bin.path}:${Platform.environment['PATH']}'};
  });

  tearDown(() => home.deleteSync(recursive: true));

  DshService service({String mode = 'fast', String unit = 'dsh-web', Map<String, String> extra = const {}}) =>
      DshService(
        LocalProcessShell(environment: {...env, 'MODE': mode, ...extra}),
        unit: unit,
        workingDirectory: '~/code',
        startTimeout: const Duration(seconds: 2),
      );

  List<String> argv() => File('${home.path}/argv').readAsLinesSync();
  TypeMatcher<HostLinkError> kind(HostLinkErrorKind value) => isA<HostLinkError>().having((e) => e.kind, 'kind', value);

  test('active service reuses the last token URL and its port', () async {
    File('${home.path}/state').writeAsStringSync('active\n');
    final endpoint = await service().ensureRunning();
    expect(endpoint.reused, isTrue);
    expect(endpoint.port, 41234);
    expect(endpoint.token, 'launch-tok');
    expect(endpoint.pid, 4242);
    expect(endpoint.home, home.path);
    expect(endpoint.authority, '127.0.0.1:41234');
    expect(service().resolvedWorkingDirectory(endpoint.home), '${home.path}/code');
    expect(argv().where((line) => line.contains('<start>') || line.contains('<restart>')), isEmpty);
  });

  test('inactive service starts and polls until the current invocation has a token', () async {
    final endpoint = await service(mode: 'delayed').ensureRunning();
    expect(endpoint.reused, isFalse);
    expect(endpoint.token, 'launch-tok');
    expect(endpoint.port, 41234);
    expect(int.parse(File('${home.path}/polls').readAsStringSync()), 2);
    expect(argv(), contains('systemctl <--user> <start> <--> <dsh-web.service>'));
    expect(argv().where((line) => line.startsWith('journalctl')), everyElement(contains('_SYSTEMD_INVOCATION_ID=')));
  });

  test('active service without a launch URL restarts exactly once', () async {
    File('${home.path}/state').writeAsStringSync('active\n');
    final endpoint = await service(mode: 'no-token-once', extra: {'LAUNCH_LINE': 'http://127.0.0.1:4567/?token=fresh'})
        .ensureRunning();
    expect(endpoint.reused, isFalse);
    expect(endpoint.token, 'fresh');
    expect(argv().where((line) => line.contains('<restart>')), hasLength(1));
  });

  test('forceRestart ignores an active service token', () async {
    File('${home.path}/state').writeAsStringSync('active\n');
    final endpoint = await service().ensureRunning(forceRestart: true);
    expect(endpoint.reused, isFalse);
    expect(argv().where((line) => line.contains('<restart>')), hasLength(1));
  });

  test('active service with no token restarts once and then times out', () async {
    File('${home.path}/state').writeAsStringSync('active\n');
    await expectLater(service(mode: 'no-token').ensureRunning(), throwsA(kind(HostLinkErrorKind.dshTimeout)));
    expect(argv().where((line) => line.contains('<restart>')), hasLength(1));
  });

  test('missing unit has a stable nonretryable error', () async {
    await expectLater(service(mode: 'missing').ensureRunning(), throwsA(kind(HostLinkErrorKind.unitNotFound)));
    expect(argv().where((line) => line.contains('<start>')), isEmpty);
  });

  for (final busError in ['Failed to connect to user scope bus', 'Failed to connect to bus']) {
    test('bus failure suggests enable-linger: $busError', () async {
      await expectLater(
        service(mode: 'bus', extra: {'BUS_ERROR': busError}).ensureRunning(),
        throwsA(
          kind(HostLinkErrorKind.serviceStartFailed)
              .having((e) => e.message, 'message', contains('loginctl enable-linger <user>')),
        ),
      );
    });
  }

  test('silent service times out with its journal tail', () async {
    await expectLater(
      service(mode: 'silent').ensureRunning(),
      throwsA(kind(HostLinkErrorKind.dshTimeout).having((e) => e.detail, 'detail', contains('startup diagnostic'))),
    );
  });

  test('process exit reports the journal and redacts complete tokens', () async {
    await expectLater(
      service(mode: 'crash').ensureRunning(),
      throwsA(
        kind(HostLinkErrorKind.serviceStartFailed)
            .having((e) => e.detail, 'detail', contains('EACCES'))
            .having((e) => e.detail, 'detail', isNot(contains('secret+/=='))),
      ),
    );
  });

  test('start failure reports both stderr and the journal tail', () async {
    await expectLater(
      service(mode: 'start-failure').ensureRunning(),
      throwsA(
        kind(HostLinkErrorKind.serviceStartFailed)
            .having((e) => e.detail, 'detail', contains('Job failed'))
            .having((e) => e.detail, 'detail', contains('startup diagnostic')),
      ),
    );
  });

  test('journal failure is reported instead of a timeout', () async {
    await expectLater(
      service(mode: 'journal-failure').ensureRunning(),
      throwsA(kind(HostLinkErrorKind.serviceStartFailed)),
    );
  });

  test('stop and restart pass normalized unit as a single argv', () async {
    final controller = service(unit: 'dsh:work_.@-1.service');
    await controller.stopService();
    await controller.restartService();
    expect(argv().where((line) => line.contains('<stop>') || line.contains('<restart>')), [
      'systemctl <--user> <stop> <--> <dsh:work_.@-1.service>',
      'systemctl <--user> <restart> <--> <dsh:work_.@-1.service>',
    ]);
  });

  test('failed stop is not silently ignored', () async {
    await expectLater(service(mode: 'stop-failure').stopService(), throwsA(kind(HostLinkErrorKind.serviceStartFailed)));
  });

  test('logTail uses the requested line count and redacts tokens', () async {
    final logs = await service().logTail(17);
    expect(logs, contains('startup diagnostic'));
    expect(logs, isNot(contains('launch-tok')));
    expect(logs, isNot(contains('old-token')));
    expect(argv().single, 'journalctl <--user> <-u> <dsh-web.service> <-o> <cat> <-n> <17> <--no-pager>');
  });

  for (final (line, port, token) in [
    ('dsh web: http://127.0.0.1:51234/?token=AbC.d_e~f-9', 51234, 'AbC.d_e~f-9'),
    ('ready https://localhost:4431/?mode=web&token=abc%2B123', 4431, 'abc+123'),
  ]) {
    test('parses token and port from $port', () async {
      final endpoint = await service(extra: {'LAUNCH_LINE': line}).ensureRunning();
      expect(endpoint.port, port);
      expect(endpoint.token, token);
    });
  }

  test('unit names reject empty, whitespace and shell metacharacters', () {
    for (final unit in ['', 'dsh web', 'dsh;id', 'dsh/web', 'dsh\nweb']) {
      expect(DshService.isValidUnit(unit), isFalse);
      expect(() => service(unit: unit), throwsArgumentError);
    }
    expect(DshService.normalizeUnit('dsh-web'), 'dsh-web.service');
    expect(DshService.normalizeUnit('dsh-web.service'), 'dsh-web.service');
  });
}
