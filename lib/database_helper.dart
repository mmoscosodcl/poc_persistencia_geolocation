import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

/// Clase auxiliar para la administración de la base de datos SQLite mediante sqflite.
/// Proporciona un único punto de acceso (patrón Singleton) para inicializar
/// la base de datos y gestionar las operaciones CRUD sobre la tabla de ubicaciones.
class DatabaseHelper {
  // Instancia única del Singleton
  static final DatabaseHelper _instance = DatabaseHelper._internal();

  // Fábrica para retornar la misma instancia
  factory DatabaseHelper() => _instance;

  // Constructor privado
  DatabaseHelper._internal();

  static Database? _database;

  // Nombre de la base de datos y de la tabla
  static const String _databaseName = 'locations_database.db';
  static const int _databaseVersion = 1;
  static const String tableName = 'locations';

  // Nombres de las columnas
  static const String columnId = 'id';
  static const String columnLatitude = 'latitude';
  static const String columnLongitude = 'longitude';
  static const String columnAltitude = 'altitude';
  static const String columnAccuracy = 'accuracy';
  static const String columnSpeed = 'speed';
  static const String columnTimestamp = 'timestamp';

  /// Obtiene la referencia a la base de datos abierta, o la inicializa si aún no existe.
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  /// Inicializa la base de datos SQLite creando el archivo en el directorio correspondiente
  /// del sistema de archivos y ejecutando las sentencias DDL iniciales.
  Future<Database> _initDatabase() async {
    // Obtiene la ruta predeterminada de bases de datos del dispositivo
    final String databasesPath = await getDatabasesPath();
    final String path = join(databasesPath, _databaseName);

    // Abre o crea la base de datos con la versión especificada
    return await openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
    );
  }

  /// Crea la tabla única 'locations' para persistir los datos de geolocalización.
  /// Contiene latitud, longitud, altitud, precisión, velocidad y fecha/hora.
  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $tableName (
        $columnId INTEGER PRIMARY KEY AUTOINCREMENT,
        $columnLatitude REAL NOT NULL,
        $columnLongitude REAL NOT NULL,
        $columnAltitude REAL NOT NULL,
        $columnAccuracy REAL NOT NULL,
        $columnSpeed REAL NOT NULL,
        $columnTimestamp TEXT NOT NULL
      )
    ''');
  }

  /// Inserta un nuevo registro de ubicación en la base de datos relacional.
  /// Retorna el identificador único (ID) asignado al nuevo registro insertado.
  Future<int> insertLocation(Map<String, dynamic> row) async {
    final Database db = await database;
    return await db.insert(
      tableName,
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Consulta y obtiene todos los registros de ubicaciones guardados.
  /// Los registros se retornan ordenados de manera descendente según su ID (el más reciente primero).
  Future<List<Map<String, dynamic>>> getLocations() async {
    final Database db = await database;
    return await db.query(
      tableName,
      orderBy: '$columnId DESC',
    );
  }

  /// Elimina un registro de ubicación específico a partir de su ID.
  Future<int> deleteLocation(int id) async {
    final Database db = await database;
    return await db.delete(
      tableName,
      where: '$columnId = ?',
      whereArgs: [id],
    );
  }

  /// Elimina todos los registros de la tabla de ubicaciones para reiniciar el historial.
  Future<int> clearAllLocations() async {
    final Database db = await database;
    return await db.delete(tableName);
  }
}
