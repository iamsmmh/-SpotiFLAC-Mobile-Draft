import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/l10n/staged_strings.dart';
import 'package:spotiflac_android/providers/provider_accounts_provider.dart';
import 'package:spotiflac_android/widgets/app_sliver_header.dart';
import 'package:spotiflac_android/widgets/settings_group.dart';

/// Settings → Provider accounts.
///
/// Collects user-supplied streaming tokens (Tidal, Qobuz, Apple, Deezer,
/// Amazon) into encrypted storage. Stored values are never read back into
/// the UI — each field only reports whether a token exists.
///
/// NOTE(l10n): English-first while the surface stabilizes; staged for Crowdin
/// (see [StagedStrings]).
class ProviderAccountsPage extends ConsumerStatefulWidget {
  const ProviderAccountsPage({super.key});

  @override
  ConsumerState<ProviderAccountsPage> createState() =>
      _ProviderAccountsPageState();
}

class _ProviderAccountsPageState extends ConsumerState<ProviderAccountsPage> {
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, bool> _obscured = {};
  final Set<String> _saving = {};
  bool _loadScheduled = false;

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  TextEditingController _controllerFor(String credentialName) {
    return _controllers.putIfAbsent(
      credentialName,
      TextEditingController.new,
    );
  }

  Future<void> _save(ProviderAccountField field) async {
    final name = field.credentialName;
    final value = _controllerFor(name).text;
    if (value.trim().isEmpty || _saving.contains(name)) return;
    setState(() => _saving.add(name));
    try {
      await ref.read(providerAccountsProvider.notifier).save(name, value);
      _controllerFor(name).clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${field.label}: ${StagedStrings.providerAccountsSaved}',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not save ${field.label}: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving.remove(name));
    }
  }

  Future<void> _clear(ProviderAccountField field) async {
    final name = field.credentialName;
    if (_saving.contains(name)) return;
    setState(() => _saving.add(name));
    try {
      await ref.read(providerAccountsProvider.notifier).clear(name);
      _controllerFor(name).clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${field.label}: ${StagedStrings.providerAccountsCleared}',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not clear ${field.label}: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving.remove(name));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (!_loadScheduled) {
      _loadScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(providerAccountsProvider.notifier).load();
      });
    }
    final accountsState = ref.watch(providerAccountsProvider);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(
            title: StagedStrings.providerAccountsTitle,
          ),
          SliverToBoxAdapter(
            child: SettingsInfoCard(
              icon: Icons.key_rounded,
              message: StagedStrings.providerAccountsDescription,
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            ),
          ),
          if (!accountsState.loaded)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              ),
            )
          else ...[
            for (final account in providerAccounts)
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SettingsSectionHeader(title: account.providerLabel),
                    SettingsGroup(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                          child: Text(
                            account.description,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ),
                        for (final field in account.fields)
                          _CredentialField(
                            field: field,
                            controller: _controllerFor(field.credentialName),
                            configured: accountsState.isConfigured(
                              field.credentialName,
                            ),
                            saving: _saving.contains(field.credentialName),
                            obscured:
                                _obscured[field.credentialName] ?? true,
                            onToggleObscured: () => setState(() {
                              _obscured[field.credentialName] =
                                  !(_obscured[field.credentialName] ?? true);
                            }),
                            onSave: () => _save(field),
                            onClear: () => _clear(field),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                child: SettingsInfoCard(
                  icon: Icons.bolt_outlined,
                  message: StagedStrings.providerAccountsTestHint,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CredentialField extends StatelessWidget {
  const _CredentialField({
    required this.field,
    required this.controller,
    required this.configured,
    required this.saving,
    required this.obscured,
    required this.onToggleObscured,
    required this.onSave,
    required this.onClear,
  });

  final ProviderAccountField field;
  final TextEditingController controller;
  final bool configured;
  final bool saving;
  final bool obscured;
  final VoidCallback onToggleObscured;
  final VoidCallback onSave;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final statusColor = configured ? colorScheme.primary : colorScheme.outline;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  field.label,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(
                configured
                    ? Icons.check_circle_rounded
                    : Icons.circle_outlined,
                size: 16,
                color: statusColor,
              ),
              const SizedBox(width: 6),
              Text(
                configured
                    ? StagedStrings.providerAccountsConfigured
                    : StagedStrings.providerAccountsNotConfigured,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: statusColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  obscureText: obscured,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(
                    hintText: field.hint,
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    suffixIcon: IconButton(
                      tooltip: obscured ? 'Show token' : 'Hide token',
                      icon: Icon(
                        obscured
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: onToggleObscured,
                    ),
                  ),
                  onSubmitted: (_) => onSave(),
                ),
              ),
              const SizedBox(width: 8),
              Column(
                children: [
                  FilledButton.tonal(
                    onPressed: saving ? null : onSave,
                    child: saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(StagedStrings.providerAccountsSave),
                  ),
                  if (configured)
                    TextButton(
                      onPressed: saving ? null : onClear,
                      child: Text(StagedStrings.providerAccountsClear),
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
