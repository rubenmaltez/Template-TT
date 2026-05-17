import 'package:flutter/material.dart';
import '../../shared/widgets/empty_state.dart';

class ClientesAdminScreen extends StatelessWidget {
  const ClientesAdminScreen({super.key});
  @override
  Widget build(BuildContext context) =>
      const PendingScreen(titulo: 'Gestión de clientes');
}

class ClienteFormScreen extends StatelessWidget {
  const ClienteFormScreen({super.key, this.clienteId});
  final String? clienteId;
  @override
  Widget build(BuildContext context) => PendingScreen(
      titulo: clienteId == null ? 'Nuevo cliente' : 'Editar cliente');
}
