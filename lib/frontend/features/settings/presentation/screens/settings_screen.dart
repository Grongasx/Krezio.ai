import 'package:flutter/material.dart';
import '../widgets/settings_sections.dart';
import '../../../security/biometric_auth.dart';
import '../../../../../backend/services/pin_lock.dart';
import '../../../../../backend/services/pin_store_prefs.dart';
import '../../../accounts/presentation/screens/accounts_screen.dart';
import '../../../reminders/presentation/screens/open_items_screen.dart';
import '../../../../theme/krezio_theme.dart';
import '../../../../widgets/krezio_components.dart';
import '../../../../../backend/repositories/financial_repository.dart';
import '../../../../../backend/config/app_environment.dart';
import '../../../../../backend/config/app_version.dart';
import '../../../../../backend/services/auth_service.dart';
import '../../../../../ai/local_nlp_engine.dart';
import '../../../homologation/presentation/screens/neural_inspector_screen.dart';

class SettingsScreen extends StatelessWidget {
  final FinancialRepository repository;
  final LocalFinancialNlpEngine? engine;
  final bool isDark;
  final VoidCallback onToggleTheme;

  /// Signed-in account's e-mail, or null when running without Firebase (e.g.
  /// before `flutterfire configure` has been run) or before the app decided
  /// to require login at all.
  final String? userEmail;
  final SignOutAction? onSignOut;
  final Future<void> Function()? onClearData;
  final Future<void> Function()? onExportLegacy;
  final VoidCallback? onExploreDemo;
  final bool isDemo;

  /// Deletes the signed-in account and its cloud data (null without an account).
  final Future<void> Function()? onDeleteAccount;

  const SettingsScreen({
    super.key,
    required this.repository,
    this.engine,
    required this.isDark,
    required this.onToggleTheme,
    this.userEmail,
    this.onSignOut,
    this.onDeleteAccount,
    this.onClearData,
    this.onExportLegacy,
    this.onExploreDemo,
    this.isDemo = false,
  });

  Future<void> _confirmSignOut(BuildContext context) async {
    final keep = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Sair da conta?'),
        content: const Text('Só esta conta pode reabrir uma cópia mantida no aparelho.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Remover deste aparelho')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Manter neste aparelho')),
        ],
      ),
    );
    if (keep == null || !context.mounted) return;
    try {
      await onSignOut!(keepData: keep, skipSync: false);
    } on SignOutSyncFailure {
      if (!context.mounted) return;
      final retry = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Sincronização indisponível'),
          content: const Text('Você pode tentar sincronizar ou sair mantendo a cópia neste aparelho.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Cancelar')),
            TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Sair e manter')),
            FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Tentar de novo')),
          ],
        ),
      );
      if (!context.mounted) return;
      if (retry == true) {
        await _confirmSignOut(context);
      } else if (retry == false) {
        try {
          await onSignOut!(keepData: true, skipSync: true);
        } catch (_) {
          if (context.mounted) _signOutError(context);
        }
      }
    } catch (_) {
      if (context.mounted) _signOutError(context);
    }
  }

  void _signOutError(BuildContext context) => ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Não foi possível sair da conta.')),
  );

  @override
  Widget build(BuildContext context) {
    final bgSurface = isDark ? KrezioColors.darkSurface : KrezioColors.lightSurface;
    final borderColor = isDark ? KrezioColors.darkBorder : KrezioColors.lightBorder;
    final primaryTextColor = isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText;
    final secondaryTextColor = isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: isDark ? KrezioColors.darkBackground : KrezioColors.lightBackground,
        elevation: 0,
        title: Text(
          'Configurações',
          style: TextStyle(fontSize: KrezioFont.title, fontWeight: FontWeight.bold, color: primaryTextColor),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(KrezioSpace.lg),
        children: [
          ProfileSection(repository: repository),
          AppearanceSection(repository: repository),
          NotificationsSection(repository: repository),
          const VoiceSection(),
          if (!isDemo) ...[
            SecuritySection(lock: PinLock(PrefsPinStore()), biometric: BiometricAuth()),
            PrivacySection(
              repository: repository,
              userEmail: userEmail,
              onDeleteAccount: onDeleteAccount,
              onClearData: onClearData,
              onExportLegacy: onExportLegacy,
            ),
            ToolsSection(repository: repository),
          ],
          if (onExploreDemo != null)
            ListTile(
              leading: const Icon(Icons.science_outlined),
              title: const Text('Explorar com exemplos'),
              onTap: onExploreDemo,
            ),

          // Money: accounts and open bills/debtors
          KrezioCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.account_balance_wallet_outlined, color: KrezioColors.aiPurple),
                  title: const Text('Contas e carteiras'),
                  subtitle: const Text('Saldo por conta e fatura do cartão'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => AccountsScreen(repository: repository, isDark: isDark)),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.receipt_long, color: KrezioColors.aiPurple),
                  title: const Text('Lembretes e Contas a Receber'),
                  subtitle: const Text('Contas em aberto e quem te deve'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => OpenItemsScreen(repository: repository, isDark: isDark)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: KrezioSpace.lg),

          ListTile(
            title: const Text('Versão do app'),
            trailing: Text(AppVersion.label),
            onTap: () async {
              if (!EnvironmentConfig.registerEasterEggTap()) return;
              final confirm = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Row(
                    children: [
                      Icon(Icons.hub_outlined, color: KrezioColors.aiPurple),
                      SizedBox(width: 8),
                      Expanded(child: Text('Modo de Homologação')),
                    ],
                  ),
                  content: const Text(
                    'Você ativou o easter egg de engenharia (5 cliques na versão do app)!\n\n'
                    'Deseja habilitar o Modo de Homologação e o Visualizador da Rede Neural nesta sessão?',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancelar'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Ativar Homologação'),
                    ),
                  ],
                ),
              );
              if (confirm != true || !context.mounted) return;
              EnvironmentConfig.setEnvironment(AppEnvironment.homologation);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Modo de Homologação ativado com sucesso! 🧠')),
              );
            },
          ),
          // Homologation & Neural Inspector Card
          ValueListenableBuilder<AppEnvironment>(
            valueListenable: EnvironmentConfig.environmentNotifier,
            builder: (context, currentEnv, _) {
              final isHomolog = currentEnv == AppEnvironment.homologation;
              if (!EnvironmentConfig.canToggle) return const SizedBox.shrink();

              return Container(
                padding: const EdgeInsets.all(KrezioSpace.lg),
                decoration: BoxDecoration(
                  color: bgSurface,
                  borderRadius: KrezioTheme.borderRadius,
                  border: Border.all(
                    color: isHomolog ? KrezioColors.aiPurple.withOpacity(0.5) : borderColor,
                    width: isHomolog ? 1.5 : 1.0,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.hub_outlined,
                              color: isHomolog ? KrezioColors.aiPurple : secondaryTextColor,
                            ),
                            const SizedBox(width: KrezioSpace.md),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Modo de Homologação',
                                  style: TextStyle(
                                    fontSize: KrezioFont.body,
                                    fontWeight: FontWeight.bold,
                                    color: primaryTextColor,
                                  ),
                                ),
                                Text(
                                  isHomolog
                                      ? 'Ambiente de Testes / Staging Ativo'
                                      : 'Ambiente de Produção Padrão',
                                  style: TextStyle(
                                    fontSize: KrezioFont.small,
                                    color: isHomolog ? KrezioColors.aiPurple : secondaryTextColor,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        Switch(
                          value: isHomolog,
                          activeColor: KrezioColors.aiPurple,
                          onChanged: (_) => EnvironmentConfig.toggleEnvironment(),
                        ),
                      ],
                    ),
                    if (isHomolog) ...[
                      const SizedBox(height: KrezioSpace.md),
                      const Divider(height: 1),
                      const SizedBox(height: KrezioSpace.md),
                      Text(
                        'O modo de homologação ativa o inspetor visual transparente da rede neural e auditoria on-device de inferências.',
                        style: TextStyle(fontSize: KrezioFont.small, color: secondaryTextColor, height: 1.35),
                      ),
                      const SizedBox(height: KrezioSpace.md),
                      if (engine != null)
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: KrezioColors.aiPurple,
                              padding: const EdgeInsets.symmetric(vertical: KrezioSpace.md),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            icon: const Icon(Icons.auto_awesome, color: Colors.white, size: 18),
                            label: const Text(
                              'Abrir Visualizador da Rede Neural 🧠',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: KrezioFont.bodySmall,
                              ),
                            ),
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => NeuralInspectorScreen(
                                    engine: engine!,
                                    isDark: isDark,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: KrezioSpace.lg),

          // Privacy & AI Info Card
          KrezioCard(
            padding: const EdgeInsets.all(KrezioSpace.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.security, color: KrezioColors.emeraldGreen, size: 20),
                    const SizedBox(width: KrezioSpace.sm),
                    Text(
                      'Privacidade e César',
                      style: TextStyle(fontSize: KrezioFont.body, fontWeight: FontWeight.bold, color: primaryTextColor),
                    ),
                  ],
                ),
                const SizedBox(height: KrezioSpace.sm),
                Text(
                  userEmail != null
                      ? 'O César interpreta comandos no aparelho. A fala usa os recursos da plataforma. Os lançamentos são sincronizados com a sua conta.'
                      : 'O César interpreta comandos no aparelho. A fala usa os recursos da plataforma. Os lançamentos ficam neste aparelho.',
                  style: TextStyle(fontSize: KrezioFont.small, height: 1.4, color: secondaryTextColor),
                ),
              ],
            ),
          ),
          const SizedBox(height: KrezioSpace.lg),

          if (userEmail != null) ...[
            KrezioCard(
              padding: const EdgeInsets.all(KrezioSpace.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Conta',
                    style: TextStyle(fontSize: KrezioFont.body, fontWeight: FontWeight.bold, color: primaryTextColor),
                  ),
                  const SizedBox(height: KrezioSpace.md),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.account_circle_outlined, color: KrezioColors.aiPurple),
                    title: Text(userEmail!, style: TextStyle(fontSize: KrezioFont.bodySmall, color: primaryTextColor)),
                    subtitle: Text('Dados sincronizados nesta conta', style: TextStyle(fontSize: KrezioFont.caption, color: secondaryTextColor)),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.logout, color: KrezioColors.friendlyOrange),
                    title: const Text('Sair da Conta', style: TextStyle(fontSize: KrezioFont.bodySmall, color: KrezioColors.friendlyOrange)),
                    onTap: onSignOut == null
                        ? null
                        : () => _confirmSignOut(context),
                  ),
                ],
              ),
            ),
            const SizedBox(height: KrezioSpace.lg),
          ],

        ],
      ),
    );
  }
}
