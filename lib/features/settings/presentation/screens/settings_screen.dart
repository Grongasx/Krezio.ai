import 'package:flutter/material.dart';
import '../../../../core/theme/krezio_theme.dart';
import '../../../../core/repositories/financial_repository.dart';

class SettingsScreen extends StatelessWidget {
  final FinancialRepository repository;
  final bool isDark;
  final VoidCallback onToggleTheme;

  const SettingsScreen({
    super.key,
    required this.repository,
    required this.isDark,
    required this.onToggleTheme,
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
                      'Privacidade & IA 100% On-Device',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: primaryTextColor),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Todos os seus dados financeiros, inferências de NLP e processamento de voz acontecem exclusivamente no seu dispositivo. Nenhum dado financeiro é compartilhado ou enviado para servidores externos.',
                  style: TextStyle(fontSize: 12, height: 1.4, color: secondaryTextColor),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

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
                            onPressed: () {
                              for (final tx in repository.transactions.toList()) {
                                repository.deleteTransaction(tx.id);
                              }
                              Navigator.of(ctx).pop();
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
