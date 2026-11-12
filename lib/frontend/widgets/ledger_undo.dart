import 'package:flutter/material.dart';

import '../../ai/chat_action_history.dart';
import '../../backend/repositories/financial_repository.dart';

void deleteLedgerTransaction(
  BuildContext context,
  FinancialRepository repository,
  String id,
) {
  final index = repository.transactions.indexWhere(
    (transaction) => transaction.id == id,
  );
  if (index < 0) return;
  final transaction = repository.transactions[index];
  // A Cofrinho application/withdrawal mirrors the goal balance: deleting it
  // here would leave the Cofrinho out of sync, so point to the right place.
  if (id.startsWith('cofrinho-')) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(id.startsWith('cofrinho-resgate-')
          ? '"${transaction.title}" é um resgate de cofrinho. Para mudar, guarde o valor de volta na aba Cofrinhos.'
          : '"${transaction.title}" é uma aplicação no cofrinho. Para devolver ao saldo, use "Resgatar" na aba Cofrinhos.'),
      duration: const Duration(seconds: 6),
    ));
    return;
  }
  repository.deleteTransaction(id);
  showLedgerUndo(
    context,
    repository,
    ChatAction(ChatActionKind.deleted, [transaction]),
    '${transaction.title} apagado.',
  );
}

void showLedgerUndo(
  BuildContext context,
  FinancialRepository repository,
  ChatAction action,
  String message,
) {
  final history = ChatActionHistory.forRepository(repository);
  history.push(action);
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 6),
      action: SnackBarAction(
        label: 'Desfazer',
        onPressed: () {
          final result = history.undo(repository, only: action);
          if (result?.undone != true) {
            messenger.showSnackBar(SnackBar(
              content: Text(result?.message ?? 'Esta ação já foi desfeita ou expirou.'),
            ));
          }
        },
      ),
    ),
  );
}
