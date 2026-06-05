import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

/// Construye un archivo Excel (.xlsx) de UNA hoja con encabezado + filas y lo
/// ofrece para descargar/guardar. Targets soportados: **Android** y **Windows**.
///   - Windows (y demás desktop): abre el diálogo nativo "Guardar como" y
///     escribimos los bytes a la ruta elegida (file_picker en desktop devuelve
///     la ruta pero NO escribe el contenido — hay que hacerlo a mano).
///   - Android: file_picker guarda el archivo directamente con `bytes:` y
///     devuelve la ruta (que puede ser un content URI no escribible por
///     dart:io, por eso ahí NO reescribimos).
///   - Web: `saveFile` no está implementado en file_picker 8.x; como web no es
///     un target del producto, avisamos con un mensaje claro en vez de fallar
///     con un error críptico.
///
/// Pensado para los reportes del admin: reutiliza las mismas queries que ya
/// alimentaban el export CSV, pero produce un .xlsx con formato (encabezado
/// destacado, columnas anchas según el contenido, montos como números con
/// separador de miles, así las sumas funcionan en Excel/Sheets).
///
/// [filas] es una lista de filas; cada celda puede ser `num` (→ celda numérica
/// con formato) o `String` (→ texto) o `null` (→ celda vacía). Los `int` se
/// muestran como enteros (conteos) y los `double` con 2 decimales (montos).
/// Devuelve la ruta donde se guardó, o `null` si el usuario canceló.
Future<String?> descargarExcel({
  required String fileName,
  required String hojaNombre,
  required List<String> headers,
  required List<List<Object?>> filas,
}) async {
  final excel = Excel.createExcel();
  // createExcel arranca con una hoja default ('Sheet1'); la renombramos a algo
  // descriptivo en vez de crear otra y tener que borrar la default.
  final defaultName = excel.getDefaultSheet();
  if (defaultName != null && defaultName != hojaNombre) {
    excel.rename(defaultName, hojaNombre);
  }
  final sheet = excel[hojaNombre];

  // Estilos reutilizables.
  final headerStyle = CellStyle(
    bold: true,
    fontColorHex: ExcelColor.white,
    backgroundColorHex: ExcelColor.blueGrey800,
    horizontalAlign: HorizontalAlign.Center,
    verticalAlign: VerticalAlign.Center,
  );
  // Enteros (conteos): separador de miles, sin decimales, a la derecha.
  final intStyle = CellStyle(
    horizontalAlign: HorizontalAlign.Right,
    numberFormat: NumFormat.custom(formatCode: '#,##0'),
  );
  // Montos (double): separador de miles + 2 decimales, a la derecha.
  final moneyStyle = CellStyle(
    horizontalAlign: HorizontalAlign.Right,
    numberFormat: NumFormat.custom(formatCode: '#,##0.00'),
  );

  // Fila 0: encabezado.
  sheet.appendRow(headers.map<CellValue?>((h) => TextCellValue(h)).toList());
  for (var c = 0; c < headers.length; c++) {
    sheet
        .cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0))
        .cellStyle = headerStyle;
  }

  // Filas de datos: aplicamos formato numérico a las celdas num según su tipo.
  for (var r = 0; r < filas.length; r++) {
    final fila = filas[r];
    sheet.appendRow(fila.map(_celda).toList());
    final rowIndex = r + 1; // +1 porque la fila 0 es el encabezado
    for (var c = 0; c < fila.length; c++) {
      final v = fila[c];
      if (v is int) {
        sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: rowIndex))
            .cellStyle = intStyle;
      } else if (v is num) {
        sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: rowIndex))
            .cellStyle = moneyStyle;
      }
    }
  }

  // Ancho de columnas según el contenido más largo (encabezado o celda),
  // acotado a un rango razonable para que no quede ni cortado ni gigante.
  for (var c = 0; c < headers.length; c++) {
    var maxLen = headers[c].length;
    for (final fila in filas) {
      if (c < fila.length) {
        final s = fila[c]?.toString() ?? '';
        if (s.length > maxLen) maxLen = s.length;
      }
    }
    sheet.setColumnWidth(c, (maxLen + 3).clamp(12, 50).toDouble());
  }

  final saved = excel.save();
  if (saved == null) {
    throw Exception('No se pudo generar el archivo Excel');
  }
  final bytes = Uint8List.fromList(saved);

  // Web fuera de scope: file_picker.saveFile no existe en la línea 8.x.
  if (kIsWeb) {
    throw UnsupportedError(
      'La exportación a Excel está disponible en la app de Windows o Android, '
      'no en la versión web.',
    );
  }

  final path = await FilePicker.platform.saveFile(
    dialogTitle: 'Guardar reporte',
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: const ['xlsx'],
    // En Android/iOS file_picker escribe el archivo con estos bytes; en
    // desktop solo abre el diálogo (los bytes los escribimos abajo).
    bytes: bytes,
  );
  if (path == null) return null; // el usuario canceló el diálogo

  // En desktop file_picker devuelve la ruta pero NO escribe el contenido →
  // lo hacemos nosotros. En Android ya quedó escrito por el `bytes:` de arriba.
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await File(path).writeAsBytes(bytes, flush: true);
  }
  return path;
}

/// Mapea un valor crudo de una fila a la celda tipada de Excel. Los números
/// quedan como números (sumables en Excel); el resto, como texto.
CellValue? _celda(Object? v) {
  if (v == null) return null;
  if (v is int) return IntCellValue(v);
  if (v is double) return DoubleCellValue(v);
  if (v is num) return DoubleCellValue(v.toDouble());
  return TextCellValue(v.toString());
}
