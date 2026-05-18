import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

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
    // ignore: avoid_print
    print('[SUPER_SHELL] build titulo=$titulo');
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: scheme.tertiaryContainer,
        foregroundColor: scheme.onTertiaryContainer,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Volver al panel',
          onPressed: () => context.go('/admin'),
        ),
        title: Row(
          children: [
            const Icon(Icons.shield, size: 18),
            const SizedBox(width: 8),
            Text('Super Admin · $titulo'),
          ],
        ),
      ),
      body: child,
    );
  }
}
