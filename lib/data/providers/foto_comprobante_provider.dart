import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/foto_comprobante_service.dart';

final fotoComprobanteServiceProvider = Provider<FotoComprobanteService>(
    (ref) => FotoComprobanteService(Supabase.instance.client));
