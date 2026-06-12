import 'package:excel/excel.dart';

import '../../../../data/utils/formatters.dart';
import '../descarga_archivo.dart';

/// Construye un archivo Excel (.xlsx) de UNA hoja con encabezado + filas y lo
/// ofrece para descargar/guardar vía [guardarArchivo] (diálogo "Guardar como"
/// en Windows, selector de ubicación en Android).
///
/// Pensado para los reportes del admin: reutiliza las mismas queries que ya
/// alimentaban el export CSV, pero produce un .xlsx con formato (encabezado
/// destacado, columnas anchas según el contenido, montos como números con
/// separador de miles, así las sumas funcionan en Excel/Sheets).
///
/// Con [empresaNombre]/[titulo]/[periodo] agrega un header corporativo arriba
/// de la tabla (nombre de la empresa, título del reporte y período/fecha de
/// generación, mergeados a lo ancho) — la librería `excel` no soporta
/// imágenes embebidas, así que el branding acá es tipográfico; el logo del
/// tenant va en los reportes PDF.
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
  String? empresaNombre,
  String? titulo,
  String? periodo,
}) async {
  final bytes = construirExcelBytes(
    hojaNombre: hojaNombre,
    headers: headers,
    filas: filas,
    empresaNombre: empresaNombre,
    titulo: titulo,
    periodo: periodo,
  );
  return guardarArchivo(fileName: fileName, bytes: bytes, extension: 'xlsx');
}

/// Arma los bytes del .xlsx (separado de la descarga para poder testearlo
/// sin diálogo de guardado).
List<int> construirExcelBytes({
  required String hojaNombre,
  required List<String> headers,
  required List<List<Object?>> filas,
  String? empresaNombre,
  String? titulo,
  String? periodo,
}) {
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

  // Header corporativo (mismo orden que el header de los PDF): empresa,
  // título, período + fecha de generación, fila en blanco.
  var filaActual = 0;
  if (empresaNombre != null && empresaNombre.isNotEmpty) {
    void filaBranding(String texto, CellStyle estilo) {
      final cell = sheet.cell(
          CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: filaActual));
      cell.value = TextCellValue(texto);
      cell.cellStyle = estilo;
      if (headers.length > 1) {
        sheet.merge(
          CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: filaActual),
          CellIndex.indexByColumnRow(
              columnIndex: headers.length - 1, rowIndex: filaActual),
        );
      }
      filaActual++;
    }

    filaBranding(
        empresaNombre,
        CellStyle(
            bold: true, fontSize: 14, fontColorHex: ExcelColor.blueGrey800));
    if (titulo != null && titulo.isNotEmpty) {
      filaBranding(titulo, CellStyle(bold: true, fontSize: 12));
    }
    final generado = 'Generado: ${Fmt.fechaCorta(DateTime.now())}';
    filaBranding(
        (periodo == null || periodo.isEmpty)
            ? generado
            : 'Período: $periodo — $generado',
        CellStyle(fontSize: 10, fontColorHex: ExcelColor.grey700));
    filaActual++; // fila en blanco antes de la tabla
  }

  // Fila de encabezado de la tabla. Celdas explícitas (no appendRow) para
  // que los índices no dependan de las filas/merges del branding.
  final filaHeaders = filaActual;
  for (var c = 0; c < headers.length; c++) {
    final cell = sheet
        .cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: filaHeaders));
    cell.value = TextCellValue(headers[c]);
    cell.cellStyle = headerStyle;
  }

  // Filas de datos: aplicamos formato numérico a las celdas num según su tipo.
  for (var r = 0; r < filas.length; r++) {
    final fila = filas[r];
    final rowIndex = filaHeaders + 1 + r;
    for (var c = 0; c < fila.length; c++) {
      final v = fila[c];
      final celda = _celda(v);
      if (celda == null) continue;
      final cell = sheet
          .cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: rowIndex));
      cell.value = celda;
      if (v is int) {
        cell.cellStyle = intStyle;
      } else if (v is num) {
        cell.cellStyle = moneyStyle;
      }
    }
  }

  // Ancho de columnas según el contenido más largo (encabezado o celda),
  // acotado a un rango razonable para que no quede ni cortado ni gigante.
  // Las filas de branding no cuentan: están mergeadas a lo ancho.
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
  return saved;
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
