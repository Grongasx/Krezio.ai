import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/krezio_theme.dart';

/// Shared building blocks for every screen: buttons, fields, cards, dialogs and
/// the empty / loading / error states. Colors come from the active theme's
/// brightness, so callers never pass `isDark` around.
class KrezioPalette {
  final bool isDark;
  const KrezioPalette._(this.isDark);

  factory KrezioPalette.of(BuildContext context) =>
      KrezioPalette._(Theme.of(context).brightness == Brightness.dark);

  Color get background => isDark ? KrezioColors.darkBackground : KrezioColors.lightBackground;
  Color get surface => isDark ? KrezioColors.darkSurface : KrezioColors.lightSurface;
  Color get primaryText => isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText;
  Color get secondaryText => isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText;
  Color get border => isDark ? KrezioColors.darkBorder : KrezioColors.lightBorder;
}

// ── Buttons ─────────────────────────────────────────────────────────────────

enum KrezioButtonKind { primary, secondary, danger }

class KrezioButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final KrezioButtonKind kind;
  final IconData? icon;
  final bool loading;
  final bool expand;

  const KrezioButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.kind = KrezioButtonKind.primary,
    this.icon,
    this.loading = false,
    this.expand = false,
  });

  const KrezioButton.secondary({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.loading = false,
    this.expand = false,
  }) : kind = KrezioButtonKind.secondary;

  const KrezioButton.danger({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.loading = false,
    this.expand = false,
  }) : kind = KrezioButtonKind.danger;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;
    final child = loading
        ? const SizedBox(
            width: KrezioSpace.lg,
            height: KrezioSpace.lg,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: KrezioFont.title), const SizedBox(width: KrezioSpace.sm)],
              Text(label, style: const TextStyle(fontSize: KrezioFont.body, fontWeight: FontWeight.bold)),
            ],
          );

    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(KrezioSpace.md));
    const padding = EdgeInsets.symmetric(horizontal: KrezioSpace.xl, vertical: KrezioSpace.md);
    final Widget button = kind == KrezioButtonKind.secondary
        ? OutlinedButton(
            onPressed: enabled ? onPressed : null,
            style: OutlinedButton.styleFrom(
              foregroundColor: KrezioColors.aiPurple,
              side: const BorderSide(color: KrezioColors.aiPurple),
              shape: shape,
              padding: padding,
            ),
            child: child,
          )
        : ElevatedButton(
            onPressed: enabled ? onPressed : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: kind == KrezioButtonKind.danger ? KrezioColors.friendlyOrange : KrezioColors.aiPurple,
              foregroundColor: Colors.white,
              shape: shape,
              padding: padding,
            ),
            child: child,
          );
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

// ── Fields ──────────────────────────────────────────────────────────────────

class KrezioTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? errorText;
  final bool autofocus;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final Widget? suffixIcon;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  const KrezioTextField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.errorText,
    this.autofocus = false,
    this.obscureText = false,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.none,
    this.suffixIcon,
    this.onChanged,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
      obscureText: obscureText,
      keyboardType: keyboardType,
      textCapitalization: textCapitalization,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      style: const TextStyle(fontSize: KrezioFont.bodyLarge),
      decoration: InputDecoration(labelText: label, hintText: hint, errorText: errorText, suffixIcon: suffixIcon),
    );
  }
}

/// Money input in reais: numeric keyboard, "R$ " prefix and only digits plus one
/// decimal separator. Read the value with [KrezioMoneyField.parse].
class KrezioMoneyField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? errorText;
  final bool autofocus;

  const KrezioMoneyField({
    super.key,
    required this.controller,
    required this.label,
    this.errorText,
    this.autofocus = false,
  });

  /// "1.234,56" → 1234.56 · "12,5" → 12.5 · "80" → 80 · invalid or ≤ 0 → null.
  static double? parse(String text) {
    var t = text.trim().replaceAll(RegExp(r'[R$\s]'), '');
    if (t.contains(',')) t = t.replaceAll('.', '').replaceAll(',', '.');
    final v = double.tryParse(t);
    return (v == null || !v.isFinite || v <= 0) ? null : v;
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
      style: const TextStyle(fontSize: KrezioFont.bodyLarge),
      decoration: InputDecoration(labelText: label, prefixText: 'R\$ ', errorText: errorText),
    );
  }
}

// ── Card ────────────────────────────────────────────────────────────────────

class KrezioCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  const KrezioCard({super.key, required this.child, this.padding = const EdgeInsets.all(KrezioSpace.lg), this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = KrezioPalette.of(context);
    return Material(
      color: p.surface,
      shape: RoundedRectangleBorder(borderRadius: KrezioTheme.borderRadius, side: BorderSide(color: p.border)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
    );
  }
}

// ── Dialogs ─────────────────────────────────────────────────────────────────

/// Yes/no confirmation. Resolves to `true` only when the user confirms.
Future<bool> showKrezioConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirmar',
  String cancelLabel = 'Cancelar',
  bool danger = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: KrezioTheme.borderRadius),
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(cancelLabel)),
        danger
            ? KrezioButton.danger(label: confirmLabel, onPressed: () => Navigator.of(ctx).pop(true))
            : KrezioButton(label: confirmLabel, onPressed: () => Navigator.of(ctx).pop(true)),
      ],
    ),
  );
  return result ?? false;
}

/// Small form in a dialog. [onConfirm] returns `true` when the input is valid
/// and the dialog can close; returning `false` keeps it open.
Future<void> showKrezioFormDialog(
  BuildContext context, {
  required String title,
  required List<Widget> fields,
  required bool Function() onConfirm,
  String confirmLabel = 'Salvar',
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: KrezioTheme.borderRadius),
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < fields.length; i++) ...[
            if (i > 0) const SizedBox(height: KrezioSpace.md),
            fields[i],
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancelar')),
        KrezioButton(
          label: confirmLabel,
          onPressed: () {
            if (onConfirm()) Navigator.of(ctx).pop();
          },
        ),
      ],
    ),
  );
}

// ── Empty / loading / error states ──────────────────────────────────────────

class KrezioEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool compact;

  const KrezioEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = KrezioPalette.of(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.all(compact ? KrezioSpace.lg : KrezioSpace.xxxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: compact ? 32 : 48, color: p.secondaryText.withValues(alpha: 0.6)),
            const SizedBox(height: KrezioSpace.md),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: KrezioFont.bodyLarge, fontWeight: FontWeight.bold, color: p.primaryText),
            ),
            if (message != null) ...[
              const SizedBox(height: KrezioSpace.sm),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: KrezioFont.small, color: p.secondaryText),
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: KrezioSpace.lg),
              KrezioButton.secondary(label: actionLabel!, onPressed: onAction),
            ],
          ],
        ),
      ),
    );
  }
}

/// Placeholder rows shown while a list loads.
class KrezioSkeletonList extends StatefulWidget {
  final int rows;
  const KrezioSkeletonList({super.key, this.rows = 6});

  @override
  State<KrezioSkeletonList> createState() => _KrezioSkeletonListState();
}

class _KrezioSkeletonListState extends State<KrezioSkeletonList> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = KrezioPalette.of(context);
    Widget bar(double width, double height) => Container(
          width: width,
          height: height,
          decoration: BoxDecoration(color: p.border, borderRadius: BorderRadius.circular(KrezioSpace.xs)),
        );
    return FadeTransition(
      opacity: Tween(begin: 0.4, end: 1.0).animate(_pulse),
      child: ListView.separated(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(KrezioSpace.lg),
        itemCount: widget.rows,
        separatorBuilder: (_, __) => const SizedBox(height: KrezioSpace.lg),
        itemBuilder: (_, __) => Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: p.border, borderRadius: BorderRadius.circular(KrezioSpace.md)),
            ),
            const SizedBox(width: KrezioSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [bar(160, KrezioSpace.md), const SizedBox(height: KrezioSpace.sm), bar(100, KrezioSpace.sm)],
              ),
            ),
            bar(60, KrezioSpace.md),
          ],
        ),
      ),
    );
  }
}

class KrezioErrorState extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const KrezioErrorState({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return KrezioEmptyState(
      icon: Icons.error_outline,
      title: 'Algo deu errado',
      message: message,
      actionLabel: onRetry == null ? null : 'Tentar de novo',
      onAction: onRetry,
    );
  }
}

// ── Splash ──────────────────────────────────────────────────────────────────

/// Shown while the César engine and the saved data load. Brand mark only, no
/// small text (criterion of card 1.2).
class KrezioSplash extends StatelessWidget {
  const KrezioSplash({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KrezioPalette.of(context).background,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(KrezioSpace.xl),
              decoration: BoxDecoration(color: KrezioColors.aiPurple.withValues(alpha: 0.15), shape: BoxShape.circle),
              child: const Icon(Icons.auto_awesome, color: KrezioColors.aiPurple, size: 48),
            ),
            const SizedBox(height: KrezioSpace.xxl),
            const Text(
              'Krezio.ai',
              style: TextStyle(fontSize: KrezioFont.headline, fontWeight: FontWeight.bold, color: KrezioColors.aiPurple),
            ),
            const SizedBox(height: KrezioSpace.xxl),
            const SizedBox(
              width: KrezioSpace.xxl,
              height: KrezioSpace.xxl,
              child: CircularProgressIndicator(strokeWidth: 2.5, color: KrezioColors.aiPurple),
            ),
          ],
        ),
      ),
    );
  }
}
