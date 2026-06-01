import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../powersync/db.dart' as ps;
import '../models/cliente.dart';

/// Repo de clientes. Todos los queries leen del SQLite local sincronizado.
class ClientesRepo {
  const ClientesRepo();

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
}

final clientesRepoProvider = Provider((_) => const ClientesRepo());

final clienteByIdProvider =
    StreamProvider.autoDispose.family<Cliente?, String>((ref, id) {
  return ref.watch(clientesRepoProvider).watchById(id);
});
