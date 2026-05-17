import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../powersync/db.dart' as ps;

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = Supabase.instance.client.auth.currentUser;
    return Scaffold(
      appBar: AppBar(
        title: const Text('ISP Billing'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Cerrar sesión',
            onPressed: () => Supabase.instance.client.auth.signOut(),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.person),
              title: const Text('Sesión activa'),
              subtitle: Text(user?.email ?? '—'),
            ),
          ),
          const SizedBox(height: 8),
          const _SyncStatusCard(),
          const SizedBox(height: 8),
          const _CountersCard(),
        ],
      ),
    );
  }
}

class _SyncStatusCard extends StatelessWidget {
  const _SyncStatusCard();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: ps.db.statusStream,
      initialData: ps.db.currentStatus,
      builder: (context, snapshot) {
        final status = snapshot.data;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Estado de sync',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text('Conectado: ${status?.connected ?? false}'),
                Text('Descargando: ${status?.downloading ?? false}'),
                Text('Subiendo: ${status?.uploading ?? false}'),
                Text('Última sync: ${status?.lastSyncedAt ?? "—"}'),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _CountersCard extends StatelessWidget {
  const _CountersCard();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: ps.db.watch('''
        SELECT
          (SELECT COUNT(*) FROM planes)    AS planes,
          (SELECT COUNT(*) FROM clientes)  AS clientes,
          (SELECT COUNT(*) FROM contratos) AS contratos,
          (SELECT COUNT(*) FROM cuotas)    AS cuotas
      '''),
      builder: (context, snapshot) {
        if (snapshot.data == null) {
          return const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('Esperando primer sync...'),
            ),
          );
        }
        final row = (snapshot.data as dynamic).first as Map<String, dynamic>;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Datos sincronizados localmente',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text('Planes:    ${row['planes']}'),
                Text('Clientes:  ${row['clientes']}'),
                Text('Contratos: ${row['contratos']}'),
                Text('Cuotas:    ${row['cuotas']}'),
              ],
            ),
          ),
        );
      },
    );
  }
}
