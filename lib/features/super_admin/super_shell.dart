import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../shared/utils/shell_nav.dart';

/// Shell del panel Super Admin (gestión cross-tenant del SaaS).
/// Visualmente separado del AdminShell para dejar claro que estás "afuera"
/// del tenant — con un AppBar que indica "Super Admin" y un botón para
/// volver al panel admin del tenant System.
class SuperShell extends StatelessWidget {
  const SuperShell({super.key, required this.child, required this.titulo});

  final Widget child;
  final String titulo;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final loc = GoRouterState.of(context).matchedLocation;
    final enLogs = loc == '/super/logs';
    final enTenants = loc == '/super/tenants';
    return Scaffold(
      appBar: AppBar(
        backgroundColor: scheme.tertiaryContainer,
        foregroundColor: scheme.onTertiaryContainer,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Volver al panel',
          // closeModalsAndGo cierra dialogs/sheets abiertos sobre la
          // ruta actual antes de navegar (ej. CredencialesDialog en
          // /super/tenants después de crear un ISP, que queda flotando
          // si el user toca volver sin cerrarlo).
          onPressed: () => context.closeModalsAndGo('/admin'),
        ),
        title: Row(
          children: [
            const Icon(Icons.shield, size: 18),
            const SizedBox(width: 8),
            Text('Super Admin · $titulo'),
          ],
        ),
        actions: [
          if (!enTenants)
            IconButton(
              icon: const Icon(Icons.business),
              tooltip: 'Tenants',
              onPressed: () => context.closeModalsAndGo('/super/tenants'),
            ),
          if (!enLogs)
            IconButton(
              icon: const Icon(Icons.bug_report_outlined),
              tooltip: 'Logs de errores',
              onPressed: () => context.closeModalsAndGo('/super/logs'),
            ),
        ],
      ),
      body: child,
    );
  }
}
