import 'package:flutter/material.dart';
import '../shared/widgets/empty_state.dart';

class ClientesListScreen extends StatelessWidget {
  const ClientesListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PendingScreen(titulo: 'Clientes');
  }
}
