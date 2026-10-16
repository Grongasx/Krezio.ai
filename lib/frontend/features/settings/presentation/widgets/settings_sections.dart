import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../../../../theme/krezio_theme.dart';
import '../../../../theme/theme_controller.dart';
import '../../../../widgets/krezio_components.dart';
import '../../../../../backend/repositories/financial_repository.dart';
import '../../../../../backend/services/data_export.dart';
import '../../../../../backend/services/pin_lock.dart';
import '../../../legal/legal_documents.dart';
import '../../../onboarding/onboarding_screen.dart';
import '../../../security/biometric_auth.dart';

/// A titled group of settings rows.
class SettingsGroup extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const SettingsGroup({super.key, required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: KrezioSpace.lg),
      child: KrezioCard(
        padding: const EdgeInsets.symmetric(vertical: KrezioSpace.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(KrezioSpace.lg, KrezioSpace.sm, KrezioSpace.lg, KrezioSpace.xs),
              child: Text(title, style: const TextStyle(fontSize: KrezioFont.body, fontWeight: FontWeight.bold)),
            ),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// Profile: the name César uses and the currency.
class ProfileSection extends StatefulWidget {
  final FinancialRepository repository;
  const ProfileSection({super.key, required this.repository});

  @override
  State<ProfileSection> createState() => _ProfileSectionState();
}

class _ProfileSectionState extends State<ProfileSection> {
  @override
  Widget build(BuildContext context) {
    final repository = widget.repository;
    final name = repository.preference(FinancialRepository.prefUserName);
    return SettingsGroup(title: 'Perfil', children: [
      ListTile(
        leading: const Icon(Icons.person_outline, color: KrezioColors.aiPurple),
        title: const Text('Como o César te chama'),
        subtitle: Text(name ?? 'Não definido'),
        trailing: const Icon(Icons.edit_outlined, size: 18),
        onTap: () async {
          final c = TextEditingController(text: name);
          await showKrezioFormDialog(
            context,
            title: 'Seu nome',
            confirmLabel: 'Salvar',
            fields: [KrezioTextField(controller: c, label: 'Nome', autofocus: true, textCapitalization: TextCapitalization.words)],
            onConfirm: () {
              final v = c.text.trim();
              repository.setPreference(FinancialRepository.prefUserName, v.isEmpty ? null : v);
              return true;
            },
          );
          if (mounted) setState(() {});
        },
      ),
      const ListTile(
        leading: Icon(Icons.payments_outlined, color: KrezioColors.aiPurple),
        title: Text('Moeda'),
        subtitle: Text('Real (R\$)'),
      ),
    ]);
  }
}

/// Light, dark or follow the system.
class AppearanceSection extends StatelessWidget {
  final FinancialRepository repository;
  const AppearanceSection({super.key, required this.repository});

  @override
  Widget build(BuildContext context) {
    return SettingsGroup(title: 'Aparência', children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.lg, vertical: KrezioSpace.sm),
        child: ValueListenableBuilder<ThemeMode>(
          valueListenable: ThemeController.mode,
          builder: (context, mode, _) => SegmentedButton<ThemeMode>(
            segments: [
              for (final m in const [ThemeMode.system, ThemeMode.light, ThemeMode.dark])
                ButtonSegment(value: m, label: Text(ThemeController.labelOf(m), style: const TextStyle(fontSize: KrezioFont.small))),
            ],
            selected: {mode},
            onSelectionChanged: (s) {
              ThemeController.mode.value = s.first;
              repository.setPreference(ThemeController.pref, ThemeController.nameOf(s.first));
            },
          ),
        ),
      ),
    ]);
  }
}

/// PIN, fingerprint/face and auto-lock.
class SecuritySection extends StatefulWidget {
  final PinLock lock;
  final BiometricAuth biometric;
  const SecuritySection({super.key, required this.lock, required this.biometric});

  @override
  State<SecuritySection> createState() => _SecuritySectionState();
}

class _SecuritySectionState extends State<SecuritySection> {
  bool _pinOn = false;
  bool _bioOn = false;
  bool _bioAvailable = false;
  Duration _after = const Duration(minutes: 1);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final pin = await widget.lock.isEnabled;
    final bio = await widget.lock.biometricsEnabled;
    final avail = await widget.biometric.available();
    final after = await widget.lock.autoLockAfter;
    if (mounted) {
      setState(() {
        _pinOn = pin;
        _bioOn = bio;
        _bioAvailable = avail;
        _after = after;
      });
    }
  }

  Future<bool> _askNewPin() async {
    final a = TextEditingController();
    final b = TextEditingController();
    String? error;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Criar PIN'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            KrezioTextField(controller: a, label: 'PIN (4 a 6 dígitos)', obscureText: true, keyboardType: TextInputType.number, autofocus: true),
            const SizedBox(height: KrezioSpace.sm),
            KrezioTextField(controller: b, label: 'Repita o PIN', obscureText: true, keyboardType: TextInputType.number, errorText: error),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(
              onPressed: () async {
                if (!PinLock.isValidPin(a.text)) return setLocal(() => error = 'Use de 4 a 6 números.');
                if (a.text != b.text) return setLocal(() => error = 'Os PINs não são iguais.');
                await widget.lock.setPin(a.text, b.text);
                if (ctx.mounted) Navigator.pop(ctx, true);
              },
              child: const Text('Salvar'),
            ),
          ],
        ),
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    return SettingsGroup(title: 'Segurança', children: [
      SwitchListTile(
        secondary: const Icon(Icons.pin_outlined, color: KrezioColors.aiPurple),
        title: const Text('Bloquear com PIN'),
        subtitle: const Text('Pede o PIN ao abrir o app'),
        value: _pinOn,
        onChanged: (on) async {
          if (on) {
            if (await _askNewPin()) setState(() => _pinOn = true);
          } else {
            await widget.lock.disable();
            setState(() {
              _pinOn = false;
              _bioOn = false;
            });
          }
        },
      ),
      if (_pinOn) ...[
        ListTile(
          leading: const Icon(Icons.password, color: KrezioColors.aiPurple),
          title: const Text('Trocar PIN'),
          onTap: _askNewPin,
        ),
        if (_bioAvailable)
          SwitchListTile(
            secondary: const Icon(Icons.fingerprint, color: KrezioColors.aiPurple),
            title: const Text('Desbloquear com digital ou rosto'),
            subtitle: const Text('O PIN continua valendo'),
            value: _bioOn,
            onChanged: (on) async {
              if (on && !await widget.biometric.authenticate()) return;
              await widget.lock.setBiometrics(on);
              setState(() => _bioOn = on);
            },
          ),
        ListTile(
          leading: const Icon(Icons.timer_outlined, color: KrezioColors.aiPurple),
          title: const Text('Bloquear depois de sair do app'),
          trailing: DropdownButton<int>(
            value: _after.inSeconds,
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem(value: 0, child: Text('Na hora')),
              DropdownMenuItem(value: 60, child: Text('1 minuto')),
              DropdownMenuItem(value: 300, child: Text('5 minutos')),
              DropdownMenuItem(value: 900, child: Text('15 minutos')),
            ],
            onChanged: (v) async {
              if (v == null) return;
              await widget.lock.setAutoLockAfter(Duration(seconds: v));
              setState(() => _after = Duration(seconds: v));
            },
          ),
        ),
      ],
    ]);
  }
}

/// Terms, privacy policy, export, and deleting the account or the data.
class PrivacySection extends StatelessWidget {
  final FinancialRepository repository;
  final String? userEmail;
  final Future<void> Function()? onDeleteAccount;

  const PrivacySection({super.key, required this.repository, this.userEmail, this.onDeleteAccount});

  Future<void> _export(BuildContext context) async {
    final now = DateTime.now();
    final base = DataExport.fileBase(now);
    final json = utf8.encode(DataExport.toJson(repository, now: now));
    final csv = utf8.encode(DataExport.transactionsCsv(repository));
    try {
      await SharePlus.instance.share(ShareParams(
        title: 'Meus dados do Krezio.ai',
        files: [
          XFile.fromData(json, mimeType: 'application/json', name: '$base.json'),
          XFile.fromData(csv, mimeType: 'text/csv', name: '$base-lancamentos.csv'),
        ],
        fileNameOverrides: ['$base.json', '$base-lancamentos.csv'],
      ));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Não foi possível exportar: $e')));
      }
    }
  }

  Future<void> _delete(BuildContext context) async {
    final account = onDeleteAccount != null;
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(account ? 'Excluir minha conta' : 'Apagar todos os dados'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(account
                ? 'Isso apaga a sua conta ($userEmail) e todos os seus dados na nuvem e neste aparelho. Não dá para desfazer.'
                : 'Isso apaga todos os lançamentos, contas, metas e preferências deste aparelho. Não dá para desfazer.'),
            const SizedBox(height: KrezioSpace.md),
            const Text('Para confirmar, digite EXCLUIR:'),
            TextField(controller: c, autofocus: true, onChanged: (_) => setLocal(() {})),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: KrezioColors.budgetOver),
              onPressed: c.text.trim() == 'EXCLUIR' ? () => Navigator.pop(ctx, true) : null,
              child: const Text('Excluir'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      if (account) await onDeleteAccount!();
      await repository.clearAllData();
      repository.setPreference(OnboardingScreen.donePref, null);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pronto, tudo foi apagado.')));
      }
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final accepted = repository.preference(LegalDocuments.acceptedPref);
    String? acceptedLabel;
    if (accepted != null && accepted.contains('|')) {
      final d = DateTime.tryParse(accepted.split('|')[1]);
      if (d != null) acceptedLabel = 'Versão ${accepted.split('|')[0]} aceita em ${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
    }
    return SettingsGroup(title: 'Privacidade e dados', children: [
      ListTile(
        leading: const Icon(Icons.description_outlined, color: KrezioColors.aiPurple),
        title: const Text('Termos de uso'),
        subtitle: acceptedLabel != null ? Text(acceptedLabel) : null,
        onTap: () => LegalDocuments.open(context, title: 'Termos de uso', asset: LegalDocuments.termsAsset),
      ),
      ListTile(
        leading: const Icon(Icons.privacy_tip_outlined, color: KrezioColors.aiPurple),
        title: const Text('Política de privacidade'),
        onTap: () => LegalDocuments.open(context, title: 'Política de privacidade', asset: LegalDocuments.privacyAsset),
      ),
      ListTile(
        leading: const Icon(Icons.file_download_outlined, color: KrezioColors.aiPurple),
        title: const Text('Exportar meus dados'),
        subtitle: const Text('JSON completo e CSV dos lançamentos (abre no Excel)'),
        onTap: () => _export(context),
      ),
      ListTile(
        leading: const Icon(Icons.delete_forever_outlined, color: KrezioColors.budgetOver),
        title: Text(onDeleteAccount != null ? 'Excluir minha conta' : 'Apagar todos os dados',
            style: const TextStyle(color: KrezioColors.budgetOver)),
        onTap: () => _delete(context),
      ),
    ]);
  }
}
