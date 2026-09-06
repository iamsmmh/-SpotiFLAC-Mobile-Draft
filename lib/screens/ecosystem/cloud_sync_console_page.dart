import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotimusic/core/sync/sync_entities.dart';
import 'package:spotimusic/ecosystem/ecosystem.dart';
import 'package:spotimusic/providers/ecosystem_providers.dart';
import 'package:spotimusic/providers/sync_provider.dart';
import 'package:spotimusic/widgets/app_sliver_header.dart';
import 'package:spotimusic/widgets/settings_group.dart';

/// Cloud sync console (Feature Group 2).
///
/// Complements the existing Settings → Cloud sync page: this one exposes the
/// *engine* — scope selection, background scheduling, network policy, retry
/// state and the offline outbox — while the settings page keeps owning sign-in.
class CloudSyncConsolePage extends ConsumerStatefulWidget {
  const CloudSyncConsolePage({super.key});

  @override
  ConsumerState<CloudSyncConsolePage> createState() =>
      _CloudSyncConsolePageState();
}

class _CloudSyncConsolePageState extends ConsumerState<CloudSyncConsolePage> {
  late Set<SyncScope> _enabled;
  bool _background = false;
  bool _allowMetered = false;
  Duration _interval = const Duration(minutes: 15);
  String? _lastReport;

  @override
  void initState() {
    super.initState();
    _enabled = SyncScopeDescriptor.defaultEnabledScopes();
  }

  SyncEngine get _engine => ref.read(syncEngineProvider);

  void _applyPolicy() {
    _engine.updatePolicy(
      SyncPolicy(
        interval: _interval,
        allowMetered: _allowMetered,
        enabledScopes: _enabled,
      ),
    );
  }

  Future<void> _runCycle() async {
    final report = await _engine.runCycle(trigger: SyncTrigger.manual);
    if (!mounted) return;
    setState(() {
      _lastReport = report.skipped != null
          ? 'Skipped: ${report.skipped}'
          : 'Pushed ${report.pushedRecords}, pulled '
              '${report.pulledRecords}, resolved ${report.conflictsResolved} '
              'conflicts${report.error == null ? '' : ' (${report.error})'}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final stats = ref.watch(syncEngineStatsProvider).value;
    final snapshot = ref.watch(syncStateProvider);
    final backend = ref.watch(cloudSyncBackendProvider);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: 'Cloud sync'),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SettingsGroup(
                    children: [
                      SettingsItem(
                        icon: Icons.cloud_outlined,
                        title: 'Backend',
                        subtitle: backend.displayName,
                      ),
                      SettingsItem(
                        icon: Icons.pending_actions_outlined,
                        title: 'Pending outbox',
                        subtitle:
                            '${snapshot.pendingOutboxCount} records waiting',
                      ),
                      SettingsItem(
                        icon: Icons.sync_problem_outlined,
                        title: 'Engine',
                        subtitle: stats == null
                            ? 'idle'
                            : '${stats.cycles} cycles · '
                                  '${stats.totalPushedRecords} pushed · '
                                  '${stats.totalPulledRecords} pulled · '
                                  '${stats.totalConflictsResolved} conflicts',
                      ),
                      if (stats?.lastError != null)
                        SettingsItem(
                          icon: Icons.error_outline,
                          title: stats!.lastError!,
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: snapshot.status == SyncStatus.disabled
                              ? null
                              : _runCycle,
                          icon: const Icon(Icons.sync),
                          label: const Text('Sync now'),
                        ),
                      ),
                    ],
                  ),
                  if (_lastReport != null)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(_lastReport!),
                    ),
                  const SizedBox(height: 12),
                  SettingsGroup(
                    children: [
                      SwitchListTile(
                        title: const Text('Background sync'),
                        subtitle: const Text(
                          'Runs a cycle on the interval below while the app '
                          'is alive and on network changes',
                        ),
                        value: _background,
                        onChanged: (value) {
                          setState(() => _background = value);
                          if (value) {
                            _applyPolicy();
                            _engine.start();
                          } else {
                            _engine.stop();
                          }
                        },
                      ),
                      SwitchListTile(
                        title: const Text('Sync on metered networks'),
                        subtitle: const Text(
                          'Off by default: cellular and roaming links are '
                          'skipped',
                        ),
                        value: _allowMetered,
                        onChanged: (value) {
                          setState(() => _allowMetered = value);
                          _applyPolicy();
                        },
                      ),
                      ListTile(
                        title: const Text('Interval'),
                        trailing: DropdownButton<Duration>(
                          value: _interval,
                          items: const [
                            DropdownMenuItem<Duration>(
                              value: Duration(minutes: 5),
                              child: Text('5 minutes'),
                            ),
                            DropdownMenuItem<Duration>(
                              value: Duration(minutes: 15),
                              child: Text('15 minutes'),
                            ),
                            DropdownMenuItem<Duration>(
                              value: Duration(hours: 1),
                              child: Text('1 hour'),
                            ),
                          ],
                          onChanged: (value) {
                            if (value == null) return;
                            setState(() => _interval = value);
                            _applyPolicy();
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Scopes',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  SettingsGroup(
                    children: [
                      for (final descriptor in SyncScopeDescriptor.all)
                        CheckboxListTile(
                          title: Text(descriptor.title),
                          subtitle: Text(descriptor.description),
                          value: _enabled.contains(descriptor.scope),
                          onChanged: (value) {
                            setState(() {
                              if (value == true) {
                                _enabled.add(descriptor.scope);
                              } else {
                                _enabled.remove(descriptor.scope);
                              }
                            });
                            _applyPolicy();
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'Conflicts resolve deterministically: tombstones beat '
                      'live records, then newer timestamps win, then higher '
                      'revisions. Failed pushes stay in the outbox and are '
                      'retried with exponential backoff.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
