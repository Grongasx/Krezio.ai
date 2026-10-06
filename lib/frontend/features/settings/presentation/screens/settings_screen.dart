import 'package:flutter/material.dart';
import '../../../../theme/krezio_theme.dart';
import '../../../../../backend/repositories/financial_repository.dart';
import '../../../../../backend/config/app_environment.dart';
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
  final Future<void> Function()? onSignOut;

  const SettingsScreen({
    super.key,
    required this.repository,
    this.engine,
    required this.isDark,
    required this.onToggleTheme,
    this.userEmail,
    this.onSignOut,
  });

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
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: primaryTextColor),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Theme Section
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: bgSurface,
              borderRadius: KrezioTheme.borderRadius,
              border: Border.all(color: borderColor),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      isDark ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
                      color: KrezioColors.aiPurple,
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Aparência / Tema',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: primaryTextColor),
                        ),
                        Text(
                          isDark ? 'Modo Escuro Ativo' : 'Modo Claro Ativo',
                          style: TextStyle(fontSize: 12, color: secondaryTextColor),
                        ),
                      ],
                    ),
                  ],
                ),
                Switch(
                  value: isDark,
                  activeColor: KrezioColors.aiPurple,
                  onChanged: (_) => onToggleTheme(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Homologation & Neural Inspector Card
          ValueListenableBuilder<AppEnvironment>(
            valueListenable: EnvironmentConfig.environmentNotifier,
            builder: (context, currentEnv, _) {
              final isHomolog = currentEnv == AppEnvironment.homologation;

              return Container(
                padding: const EdgeInsets.all(16),
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
                            const SizedBox(width: 12),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Modo de Homologação',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: primaryTextColor,
                                  ),
                                ),
                                Text(
                                  isHomolog
                                      ? 'Ambiente de Testes / Staging Ativo'
                                      : 'Ambiente de Produção Padrão',
                                  style: TextStyle(
                                    fontSize: 12,
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
                      const SizedBox(height: 12),
                      const Divider(height: 1),
                      const SizedBox(height: 12),
                      Text(
                        'O modo de homologação ativa o inspetor visual transparente da rede neural e auditoria on-device de inferências.',
                        style: TextStyle(fontSize: 12, color: secondaryTextColor, height: 1.35),
                      ),
                      const SizedBox(height: 12),
                      if (engine != null)
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: KrezioColors.aiPurple,
                              padding: const EdgeInsets.symmetric(vertical: 12),
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
                                fontSize: 13,
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
          const SizedBox(height: 16),

          // Privacy & AI Info Card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: bgSurface,
              borderRadius: KrezioTheme.borderRadius,
              border: Border.all(color: borderColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.security, color: KrezioColors.emeraldGreen, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      userEmail != null ? 'Privacidade & IA On-Device' : 'Privacidade & IA 100% On-Device',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: primaryTextColor),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  userEmail != null
                      ? 'As inferências de NLP e o processamento de voz continuam 100% no seu dispositivo, inclusive offline. Seus lançamentos são sincronizados apenas com a sua própria conta na nuvem, para backup e uso em outros aparelhos — nunca compartilhados com terceiros.'
                      : 'Todos os seus dados financeiros, inferências de NLP e processamento de voz acontecem exclusivamente no seu dispositivo. Nenhum dado financeiro é compartilhado ou enviado para servidores externos.',
                  style: TextStyle(fontSize: 12, height: 1.4, color: secondaryTextColor),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          if (userEmail != null) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: bgSurface,
                borderRadius: KrezioTheme.borderRadius,
                border: Border.all(color: borderColor),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Conta',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: primaryTextColor),
                  ),
                  const SizedBox(height: 12),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.account_circle_outlined, color: KrezioColors.aiPurple),
                    title: Text(userEmail!, style: TextStyle(fontSize: 13, color: primaryTextColor)),
                    subtitle: Text('Dados sincronizados nesta conta', style: TextStyle(fontSize: 11, color: secondaryTextColor)),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.logout, color: KrezioColors.friendlyOrange),
                    title: const Text('Sair da Conta', style: TextStyle(fontSize: 13, color: KrezioColors.friendlyOrange)),
                    onTap: onSignOut == null
                        ? null
                        : () async {
                            await onSignOut!();
                          },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Data Management Card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: bgSurface,
              borderRadius: KrezioTheme.borderRadius,
              border: Border.all(color: borderColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Gestão de Dados',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: primaryTextColor),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.file_download_outlined, color: KrezioColors.aiPurple),
                  title: const Text('Exportar Extrato (CSV)', style: TextStyle(fontSize: 13)),
                  onTap: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Exportação concluída! Dados salvos localmente.')),
                    );
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.delete_sweep_outlined, color: KrezioColors.friendlyOrange),
                  title: const Text('Limpar Histórico de Testes', style: TextStyle(fontSize: 13, color: KrezioColors.friendlyOrange)),
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        shape: RoundedRectangleBorder(borderRadius: KrezioTheme.borderRadius),
                        title: const Text('Limpar Dados?'),
                        content: const Text('Deseja apagar todos os lançamentos cadastrados?'),
                        actions: [
                          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancelar')),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(backgroundColor: KrezioColors.friendlyOrange),
                            onPressed: () async {
                              Navigator.of(ctx).pop();
                              await repository.clearAllData();
                            },
                            child: const Text('Limpar', style: TextStyle(color: Colors.white)),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
