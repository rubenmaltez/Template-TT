import 'package:flutter/material.dart';

/// Muestra un dialog "¿Descartar cambios sin guardar?" centralizado
/// para forms con `PopScope`.
///
/// Retorna `true` si el user confirma descartar (puede continuar el pop),
/// `false` o `null` si cancela (debe permanecer en el form).
///
/// Patrón de uso:
///
/// ```dart
/// PopScope(
///   canPop: !_dirty,
///   onPopInvokedWithResult: (didPop, _) async {
///     if (didPop) return;
///     final confirm = await confirmDiscardChanges(context);
///     if (confirm == true && context.mounted) Navigator.pop(context);
///   },
///   child: Scaffold(...),
/// )
/// ```
///
/// **Limitación conocida**: `PopScope` solo intercepta `Navigator.pop()`
/// (browser back, hardware back, botón Cancelar imperativo). NO cubre
/// `context.go(...)` del go_router porque ese es replace de ruta, no
/// pop. Sidebar nav con go bypassa este guard — anotado al backlog.
Future<bool?> confirmDiscardChanges(BuildContext context) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      title: const Text('¿Descartar cambios?'),
      content: const Text(
        'Tenés cambios sin guardar. Si salís se pierden.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Seguir editando'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Descartar'),
        ),
      ],
    ),
  );
}
