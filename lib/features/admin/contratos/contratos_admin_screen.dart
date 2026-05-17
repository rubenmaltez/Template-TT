import 'package:flutter/material.dart';
import '../../shared/widgets/empty_state.dart';

class ContratosAdminScreen extends StatelessWidget {
  const ContratosAdminScreen({super.key});
  @override
  Widget build(BuildContext context) =>
      const PendingScreen(titulo: 'Contratos');
}

class ContratoFormScreen extends StatelessWidget {
  const ContratoFormScreen({super.key, this.contratoId, this.clienteId});
  final String? contratoId;
  final String? clienteId;
  @override
  Widget build(BuildContext context) =>
      const PendingScreen(titulo: 'Nuevo contrato');
}
