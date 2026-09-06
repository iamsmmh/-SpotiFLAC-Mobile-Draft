import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotimusic/ecosystem/ecosystem.dart';
import 'package:spotimusic/providers/ecosystem_providers.dart';
import 'package:spotimusic/widgets/app_sliver_header.dart';
import 'package:spotimusic/widgets/settings_group.dart';

/// Account settings (Feature Group 1).
///
/// Honest by construction: the buttons are driven by
/// [AccountState.availableMethods], so with no backend adapter registered the
/// page explains the architecture instead of offering actions that cannot
/// work. Guest mode is always available and keeps the entire app usable.
class AccountPage extends ConsumerStatefulWidget {
  const AccountPage({super.key});

  @override
  ConsumerState<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends ConsumerState<AccountPage> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  String? _notice;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(
    Future<void> Function() action, {
    String success = 'Done',
  }) async {
    setState(() => _notice = null);
    try {
      await action();
      if (!mounted) return;
      setState(() => _notice = success);
    } catch (error) {
      if (!mounted) return;
      setState(() => _notice = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(accountStateProvider).value;
    final service = ref.watch(accountServiceProvider);
    final methods = state?.availableMethods ?? const <AuthMethod>{};
    final isBusy = state?.status.isBusy ?? false;
    final canUseEmail = methods.contains(AuthMethod.email);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: 'Account'),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SettingsGroup(
                    children: [
                      SettingsItem(
                        icon: state?.isAuthenticated == true
                            ? Icons.verified_user_outlined
                            : Icons.person_outline,
                        title: state?.user?.label ?? 'Not signed in',
                        subtitle: _statusLabel(state),
                      ),
                      SettingsItem(
                        icon: Icons.storage_outlined,
                        title: 'Backend',
                        subtitle: state?.backend.wireId ?? 'none',
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_notice != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        _notice!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (canUseEmail) ...[
                    SettingsGroup(
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 8,
                          ),
                          child: TextField(
                            controller: _email,
                            keyboardType: TextInputType.emailAddress,
                            decoration: const InputDecoration(
                              labelText: 'Email',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                          child: TextField(
                            controller: _password,
                            obscureText: true,
                            decoration: const InputDecoration(
                              labelText: 'Password',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            onPressed: isBusy
                                ? null
                                : () => _run(
                                    () => service.signInWithEmail(
                                      email: _email.text.trim(),
                                      password: _password.text,
                                    ),
                                    success: 'Signed in',
                                  ),
                            child: const Text('Sign in'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: isBusy
                                ? null
                                : () => _run(
                                    () => service.signUpWithEmail(
                                      email: _email.text.trim(),
                                      password: _password.text,
                                    ),
                                    success: 'Account created',
                                  ),
                            child: const Text('Create account'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                  SettingsGroup(
                    children: [
                      if (methods.contains(AuthMethod.google))
                        SettingsItem(
                          icon: Icons.login,
                          title: 'Continue with Google',
                          subtitle: 'OAuth browser flow, ID token exchange',
                          onTap: isBusy ? null : () => _startOAuth(
                            service,
                            AuthMethod.google,
                          ),
                        ),
                      if (methods.contains(AuthMethod.apple))
                        SettingsItem(
                          icon: Icons.apple,
                          title: 'Continue with Apple',
                          subtitle: 'Sign in with Apple (web flow on Android)',
                          onTap: isBusy ? null : () => _startOAuth(
                            service,
                            AuthMethod.apple,
                          ),
                        ),
                      SettingsItem(
                        icon: Icons.person_outlined,
                        title: 'Continue as guest',
                        subtitle: 'Local profile — no account, no network',
                        onTap: isBusy
                            ? null
                            : () => _run(
                                service.continueAsGuest,
                                success: 'Guest session started',
                              ),
                      ),
                      if (state?.isSignedIn == true)
                        SettingsItem(
                          icon: Icons.logout,
                          title: 'Sign out',
                          subtitle: 'Clears stored tokens from the keystore',
                          onTap: () => _run(
                            service.signOut,
                            success: 'Signed out',
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'Tokens are stored in the platform keystore '
                      '(Android EncryptedSharedPreferences / iOS Keychain) and '
                      'never in plain preferences. Firebase, Supabase and '
                      'self-hosted adapters implement the same port, so a '
                      'backend is a configuration change, not a rewrite.',
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

  Future<void> _startOAuth(AccountService service, AuthMethod method) async {
    final uri = await service.beginOAuth(
      method,
      redirectUri: 'spotimusic://oauth',
    );
    if (uri == null) {
      if (!mounted) return;
      setState(
        () => _notice = 'This backend is not configured for ${method.name}.',
      );
      return;
    }
    if (!mounted) return;
    setState(
      () => _notice =
          'Open the consent URL to continue:\n$uri\n\n'
          'After approving, paste the redirect link back here.',
    );
    final controller = TextEditingController();
    final link = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Finish ${method.name} sign-in'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'spotimusic://oauth?…',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Sign in'),
          ),
        ],
      ),
    );
    if (link == null || link.isEmpty) return;
    final callback = Uri.tryParse(link);
    if (callback == null) return;
    await _run(
      () => service.completeOAuth(method, callback),
      success: 'Signed in with ${method.name}',
    );
  }

  static String _statusLabel(AccountState? state) {
    if (state == null) return 'Loading…';
    switch (state.status) {
      case AccountStatus.signedOut:
        return state.user == null
            ? 'No session'
            : 'Session expired — sign in again';
      case AccountStatus.signingIn:
        return 'Signing in…';
      case AccountStatus.guest:
        return 'Guest (local only)';
      case AccountStatus.signedIn:
        return 'Signed in';
      case AccountStatus.error:
        return state.errorMessage ?? 'Error';
    }
  }
}
