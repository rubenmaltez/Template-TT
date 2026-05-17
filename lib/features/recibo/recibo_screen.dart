import 'package:flutter/material.dart';
import '../shared/widgets/empty_state.dart';

class ReciboScreen extends StatelessWidget {
  const ReciboScreen({super.key, required this.reciboId});
  final String reciboId;

  @override
  Widget build(BuildContext context) {
    return PendingScreen(titulo: 'Recibo $reciboId');
  }
}
