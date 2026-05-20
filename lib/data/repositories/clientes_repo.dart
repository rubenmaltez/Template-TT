import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../powersync/db.dart' as ps;
import '../models/cliente.dart';

/// Repo de clientes. Todos los queries leen del SQLite local sincronizado.
class ClientesRepo {
  const ClientesRepo();

  Stream<List<Cliente>> watchAsignados() {
    return ps.db
        .watch('SELECT * FROM clientes WHERE activo = 1 ORDER BY nombre')
        .map((rows) => rows.map(Cliente.fromRow).toList());
  }

  Stream<Cliente?> watchById(String id) {
    return ps.db
        .watch('SELECT * FROM clientes WHERE id = ?', parameters: [id])
        .map((rows) => rows.isEmpty ? null : Cliente.fromRow(rows.first));
  }

  Future<Cliente?> getById(String id) async {
    final rows = await ps.db
        .getAll('SELECT * FROM clientes WHERE id = ?', [id]);
    return rows.isEmpty ? null : Cliente.fromRow(rows.first);
  }

  /// Búsqueda local con LIKE (sobre SQLite). Usable para autocompletar.
  Stream<List<Cliente>> search(String query) {
    final like = '%${query.toLowerCase()}%';
    return ps.db
        .watch(
          '''
          SELECT * FROM clientes
           WHERE activo = 1
             AND (lower(nombre) LIKE ? OR lower(cedula) LIKE ? OR telefono LIKE ?)
           ORDER BY nombre
           LIMIT 50
          ''',
          parameters: [like, like, like],
        )
        .map((rows) => rows.map(Cliente.fromRow).toList());
  }
}

final clientesRepoProvider = Provider((_) => const ClientesRepo());

final clientesAsignadosProvider = StreamProvider<List<Cliente>>((ref) {
  return ref.watch(clientesRepoProvider).watchAsignados();
});

final clienteByIdProvider =
    StreamProvider.autoDispose.family<Cliente?, String>((ref, id) {
  return ref.watch(clientesRepoProvider).watchById(id);
});
