import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../theme/krezio_theme.dart';
import '../../widgets/krezio_components.dart';
import '../../../ai/cesar_text.dart';
import '../../../backend/models/financial_account.dart';
import '../../../backend/repositories/financial_repository.dart';
import '../../../backend/services/statement_import.dart';

/// Imports a bank statement (OFX or CSV): pick the file, see a preview with
/// the lines already in the app marked, choose the account, import.
class ImportStatementScreen extends StatefulWidget {
  final FinancialRepository repository;
  const ImportStatementScreen({super.key, required this.repository});

  @override
  State<ImportStatementScreen> createState() => _ImportStatementScreenState();
}

class _ImportStatementScreenState extends State<ImportStatementScreen> {
  List<ImportedEntry>? _entries;
  String? _fileName;
  String? _raw;
  bool _expensesPositive = false;
  String _accountId = FinancialAccount.mainId;
  String? _error;
  bool _reading = false;

  FinancialRepository get repo => widget.repository;

  Future<void> _pick() async {
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['ofx', 'csv', 'txt']);
    if (files.isEmpty) return;
    final f = files.first;
    setState(() => _reading = true);
    final bytes = await f.xFile.readAsBytes();
    String content;
    try {
      content = utf8.decode(bytes);
    } on FormatException {
      content = latin1.decode(bytes); // many banks still export Latin-1
    }
    setState(() {
      _fileName = f.name;
      _raw = content;
      _reading = false;
    });
    _parse();
  }

  void _parse() {
    final raw = _raw;
    if (raw == null) return;
    final isOfx = raw.toUpperCase().contains('<OFX') || raw.toUpperCase().contains('<STMTTRN>');
    final parsed = isOfx ? StatementImport.parseOfx(raw) : StatementImport.parseCsv(raw, expensesPositive: _expensesPositive);
    setState(() {
      _entries = StatementImport.markDuplicates(parsed, repo.transactions);
      _error = parsed.isEmpty ? 'Não encontrei lançamentos nesse arquivo. Use o OFX ou o CSV exportado pelo banco.' : null;
    });
  }

  void _import() {
    final entries = _entries;
    if (entries == null) return;
    var seq = 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final txs = StatementImport.toTransactions(entries,
        accountId: _accountId,
        categorize: (d) => repo.recallCategoryOverride(d),
        newId: () => 'import-$now-${seq++}');
    for (final t in txs) {
      repo.addTransaction(t);
    }
    final skipped = entries.where((e) => e.isDuplicate).length;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${txs.length} ${txs.length == 1 ? 'lançamento importado' : 'lançamentos importados'}'
          '${skipped > 0 ? '; $skipped já existiam e foram ignorados' : ''}.'),
    ));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    final fresh = entries?.where((e) => !e.isDuplicate).length ?? 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Importar extrato')),
      body: ListView(
        padding: const EdgeInsets.all(KrezioSpace.lg),
        children: [
          const Text('Exporte o extrato no app ou site do banco em OFX (recomendado) ou CSV e escolha o arquivo aqui. '
              'Você vê tudo antes de importar, e o que já existe no app é ignorado.'),
          const SizedBox(height: KrezioSpace.md),
          KrezioButton(label: _fileName == null ? 'Escolher arquivo' : 'Trocar arquivo ($_fileName)', icon: Icons.upload_file, onPressed: _pick),
          if (_raw != null && !(_raw!.toUpperCase().contains('<OFX'))) ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Compras aparecem como valores positivos'),
              subtitle: const Text('Comum na fatura do cartão (ex.: Nubank)'),
              value: _expensesPositive,
              onChanged: (v) {
                setState(() => _expensesPositive = v);
                _parse();
              },
            ),
          ],
          if (repo.activeAccounts.length > 1) ...[
            const SizedBox(height: KrezioSpace.sm),
            DropdownButtonFormField<String>(
              value: _accountId,
              decoration: const InputDecoration(labelText: 'Conta'),
              items: [for (final a in repo.activeAccounts) DropdownMenuItem(value: a.id, child: Text(a.name))],
              onChanged: (v) => setState(() => _accountId = v ?? _accountId),
            ),
          ],
          if (_reading) const SizedBox(height: 240, child: KrezioSkeletonList(rows: 4)),
          if (_error != null) ...[
            const SizedBox(height: KrezioSpace.md),
            Text(_error!, style: const TextStyle(color: KrezioColors.budgetOver)),
          ],
          if (entries != null && entries.isNotEmpty) ...[
            const SizedBox(height: KrezioSpace.lg),
            Text('$fresh novos de ${entries.length}', style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: KrezioSpace.sm),
            for (final e in entries)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(e.isDuplicate ? Icons.content_copy : (e.amount < 0 ? Icons.south_west : Icons.north_east),
                    color: e.isDuplicate ? Colors.grey : (e.amount < 0 ? KrezioColors.friendlyOrange : KrezioColors.emeraldGreen)),
                title: Text(e.description, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(decoration: e.isDuplicate ? TextDecoration.lineThrough : null)),
                subtitle: Text('${CesarText.ddmm(e.date)}/${e.date.year}${e.isDuplicate ? ' • já existe' : ''}'),
                trailing: Text(CesarText.money(e.amount)),
              ),
            const SizedBox(height: KrezioSpace.md),
            KrezioButton(label: 'Importar $fresh', expand: true, onPressed: fresh > 0 ? _import : null),
          ],
        ],
      ),
    );
  }
}
