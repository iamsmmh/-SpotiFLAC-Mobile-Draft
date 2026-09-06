import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotimusic/ecosystem/ecosystem.dart';
import 'package:spotimusic/providers/music_servers_providers.dart';
import 'package:spotimusic/widgets/app_sliver_header.dart';
import 'package:spotimusic/widgets/settings_group.dart';

/// Self-hosted music servers (Jellyfin, Navidrome, Subsonic, Airsonic,
/// Plex).
///
/// Servers added here join the unified search engine and the streaming
/// engine's ranked source chain; their streams are cache-permitted by
/// default (they are the user's own files).
class ServersPage extends ConsumerStatefulWidget {
  const ServersPage({super.key});

  @override
  ConsumerState<ServersPage> createState() => _ServersPageState();
}

class _ServersPageState extends ConsumerState<ServersPage> {
  bool _testing = false;

  @override
  Widget build(BuildContext context) {
    final servers = ref.watch(musicServersProvider);
    final registry = ref.watch(musicServerRegistryProvider);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(
            title: 'Music servers',
            actions: [
              IconButton(
                icon: const Icon(Icons.add),
                onPressed: _testing ? null : () => _addServer(context),
              ),
            ],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                'Connect Jellyfin, Navidrome, Subsonic, Airsonic or Plex. '
                'Servers appear in unified search and stream through the '
                'normal player with provider failover. Credentials stay in '
                'the device keystore.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          servers.when(
            data: (list) => SliverList.builder(
              itemCount: list.length,
              itemBuilder: (context, index) {
                final config = list[index];
                return SettingsGroup(
                  children: [
                    SettingsItem(
                      icon: _iconFor(config.kind),
                      title: config.effectiveName,
                      subtitle:
                          '${config.kind.label} · ${config.username.isEmpty ? 'no user' : config.username}'
                          '${config.enabled ? '' : ' · disabled'}',
                      onTap: () => _serverSheet(context, config),
                    ),
                  ],
                );
              },
            ),
            loading: () => const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
            error: (error, _) => SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('$error'),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '${registry.providers.length} configured · '
                '${registry.enabledProviders.length} enabled',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static IconData _iconFor(MusicServerKind kind) => switch (kind) {
    MusicServerKind.jellyfin => Icons.movie_filter_outlined,
    MusicServerKind.navidrome => Icons.library_music_outlined,
    MusicServerKind.subsonic => Icons.graphic_eq_outlined,
    MusicServerKind.airsonic => Icons.speaker_outlined,
    MusicServerKind.plex => Icons.dns_outlined,
  };

  Future<void> _addServer(BuildContext context) async {
    final form = await _serverForm(context, null);
    if (form == null || !mounted) return;
    final (config, password) = form;
    setState(() => _testing = true);
    final registry = ref.read(musicServerRegistryProvider);
    await registry.add(config);

    // Credential bootstrap per back-end dialect. Failures leave the config
    // in place (editable) with the error surfaced.
    String? error;
    try {
      final secrets = ref.read(musicServerSecretStoreProvider);
      if (password.isNotEmpty) {
        if (config.kind.isSubsonicFamily) {
          await secrets.setPassword(config.id, password);
        } else if (config.kind == MusicServerKind.plex) {
          final looksLikeToken =
              password.length >= 16 && !password.contains(' ');
          if (looksLikeToken) {
            await secrets.setToken(config.id, password);
          } else {
            final provider = registry.byId(config.id);
            if (provider is PlexProvider) {
              await provider.signIn(config.username, password);
            }
          }
        } else if (config.kind == MusicServerKind.jellyfin) {
          final provider = registry.byId(config.id);
          if (provider is JellyfinProvider) {
            await provider.signIn(password);
          }
        }
      }
      final provider = registry.byId(config.id);
      error = provider == null ? 'not found' : await provider.testConnection();
    } on MusicServerException catch (exception) {
      error = exception.message;
    }

    if (!mounted || !context.mounted) return;
    setState(() => _testing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          error == null
              ? '${config.effectiveName} connected'
              : 'Added, but the connection test failed: $error',
        ),
      ),
    );
    ref.invalidate(musicServersProvider);
  }

  Future<void> _serverSheet(BuildContext context, MusicServerConfig config) {
    return showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit'),
              onTap: () async {
                final edited = await _serverForm(context, config);
                if (edited != null) {
                  await ref
                      .read(musicServerRegistryProvider)
                      .update(edited.$1);
                  ref.invalidate(musicServersProvider);
                }
                if (sheetContext.mounted) Navigator.of(sheetContext).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.wifi_tethering),
              title: const Text('Test connection'),
              onTap: () async {
                final provider = ref
                    .read(musicServerRegistryProvider)
                    .byId(config.id);
                final error = provider == null
                    ? 'not found'
                    : await provider.testConnection();
                if (sheetContext.mounted) {
                  ScaffoldMessenger.of(sheetContext).showSnackBar(
                    SnackBar(
                      content: Text(
                        error == null
                            ? '${config.effectiveName} answered OK'
                            : 'Connection failed: $error',
                      ),
                    ),
                  );
                  Navigator.of(sheetContext).pop();
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Remove'),
              onTap: () async {
                await ref.read(musicServerRegistryProvider).remove(config.id);
                ref.invalidate(musicServersProvider);
                if (sheetContext.mounted) Navigator.of(sheetContext).pop();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<(MusicServerConfig, String)?> _serverForm(
    BuildContext context,
    MusicServerConfig? existing,
  ) {
    final kindController = ValueNotifier<MusicServerKind>(
      existing?.kind ?? MusicServerKind.jellyfin,
    );
    final nameController = TextEditingController(
      text: existing?.displayName ?? '',
    );
    final urlController = TextEditingController(
      text: existing?.baseUrl ?? '',
    );
    final userController = TextEditingController(
      text: existing?.username ?? '',
    );
    final passwordController = TextEditingController();

    return showDialog<(MusicServerConfig, String)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'Add server' : 'Edit server'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    for (final kind in MusicServerKind.values)
                      ChoiceChip(
                        label: Text(kind.label),
                        selected: kindController.value == kind,
                        onSelected: (selected) {
                          if (!selected) return;
                          kindController.value = kind;
                          setDialogState(() {});
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: urlController,
                  decoration: const InputDecoration(
                    labelText: 'Base URL',
                    hintText: 'https://music.example.com',
                  ),
                  autocorrect: false,
                ),
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'Display name (optional)',
                  ),
                ),
                TextField(
                  controller: userController,
                  decoration: const InputDecoration(labelText: 'Username'),
                  autocorrect: false,
                ),
                TextField(
                  controller: passwordController,
                  decoration: InputDecoration(
                    labelText: switch (kindController.value) {
                      MusicServerKind.plex => 'X-Plex-Token (or password)',
                      _ => 'Password',
                    },
                  ),
                  obscureText: true,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final url = urlController.text.trim();
                final host = Uri.tryParse(url)?.host ?? '';
                if (url.isEmpty || host.isEmpty) {
                  return;
                }
                Navigator.of(dialogContext).pop(
                  (
                    existing == null
                        ? MusicServerConfig(
                            id: newMusicServerId(),
                            kind: kindController.value,
                            baseUrl: url,
                            displayName: nameController.text.trim(),
                            username: userController.text.trim(),
                          )
                        : existing.copyWith(
                            baseUrl: url,
                            displayName: nameController.text.trim(),
                            username: userController.text.trim(),
                          ),
                    passwordController.text,
                  ),
                );
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}
