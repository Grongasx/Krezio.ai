import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'statement_file.dart';
import '../../../../theme/krezio_theme.dart';
import '../../../../theme/theme_controller.dart';
import '../../../../widgets/krezio_components.dart';
import '../../../../../backend/repositories/financial_repository.dart';
import '../../../../../backend/services/data_export.dart';
import '../../../../../backend/services/notification_service.dart';
import '../../../../../backend/services/tax_report.dart';
import '../../../import/import_statement_screen.dart';
import '../../../onboarding/onboarding_screen.dart';
import '../../../../../ai/voice/native_tts.dart';
import '../../../../../ai/voice/voice_synthesis_service.dart';
import '../../../../../backend/services/pin_lock.dart';
import '../../../legal/legal_documents.dart';
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
  final Future<void> Function()? onClearData;
  final Future<void> Function()? onExportLegacy;

  const PrivacySection({
    super.key,
    required this.repository,
    this.userEmail,
    this.onDeleteAccount,
    this.onClearData,
    this.onExportLegacy,
  });

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

  Future<void> _delete(BuildContext context, {required bool account}) async {
    final keyword = account ? 'EXCLUIR' : 'APAGAR';
    var confirmation = '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(account ? 'Excluir minha conta' : 'Apagar todos os dados'),
          scrollable: true,
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(account
                ? 'Isso apaga a sua conta ($userEmail) e todos os seus dados na nuvem e neste aparelho. Não dá para desfazer.'
                : 'Isso apaga lançamentos, contas, metas, lembretes, categorias personalizadas e preferências '
                  '${userEmail != null ? 'da conta na nuvem e deste aparelho. Seu login será mantido.' : 'deste aparelho.'}'),
            const SizedBox(height: KrezioSpace.md),
            Text('Para confirmar, digite $keyword'),
            TextField(autofocus: true, onChanged: (value) => setLocal(() => confirmation = value)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: KrezioColors.budgetOver),
              onPressed: confirmation.trim() == keyword ? () => Navigator.pop(ctx, true) : null,
              child: Text(account ? 'Excluir' : 'Apagar'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      if (account) {
        await onDeleteAccount!();
      } else {
        await (onClearData ?? repository.clearAllData)();
      }
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
      if (onExportLegacy != null)
        ListTile(
          leading: const Icon(Icons.restore_outlined),
          title: const Text('Exportar dados antigos deste aparelho'),
          onTap: () async {
            try {
              await onExportLegacy!();
            } catch (_) {
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Não foi possível exportar os dados antigos.')),
              );
            }
          },
        ),
      ListTile(
        leading: const Icon(Icons.delete_forever_outlined, color: KrezioColors.budgetOver),
        title: const Text('Apagar todos os dados', style: TextStyle(color: KrezioColors.budgetOver)),
        onTap: () => _delete(context, account: false),
      ),
      if (onDeleteAccount != null)
        ListTile(
          leading: const Icon(Icons.person_remove_outlined, color: KrezioColors.budgetOver),
          title: const Text('Excluir minha conta', style: TextStyle(color: KrezioColors.budgetOver)),
          onTap: () => _delete(context, account: true),
        ),
    ]);
  }
}

/// Push notifications for reminders and daily transaction logging.
class NotificationsSection extends StatefulWidget {
  final FinancialRepository repository;
  const NotificationsSection({super.key, required this.repository});

  @override
  State<NotificationsSection> createState() => _NotificationsSectionState();
}

class _NotificationsSectionState extends State<NotificationsSection> {
  NotificationService get _service => NotificationService(widget.repository);

  @override
  Widget build(BuildContext context) {
    final pendingCount = _service.evaluatePendingNotifications().length;
    return SettingsGroup(title: 'Notificações Push & Lembretes', children: [
      SwitchListTile(
        secondary: const Icon(Icons.notifications_active_outlined, color: KrezioColors.aiPurple),
        title: const Text('Notificações de Lembretes e Contas'),
        subtitle: const Text('Avise quando contas a pagar ou a receber estiverem próximas do vencimento'),
        value: _service.remindersPushEnabled,
        onChanged: (val) => setState(() => _service.remindersPushEnabled = val),
      ),
      SwitchListTile(
        secondary: const Icon(Icons.edit_calendar_outlined, color: KrezioColors.aiPurple),
        title: const Text('Lembrete diário para fazer lançamentos'),
        subtitle: Text('Lembrar às ${_service.dailyLogReminderHour.toString().padLeft(2, '0')}:00 de registrar gastos e receitas'),
        value: _service.dailyLogReminderEnabled,
        onChanged: (val) => setState(() => _service.dailyLogReminderEnabled = val),
      ),
      if (_service.dailyLogReminderEnabled)
        ListTile(
          leading: const Icon(Icons.schedule, color: KrezioColors.aiPurple),
          title: const Text('Horário do lembrete diário'),
          trailing: DropdownButton<int>(
            value: _service.dailyLogReminderHour,
            underline: const SizedBox.shrink(),
            items: [
              for (final h in const [9, 12, 18, 20, 21, 22])
                DropdownMenuItem(value: h, child: Text('${h.toString().padLeft(2, '0')}:00')),
            ],
            onChanged: (h) {
              if (h != null) setState(() => _service.dailyLogReminderHour = h);
            },
          ),
        ),
      ListTile(
        leading: const Icon(Icons.send_to_mobile_outlined, color: KrezioColors.emeraldGreen),
        title: const Text('Verificar / Testar Notificação Push'),
        subtitle: Text(
          pendingCount > 0
              ? '$pendingCount alerta(s) pendente(s) hoje — toque para disparar'
              : 'Tudo em dia! Toque para enviar uma notificação de teste',
        ),
        onTap: () => _service.dispatchIfDue(context, force: true),
      ),
    ]);
  }
}

/// Import a bank statement and the yearly report for the Imposto de Renda.
class ToolsSection extends StatelessWidget {
  final FinancialRepository repository;
  const ToolsSection({super.key, required this.repository});

  Future<void> _statement(BuildContext context) async {
    try {
      final bytes = utf8.encode(DataExport.transactionsCsv(repository));
      final file = '${DataExport.fileBase(DateTime.now())}-extrato.csv';
      final result = await exportStatementFile(file, bytes);
      if (context.mounted && result != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result)));
      }
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Não foi possível exportar o extrato.'),
        action: SnackBarAction(label: 'Tentar de novo', onPressed: () => _statement(context)),
      ));
    }
  }

  Future<void> _taxReport(BuildContext context) async {
    final years = {for (final t in repository.transactions) t.date.year}.toList()..sort((a, b) => b.compareTo(a));
    if (years.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ainda não há lançamentos.')));
      return;
    }
    final year = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Ano do relatório'),
        children: [for (final y in years) SimpleDialogOption(onPressed: () => Navigator.pop(ctx, y), child: Text('$y'))],
      ),
    );
    if (year == null) return;
    final report = TaxReport.build(repository.transactions, year);
    try {
      await SharePlus.instance.share(ShareParams(
        title: 'Relatório para o IR $year',
        files: [XFile.fromData(utf8.encode(report.toCsv()), mimeType: 'text/csv', name: 'krezio-ir-$year.csv')],
        fileNameOverrides: ['krezio-ir-$year.csv'],
      ));
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Não foi possível exportar: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsGroup(title: 'Ferramentas & Tour', children: [
      ListTile(
        leading: const Icon(Icons.explore_outlined, color: KrezioColors.aiPurple),
        title: const Text('Tour pelo Krezio & César'),
        subtitle: const Text('Reveja todas as funcionalidades do app passo a passo'),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => OnboardingScreen(
              repository: repository,
              onDone: () => Navigator.pop(context),
            ),
          ),
        ),
      ),
      ListTile(
        leading: const Icon(Icons.file_download_outlined, color: KrezioColors.aiPurple),
        title: const Text('Exportar extrato (CSV)'),
        onTap: () => _statement(context),
      ),
      ListTile(
        leading: const Icon(Icons.upload_file, color: KrezioColors.aiPurple),
        title: const Text('Importar extrato do banco'),
        subtitle: const Text('PDF (Itaú e outros), OFX ou CSV, sem duplicar o que já existe'),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ImportStatementScreen(repository: repository))),
      ),
      ListTile(
        leading: const Icon(Icons.receipt_long_outlined, color: KrezioColors.aiPurple),
        title: const Text('Relatório para o Imposto de Renda'),
        subtitle: const Text('Saúde, educação e rendimentos por fonte, por ano'),
        onTap: () => _taxReport(context),
      ),
    ]);
  }
}

/// César's voice on this device: defaults to Google's male voice (`pt-br-x-ptd-local`),
/// with optional On-Device Lightweight Piper VITS INT8 model or system voice picker.
class VoiceSection extends StatefulWidget {
  const VoiceSection({super.key});

  @override
  State<VoiceSection> createState() => _VoiceSectionState();
}

class _VoiceSectionState extends State<VoiceSection> {
  VoiceSynthesisService get _synthesis => VoiceSynthesisService();

  FlutterNativeTts? get _tts {
    final t = _synthesis.nativeTts;
    return t is FlutterNativeTts ? t : null;
  }

  Future<void> _choose(BuildContext context) async {
    final tts = _tts;
    if (tts == null) return;
    final voices = await tts.voices();
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(KrezioSpace.lg, 0, KrezioSpace.lg, KrezioSpace.sm),
              child: Text('Toque numa voz para ouvir e usar.', style: TextStyle(fontSize: KrezioFont.small)),
            ),
            ListTile(
              leading: const Icon(Icons.auto_awesome, color: KrezioColors.aiPurple),
              title: const Text('Padrão do Google (voz masculina natural)'),
              subtitle: const Text('Google TTS · prioriza voz Neural HD masculina'),
              onTap: () async {
                _synthesis.setUseQuantizedOnnx(false);
                await tts.useVoice(null);
                await _synthesis.speak('Olá! Eu sou o César. Como posso te ajudar hoje?');
              },
            ),
            if (voices.isEmpty)
              const ListTile(title: Text('Nenhuma voz em português instalada. Instale nas configurações de voz do celular.')),
            for (final v in voices)
              ListTile(
                leading: Icon(v.male ? Icons.man : Icons.record_voice_over_outlined),
                title: Text(v.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  '${v.locale}${v.isNatural ? ' · ✨ Natural HD' : ''}${v.isGoogle ? ' · Google' : ''}${v.male ? ' · masculina' : ''}${v.local ? '' : ' · online'}',
                ),
                trailing: const Icon(Icons.play_arrow),
                onTap: () async {
                  _synthesis.setUseQuantizedOnnx(false);
                  await tts.useVoice(v.name);
                  await _synthesis.speak('Olá! Eu sou o César. Como posso te ajudar hoje?');
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsGroup(title: 'Voz do César', children: [
      ListTile(
        leading: const Icon(Icons.record_voice_over_outlined, color: KrezioColors.aiPurple),
        title: const Text('Escolher a voz'),
        subtitle: const Text('Padrão do Google (masculina); toque para ouvir as vozes do celular'),
        onTap: () => _choose(context),
      ),
      ValueListenableBuilder<double>(
        valueListenable: _synthesis.speechRateNotifier,
        builder: (context, rate, _) {
          final clamped = rate.clamp(0.75, 2.0);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.lg, vertical: KrezioSpace.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.speed_rounded, color: KrezioColors.aiPurple),
                    const SizedBox(width: KrezioSpace.md),
                    Expanded(
                      child: Text(
                        'Velocidade de comunicação: ${rate.toStringAsFixed(2)}× (${VoiceSynthesisService.speedLabelOf(rate)})',
                        style: const TextStyle(fontSize: KrezioFont.bodySmall, fontWeight: FontWeight.w600),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Ouvir velocidade',
                      icon: const Icon(Icons.play_circle_outline, color: KrezioColors.emeraldGreen),
                      onPressed: () => _synthesis.speak('Olá! Eu sou o César, falando na velocidade selecionada.'),
                    ),
                  ],
                ),
                Slider(
                  value: clamped,
                  min: 0.75,
                  max: 2.0,
                  divisions: 25,
                  activeColor: KrezioColors.aiPurple,
                  label: '${rate.toStringAsFixed(2)}×',
                  onChanged: (v) async {
                    await _synthesis.setSpeechRate(v);
                    if (mounted) setState(() {});
                  },
                ),
                Wrap(
                  spacing: KrezioSpace.xs,
                  runSpacing: KrezioSpace.xs,
                  children: [
                    for (final preset in VoiceSynthesisService.speedPresets)
                      ChoiceChip(
                        label: Text('${preset}×', style: const TextStyle(fontSize: KrezioFont.caption)),
                        selected: (rate - preset).abs() < 0.03,
                        selectedColor: KrezioColors.aiPurple.withValues(alpha: 0.2),
                        onSelected: (_) async {
                          await _synthesis.setSpeechRate(preset);
                          if (mounted) setState(() {});
                        },
                      ),
                  ],
                ),
                const SizedBox(height: KrezioSpace.xs),
              ],
            ),
          );
        },
      ),
      ValueListenableBuilder<bool>(
        valueListenable: _synthesis.onnxManager.useOnnxModelNotifier,
        builder: (context, useOnnx, _) => SwitchListTile(
          secondary: const Icon(Icons.memory_outlined, color: KrezioColors.aiPurple),
          title: const Text('Modelo On-Device Leve (Piper VITS INT8)'),
          subtitle: Text(
            useOnnx
                ? 'Ativo (${_synthesis.quantizedModelName} · ~15 MB · Masculina)'
                : 'Desativado (usando padrão do Google masculino)',
          ),
          value: useOnnx,
          onChanged: (enabled) {
            _synthesis.setUseQuantizedOnnx(enabled);
            setState(() {});
          },
        ),
      ),
    ]);
  }
}
