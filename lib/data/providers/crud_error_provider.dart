import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../powersync/connector.dart';
import '../../powersync/db.dart' as ps;

/// Stream de errores de CRUD upload. Cuando PowerSync intenta subir
/// un write local y Postgres lo rechaza (constraint, trigger, RLS),
/// el error llega acá para que los shells lo muestren como SnackBar.
final crudUploadErrorProvider = StreamProvider<CrudUploadError>((ref) {
  return ps.uploadErrorsController.stream;
});
