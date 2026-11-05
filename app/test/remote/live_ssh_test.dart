// Live end-to-end: real dartssh2 → real sshd → real `dsh web`, through the
// local forward, logged in with DshClient. Opt-in:
//
//   DSH_APP_LIVE_SSH=1 \
//   DSH_APP_LIVE_SSH_PORT=22422 DSH_APP_LIVE_SSH_USER=$USER \
//   DSH_APP_LIVE_SSH_KEY=/path/to/throwaway_ed25519 \
//   DSH_APP_LIVE_SSH_HOST_PUB=/path/to/host_ed25519.pub \
//   DSH_APP_LIVE_SSH_UNIT=dsh-test DSH_APP_LIVE_SSH_CWD=/tmp/dsh-test-work \
//   flutter test test/remote/live_ssh_test.dart
//
// The SSH account must have a dedicated, preinstalled systemd user service.
// Set DSH_APP_LIVE_SSH_UNIT to its name and DSH_APP_LIVE_SSH_CWD to an
// existing absolute remote directory for test sessions. The service controls
// its own HOME and DSH_HOME. No model prompts are sent; the service stays up.

import 'dart:io';

import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/remote/ssh/ssh_link.dart';
import 'package:dsh_app/remote/ssh/ssh_transport.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final env = Platform.environment;
  final enabled = env['DSH_APP_LIVE_SSH'] == '1';
  final skip = enabled ? false : 'set DSH_APP_LIVE_SSH=1 (see file header)';

  late SshHostConfig config;
  late SshSecrets secrets;
  late String remoteCwd;
  final links = <SshHostLink>[];

  setUpAll(() {
    if (!enabled) return;
    remoteCwd = env['DSH_APP_LIVE_SSH_CWD']!;
    if (!remoteCwd.startsWith('/')) throw ArgumentError('DSH_APP_LIVE_SSH_CWD must be absolute');
    config = SshHostConfig(
      id: 'ssh-live',
      name: '本机 SSH',
      host: env['DSH_APP_LIVE_SSH_HOST'] ?? '127.0.0.1',
      port: int.parse(env['DSH_APP_LIVE_SSH_PORT'] ?? '22'),
      user: env['DSH_APP_LIVE_SSH_USER'] ?? env['USER']!,
      auth: SshAuthMethod.privateKey,
      unit: env['DSH_APP_LIVE_SSH_UNIT']!,
      workingDirectory: remoteCwd,
    );
    secrets = SshSecrets(privateKey: File(env['DSH_APP_LIVE_SSH_KEY']!).readAsStringSync());
  });

  tearDownAll(() async {
    if (!enabled) return;
    for (final link in links) {
      await link.close();
    }
  });

  SshHostLink link(SshHostConfig c, {HostKeyPrompter? prompt}) {
    final l = SshHostLink(
      config: c,
      loadSecrets: () async => secrets,
      promptHostKey: prompt,
      backoff: Backoff(initial: const Duration(milliseconds: 200), max: const Duration(seconds: 1), maxAttempts: 6),
    );
    links.add(l);
    return l;
  }

  test('host key preflight matches ssh-keygen', () async {
    final key = await fetchHostKey(config);
    final pub = env['DSH_APP_LIVE_SSH_HOST_PUB'];
    if (pub != null) {
      final expected = Process.runSync('ssh-keygen', ['-lf', pub]).stdout.toString().split(' ')[1];
      expect(key.fingerprint, expected);
    }
    expect(key.shortType, 'ED25519');
    config = config.copyWith(hostKeyType: () => key.type, hostKeyFingerprint: () => key.fingerprint);
  }, skip: skip);

  test(
    'connect: start dsh, tunnel, log in, list and create sessions',
    () async {
      final l = link(config);
      final steps = <HostLinkStep>{};
      l.statuses.listen((s) {
        if (s.step != null) steps.add(s.step!);
      });
      final sw = Stopwatch()..start();
      final client = await l.open().timeout(const Duration(seconds: 90));
      // ignore: avoid_print
      print('connected in ${sw.elapsedMilliseconds} ms; remote port ${l.endpoint!.port}, local ${l.localPort}');
      expect(steps, HostLinkStep.values.toSet());

      final before = await client.listSessions();
      final created = await client.createSession(cwd: l.resolvedWorkingDirectory);
      expect(l.resolvedWorkingDirectory, remoteCwd);
      final after = await client.listSessions();
      expect(after.map((s) => s.sessionId), contains(created.sessionId));
      expect(after.length, before.length + 1);
      // ignore: avoid_print
      print(
        'sessions: ${before.length} → ${after.length}; cwd ${after.firstWhere((s) => s.sessionId == created.sessionId).cwd}',
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a dropped SSH connection recovers and the same client keeps working',
    () async {
      final l = links.last;
      final client = l.currentClient!;
      l.debugDropTransport();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(l.status.phase, isNot(HostLinkPhase.connected));
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (!l.status.isConnected && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(l.status.isConnected, isTrue);
      expect(identical(l.currentClient, client), isTrue);
      final sessions = await client.listSessions().timeout(const Duration(seconds: 20));
      expect(sessions, isNotEmpty);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'second connection reuses the running dsh',
    () async {
      await links.last.close();
      final l = link(config);
      final client = await l.open().timeout(const Duration(seconds: 60));
      expect(l.endpoint!.reused, isTrue);
      expect(await client.listSessions(), isNotEmpty);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('a wrong pinned key fails closed', () async {
    final l = link(config.copyWith(hostKeyFingerprint: () => 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'));
    await expectLater(
      l.open(),
      throwsA(isA<HostLinkError>().having((e) => e.kind, 'kind', HostLinkErrorKind.hostKeyMismatch)),
    );
  }, skip: skip);

  test(
    'app state: active SSH host → HostConnection → new chat in the configured cwd',
    () async {
      SharedPreferences.setMockInitialValues({});
      final secrets = MemorySecretStore();
      final c = ProviderContainer(
        overrides: [
          secretStoreProvider.overrideWithValue(secrets),
          networkKicksProvider.overrideWithValue(const Stream.empty()),
          sshLinkFactoryProvider.overrideWithValue(
            (ref, cfg) => SshHostLink(
              config: cfg,
              loadSecrets: () => ref.read(hostsProvider.notifier).loadSecrets(cfg.id),
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      final hosts = c.read(hostsProvider.notifier);
      await hosts.ready;
      await hosts.saveSsh(
        config,
        secrets: SshSecrets(privateKey: File(env['DSH_APP_LIVE_SSH_KEY']!).readAsStringSync()),
      );
      c.read(activeHostProvider.notifier).select(HostRef.ssh(config.id));
      final sub = c.listen(activeConnectionProvider, (_, _) {});
      addTearDown(sub.close);
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (c.read(activeConnectionProvider).value == null && DateTime.now().isBefore(deadline)) {
        if (c.read(activeConnectionProvider).hasError) fail('${c.read(activeConnectionProvider).error}');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final conn = c.read(activeConnectionProvider).value!;
      expect(conn.label, '本机 SSH · SSH');
      expect(conn.workingDirectory, remoteCwd);

      final sessions = c.listen(sessionsProvider, (_, _) {});
      addTearDown(sessions.close);
      final id = await c.read(sessionsProvider.notifier).create();
      final listed = await conn.client.listSessions();
      expect(listed.firstWhere((s) => s.sessionId == id).cwd, remoteCwd);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('a rejected key is a clear auth error', () async {
    final other = Directory.systemTemp.createTempSync('dsh-app-live-key-');
    addTearDown(() => other.deleteSync(recursive: true));
    Process.runSync('ssh-keygen', ['-q', '-t', 'ed25519', '-N', '', '-f', '${other.path}/k']);
    final params = SshConnectParams(
      host: config.host,
      port: config.port,
      username: config.user,
      auth: SshAuthMethod.privateKey,
      secrets: SshSecrets(privateKey: File('${other.path}/k').readAsStringSync()),
    );
    await expectLater(
      DartSshTransport.connect(params, (_) => true),
      throwsA(isA<HostLinkError>().having((e) => e.kind, 'kind', HostLinkErrorKind.authFailed)),
    );
  }, skip: skip);
}
