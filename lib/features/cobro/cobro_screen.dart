import 'package:flutter/material.dart';
import '../shared/widgets/empty_state.dart';

class CobroScreen extends StatelessWidget {
  const CobroScreen({super.key, required this.cuotaId});
  final String cuotaId;

  @override
  Widget build(BuildContext context) {
    return PendingScreen(titulo: 'Cobrar cuota $cuotaId');
  }
}
