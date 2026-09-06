import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/providers/cloud_providers.dart';
import 'package:spotiflac_android/widgets/app_sliver_header.dart';
import 'package:spotiflac_android/widgets/settings_group.dart';

/// SpotiFLAC Cloud onboarding + control page (Phase 3).
///
/// Connect a self-hosted SpotiFLAC Cloud deployment (the reference backend in
/// `backend/`), manage the account, devices, sync, and cloud backups. Plain
/// copy (not l10n) matches the ecosystem pages; the surfaces here are
/// honestly disabled until a server is configured.
class SpotiFlacCloudPage extends ConsumerStatefulWidget {
  const SpotiFlacCloudPage({super.key});

  @override
  ConsumerState<SpotiFlacCloudPage> createState() => _SpotiFlacCloudPageState();
}

class _SpotiFlacCloudPageState extends ConsumerState<SpotiFlacCloudPage> {
  final TextEditingController _serverController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _busy = false;
  String? _message;
  List<CloudDevice> _devices = const <CloudDevice>[];

  @override
  void initState() {
    super.initState();
    final server = ref.read(cloudServerConfigProvider);
    _serverController.text = server.baseUrl;
  }

  @override
  void dispose() {
    _serverController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() => _message = error.toString());
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect() => _guard(() async {
    await ref
        .read(cloudSyncUiStateProvider.notifier)
        .connectServer(_serverController.text);
    if (!mounted) return;
    setState(() => _message = 'Server connected.');
  });

  Future<void> _disconnect() => _guard(() async {
    await ref.read(cloudSyncUiStateProvider.notifier).disconnectServer();
    if (!mounted) return;
    setState(() {
      _message = 'Disconnected.';
      _devices = const <CloudDevice>[];
    });
  });

  Future<void> _signIn(bool create) => _guard(() async {
    final manager = ref.read(cloudAccountManagerProvider);
    final result = create
        ? await manager.signUp(
            email: _emailController.text.trim(),
            password: _passwordController.text,
            displayName: _emailController.text.trim().split('@').first,
          )
        : await manager.signIn(
            email: _emailController.text.trim(),
            password: _passwordController.text,
          );
    if (!result.ok) {
      if (mounted) setState(() => _message = result.error);
      return;
    }
    await manager.registerDevice(
      name: 'SpotiFLAC on ${Platform.operatingSystem}',
      platform: Platform.operatingSystem,
    );
    if (mounted) setState(() => _message = 'Signed in.');
  });

  Future<void> _signOut() => _guard(() async {
    await ref.read(cloudAccountManagerProvider).signOut();
    if (mounted) setState(() => _message = 'Signed out.');
  });

  Future<void> _loadDevices() => _guard(() async {
    final devices = await ref
        .read(cloudSyncUiStateProvider.notifier)
        .devices();
    if (mounted) setState(() => _devices = devices);
  });

  Future<void> _revokeDevice(String id) => _guard(() async {
    await ref.read(cloudSyncUiStateProvider.notifier).revokeDevice(id);
    await _loadDevices();
  });

  Future<void> _syncNow() => _guard(() async {
    final report = await ref
        .read(cloudSyncUiStateProvider.notifier)
        .syncNow();
    if (!mounted) return;
    setState(() {
      _message = report.ok
          ? 'Synced: ${report.pulled} pulled, ${report.pushed} pushed.'
          : 'Sync failed: ${report.error}';
    });
  });

  @override
  Widget build(BuildContext context) {
    final cloud = ref.watch(cloudSyncUiStateProvider);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: 'SpotiFLAC Cloud'),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SettingsGroup(
                    children: [
                      SettingsItem(
                        icon: cloud.configured
                            ? Icons.cloud_done_outlined
                            : Icons.cloud_off_outlined,
                        title: cloud.configured
                            ? 'Connected to ${cloud.server.base}'
                            : 'Not connected',
                        subtitle: cloud.signedIn
                            ? 'Signed in as ${cloud.userLabel ?? 'unknown'}'
                            : 'Connect a server, then sign in.',
                      ),
                      if (cloud.configured && cloud.signedIn)
                        SettingsItem(
                          icon: Icons.sync,
                          title: cloud.syncing ? 'Syncing…' : 'Sync now',
                          subtitle: cloud.queuedOperations > 0
                              ? '${cloud.queuedOperations} queued operation(s)'
                              : null,
                          onTap: cloud.syncing ? null : _syncNow,
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SettingsGroup(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: TextField(
                          controller: _serverController,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          enabled: !_busy,
                          decoration: const InputDecoration(
                            labelText: 'Server URL',
                            hintText: 'https://cloud.example.com',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Row(
                          children: [
                            TextButton(
                              onPressed: _busy ? null : _connect,
                              child: const Text('Connect'),
                            ),
                            if (cloud.configured)
                              TextButton(
                                onPressed: _busy ? null : _disconnect,
                                child: const Text('Disconnect'),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SettingsGroup(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: TextField(
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          autocorrect: false,
                          enabled: !_busy && cloud.configured,
                          decoration: const InputDecoration(
                            labelText: 'Email',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                        child: TextField(
                          controller: _passwordController,
                          obscureText: true,
                          autocorrect: false,
                          enableSuggestions: false,
                          enabled: !_busy && cloud.configured,
                          decoration: const InputDecoration(
                            labelText: 'Password',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Wrap(
                          spacing: 8,
                          children: [
                            TextButton(
                              onPressed:
                                  (_busy || !cloud.configured || cloud.signedIn)
                                  ? null
                                  : () => unawaited(_signIn(false)),
                              child: const Text('Sign in'),
                            ),
                            TextButton(
                              onPressed:
                                  (_busy || !cloud.configured || cloud.signedIn)
                                  ? null
                                  : () => unawaited(_signIn(true)),
                              child: const Text('Create account'),
                            ),
                            if (cloud.signedIn)
                              TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => unawaited(_signOut()),
                                child: const Text('Sign out'),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (cloud.signedIn) ...<Widget>[
                    const SizedBox(height: 12),
                    SettingsGroup(
                      children: [
                        SettingsItem(
                          icon: Icons.devices_other,
                          title: 'Devices',
                          subtitle:
                              'This device registers automatically on sign-in.',
                          onTap: _loadDevices,
                        ),
                        for (final device in _devices)
                          SettingsItem(
                            icon: Icons.phone_android,
                            title: device.name.isEmpty
                                ? device.id
                                : device.name,
                            subtitle: device.platform,
                            onTap: () => unawaited(_revokeDevice(device.id)),
                          ),
                      ],
                    ),
                  ],
                  if (_message != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                      child: Text(
                        _message!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  else
                    const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
