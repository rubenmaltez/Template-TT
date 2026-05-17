import 'package:flutter/material.dart';
import '../shared/widgets/empty_state.dart';

class ClienteDetailScreen extends StatelessWidget {
  const ClienteDetailScreen({super.key, required this.clienteId});
  final String clienteId;

  @override
  Widget build(BuildContext context) {
    return PendingScreen(titulo: 'Cliente $clienteId');
  }
}
