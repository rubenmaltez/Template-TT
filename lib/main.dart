import 'package:flutter/material.dart';

import 'config/env.dart';

void main() {
  runApp(const IspBillingApp());
}

class IspBillingApp extends StatelessWidget {
  const IspBillingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ISP Billing',
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      home: const _StartupGate(),
    );
  }
}

class _StartupGate extends StatelessWidget {
  const _StartupGate();

  @override
  Widget build(BuildContext context) {
    if (!Env.isConfigured) {
      return const Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Configuración pendiente:\n\n'
              'Faltan SUPABASE_URL / SUPABASE_ANON_KEY / POWERSYNC_URL.\n\n'
              'Lanza la app con:\n'
              'flutter run --dart-define-from-file=.env.json',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    return const Scaffold(
      body: Center(child: Text('ISP Billing — wiring de Supabase/PowerSync pendiente')),
    );
  }
}
