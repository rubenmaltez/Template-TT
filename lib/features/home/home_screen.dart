import 'package:flutter/material.dart';
import '../shared/widgets/empty_state.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PendingScreen(titulo: 'Inicio');
  }
}
