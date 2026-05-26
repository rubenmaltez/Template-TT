import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../powersync/db.dart' as ps;

/// Verifica si hay cambios locales sin sincronizar antes de cerrar sesión.
/// Si hay pendientes, muestra un dialog de confirmación. Si no hay, hace
/// sign-out directo.
Future<void> confirmarSignOut(BuildContext context) async {
  final pendientes = await _contarCrudPendientes();

  if (pendientes > 0 && context.mounted) {
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.cloud_off, size: 32),
        title: const Text('Cambios sin sincronizar'),
        content: Text(
          'Tenés $pendientes cambio${pendientes > 1 ? 's' : ''} que '
          'todavía no se subieron al servidor.\n\n'
          'Se van a guardar localmente y se sincronizarán '
          'la próxima vez que inicies sesión.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cerrar sesión'),
          ),
        ],
      ),
    );
    if (confirmar != true || !context.mounted) return;
  }

  await Supabase.instance.client.auth.signOut();
}

Future<int> _contarCrudPendientes() async {
  try {
    final rows = await ps.db.getAll(
      'SELECT COUNT(*) AS total FROM ps_crud',
    );
    return (rows.first['total'] as num?)?.toInt() ?? 0;
  } catch (_) {
    return 0;
  }
}
