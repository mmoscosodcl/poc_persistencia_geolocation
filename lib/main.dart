import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'database_helper.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GeolocationApp());
}

/// Aplicación principal de la Prueba de Concepto (PoC).
/// Configura el tema visual y define la página única de geolocalización.
class GeolocationApp extends StatelessWidget {
  const GeolocationApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PoC Geolocalización y Persistencia',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
      ),
      themeMode: ThemeMode.system,
      home: const GeolocationPage(),
    );
  }
}

/// Página única de la prueba de concepto.
/// Administra la captura de geolocalización (última ubicación y rastreo en tiempo real)
/// y la persistencia relacional en SQLite mediante sqflite.
class GeolocationPage extends StatefulWidget {
  const GeolocationPage({super.key});

  @override
  State<GeolocationPage> createState() => _GeolocationPageState();
}

class _GeolocationPageState extends State<GeolocationPage> {
  // Instancia única del gestor de base de datos SQLite
  final DatabaseHelper _dbHelper = DatabaseHelper();

  // Estado de la ubicación actual capturada
  Position? _currentPosition;

  // Bandera para indicar si el rastreo en tiempo real está activado
  bool _isRealtimeTracking = false;

  // Suscripción al flujo continuo de geolocalización (Stream)
  StreamSubscription<Position>? _positionStreamSubscription;

  // Indicador de operaciones asíncronas en progreso (cargas o guardado)
  bool _isLoading = false;

  // Mensaje descriptivo de estado o error para retroalimentación del usuario
  String? _statusMessage;

  // Lista en memoria de las ubicaciones almacenadas en SQLite
  List<Map<String, dynamic>> _savedLocations = [];

  @override
  void initState() {
    super.initState();
    // 1. Obtener la ubicación inicial (la más reciente por defecto)
    _fetchDefaultLocation();
    // 2. Cargar el historial existente de la base de datos
    _loadSavedLocations();
  }

  @override
  void dispose() {
    // Es fundamental cancelar la suscripción del Stream para liberar memoria y recursos de GPS
    _positionStreamSubscription?.cancel();
    super.dispose();
  }

  /// Verifica la disponibilidad del servicio de ubicación en el dispositivo
  /// y gestiona los permisos necesarios de acceso a la geolocalización.
  /// Retorna `true` si el acceso está concedido, o `false` en caso contrario.
  Future<bool> _handleLocationPermissions() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() {
        _statusMessage =
            'Los servicios de ubicación del dispositivo están desactivados.';
      });
      return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        setState(() {
          _statusMessage = 'Permiso de ubicación denegado por el usuario.';
        });
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      setState(() {
        _statusMessage =
            'Los permisos de ubicación están permanentemente denegados. Habilítelos en Ajustes.';
      });
      return false;
    }

    return true;
  }

  /// Obtiene la ubicación más reciente por defecto al iniciar la pantalla
  /// o cuando el usuario pulsa manualmente el botón de refresco.
  /// Intenta primero consultar la última ubicación conocida (rápida/en caché)
  /// y luego consulta la posición actual precisa mediante GPS/Red.
  Future<void> _fetchDefaultLocation() async {
    setState(() {
      _isLoading = true;
      _statusMessage = 'Obteniendo última ubicación conocida...';
    });

    final bool hasPermission = await _handleLocationPermissions();
    if (!hasPermission) {
      setState(() {
        _isLoading = false;
      });
      return;
    }

    try {
      // Intenta obtener la última ubicación registrada en el sistema operativo
      Position? position = await Geolocator.getLastKnownPosition();

      // Si no existe ubicación previa en caché, solicita la posición actual con alta precisión
      position ??= await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );

      setState(() {
        _currentPosition = position;
        _statusMessage = 'Ubicación obtenida exitosamente.';
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Error al capturar la ubicación: ${e.toString()}';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  /// Conmuta el modo de rastreo continuo en tiempo real (activar / desactivar).
  /// Al activarse, escucha los cambios continuos mediante `Geolocator.getPositionStream`.
  /// Al desactivarse, cancela la suscripción para suspender el consumo de batería y GPS.
  Future<void> _toggleRealtimeTracking(bool enable) async {
    if (enable) {
      final bool hasPermission = await _handleLocationPermissions();
      if (!hasPermission) {
        setState(() {
          _isRealtimeTracking = false;
        });
        return;
      }

      setState(() {
        _isRealtimeTracking = true;
        _statusMessage = 'Rastreo en tiempo real activo.';
      });

      // Configuración de frecuencia y precisión del flujo de geolocalización
      const LocationSettings locationSettings = LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 2, // Emite eventos al desplazarse al menos 2 metros
      );

      _positionStreamSubscription = Geolocator.getPositionStream(
        locationSettings: locationSettings,
      ).listen(
        (Position position) {
          setState(() {
            _currentPosition = position;
            _statusMessage = 'Actualización en tiempo real recibida.';
          });
        },
        onError: (dynamic error) {
          setState(() {
            _statusMessage = 'Error en el flujo en tiempo real: $error';
          });
        },
      );
    } else {
      await _positionStreamSubscription?.cancel();
      _positionStreamSubscription = null;
      setState(() {
        _isRealtimeTracking = false;
        _statusMessage = 'Rastreo en tiempo real desactivado.';
      });
    }
  }

  /// Persiste la ubicación actual en la base de datos relacional SQLite
  /// utilizando el paquete sqflite. Almacena latitud, longitud, altitud,
  /// precisión, velocidad y la marca de tiempo (timestamp).
  Future<void> _saveCurrentLocation() async {
    if (_currentPosition == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No hay una ubicación capturada disponible para guardar.',
          ),
          backgroundColor: Colors.amber,
        ),
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final Map<String, dynamic> locationData = {
        DatabaseHelper.columnLatitude: _currentPosition!.latitude,
        DatabaseHelper.columnLongitude: _currentPosition!.longitude,
        DatabaseHelper.columnAltitude: _currentPosition!.altitude,
        DatabaseHelper.columnAccuracy: _currentPosition!.accuracy,
        DatabaseHelper.columnSpeed: _currentPosition!.speed,
        DatabaseHelper.columnTimestamp:
            DateTime.now().toLocal().toIso8601String(),
      };

      // Inserción en la tabla relacional SQLite
      final int insertId = await _dbHelper.insertLocation(locationData);

      // Recarga el listado desde la base de datos
      await _loadSavedLocations();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Ubicación guardada con éxito en SQLite (Registro ID: $insertId).',
            ),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al guardar en la base de datos: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  /// Consulta la tabla relacional de SQLite para cargar todas las ubicaciones
  /// almacenadas y reflejarlas en la interfaz de usuario.
  Future<void> _loadSavedLocations() async {
    try {
      final List<Map<String, dynamic>> data = await _dbHelper.getLocations();
      setState(() {
        _savedLocations = data;
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Error al cargar ubicaciones de SQLite: $e';
      });
    }
  }

  /// Elimina un registro puntual de la base de datos a partir de su ID.
  Future<void> _deleteLocation(int id) async {
    try {
      await _dbHelper.deleteLocation(id);
      await _loadSavedLocations();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Registro #$id eliminado de SQLite.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al eliminar registro: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Limpia todos los registros almacenados en la tabla SQLite.
  Future<void> _clearAllLocations() async {
    try {
      await _dbHelper.clearAllLocations();
      await _loadSavedLocations();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Se han eliminado todos los registros guardados.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al limpiar registros: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('PoC: Geolocalización & Persistencia'),
        centerTitle: true,
        backgroundColor: colorScheme.surfaceContainerHighest,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Actualizar ubicación actual',
            onPressed: _isLoading ? null : _fetchDefaultLocation,
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            await _fetchDefaultLocation();
            await _loadSavedLocations();
          },
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Tarjeta 1: Visualización y control de la geolocalización actual
                _buildCurrentLocationCard(theme, colorScheme),

                const SizedBox(height: 16),

                // Tarjeta 2: Panel de acciones (Guardar y controles de botón)
                _buildActionPanel(colorScheme),

                const SizedBox(height: 20),

                // Tarjeta 3: Visualización de datos persistidos en SQLite
                _buildSavedLocationsSection(theme, colorScheme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Construye la tarjeta principal que muestra la ubicación capturada y el conmutador de tiempo real.
  Widget _buildCurrentLocationCard(ThemeData theme, ColorScheme colorScheme) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _isRealtimeTracking ? Icons.sensors : Icons.location_on,
                  color: _isRealtimeTracking ? Colors.teal : colorScheme.primary,
                  size: 28,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _isRealtimeTracking
                        ? 'Rastreo en Tiempo Real (Activo)'
                        : 'Ubicación Reciente (Predeterminada)',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (_isLoading)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const Divider(height: 24),

            // Conmutador (Switch) para alternar al modo de rastreo en tiempo real
            Container(
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: SwitchListTile(
                title: const Text(
                  'Modo Tiempo Real',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  _isRealtimeTracking
                      ? 'Actualizando coordenadas de forma continua'
                      : 'Activar para escuchar cambios en vivo vía GPS/Red',
                ),
                value: _isRealtimeTracking,
                onChanged: _isLoading ? null : _toggleRealtimeTracking,
                secondary: Icon(
                  Icons.timeline,
                  color: _isRealtimeTracking ? colorScheme.primary : null,
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Desglose de coordenadas y parámetros de ubicación
            if (_currentPosition != null) ...[
              _buildDataRow(
                icon: Icons.my_location,
                label: 'Latitud',
                value: _currentPosition!.latitude.toStringAsFixed(6),
              ),
              _buildDataRow(
                icon: Icons.explore,
                label: 'Longitud',
                value: _currentPosition!.longitude.toStringAsFixed(6),
              ),
              _buildDataRow(
                icon: Icons.terrain,
                label: 'Altitud',
                value: '${_currentPosition!.altitude.toStringAsFixed(2)} m',
              ),
              _buildDataRow(
                icon: Icons.gps_fixed,
                label: 'Precisión',
                value: '±${_currentPosition!.accuracy.toStringAsFixed(2)} m',
              ),
              _buildDataRow(
                icon: Icons.speed,
                label: 'Velocidad',
                value: '${_currentPosition!.speed.toStringAsFixed(2)} m/s',
              ),
              _buildDataRow(
                icon: Icons.access_time,
                label: 'Timestamp Captura',
                value: _currentPosition!.timestamp.toLocal().toString().split('.').first,
              ),
            ] else ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24.0),
                child: Center(
                  child: Text(
                    _statusMessage ?? 'Sin datos de ubicación disponibles.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],

            if (_statusMessage != null && _currentPosition != null) ...[
              const SizedBox(height: 10),
              Text(
                'Estado: $_statusMessage',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontStyle: FontStyle.italic,
                  color: colorScheme.outline,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Construye los botones de acción para capturar/refrescar y guardar en SQLite.
  Widget _buildActionPanel(ColorScheme colorScheme) {
    return Row(
      children: [
        // Botón 1: Actualizar ubicación puntual
        Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: const Icon(Icons.my_location),
            label: const Text('Actualizar'),
            onPressed: _isLoading ? null : _fetchDefaultLocation,
          ),
        ),
        const SizedBox(width: 12),
        // Botón 2: Guardar la ubicación en la base de datos relacional SQLite
        Expanded(
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
              backgroundColor: colorScheme.primary,
              foregroundColor: colorScheme.onPrimary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: const Icon(Icons.save),
            label: const Text('Guardar'),
            onPressed: (_isLoading || _currentPosition == null)
                ? null
                : _saveCurrentLocation,
          ),
        ),
      ],
    );
  }

  /// Construye la sección que lista las ubicaciones persistidas en la tabla SQLite.
  Widget _buildSavedLocationsSection(ThemeData theme, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(Icons.storage, color: colorScheme.secondary),
                const SizedBox(width: 8),
                Text(
                  'Ubicaciones Guardadas en SQLite (${_savedLocations.length})',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            if (_savedLocations.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.delete_sweep, color: Colors.redAccent),
                tooltip: 'Limpiar todos los registros guardados',
                onPressed: () => _confirmClearAll(context),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (_savedLocations.isEmpty)
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Center(
                child: Text(
                  'No hay ubicaciones registradas en SQLite.\nPresione "Guardar" para almacenar la ubicación actual.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          )
        else
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _savedLocations.length,
            itemBuilder: (context, index) {
              final item = _savedLocations[index];
              final int id = item[DatabaseHelper.columnId] as int;
              final double lat = (item[DatabaseHelper.columnLatitude] as num).toDouble();
              final double lng = (item[DatabaseHelper.columnLongitude] as num).toDouble();
              final double alt = (item[DatabaseHelper.columnAltitude] as num).toDouble();
              final double acc = (item[DatabaseHelper.columnAccuracy] as num).toDouble();
              final String timestamp = item[DatabaseHelper.columnTimestamp]?.toString() ?? '';

              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: colorScheme.primaryContainer,
                    foregroundColor: colorScheme.onPrimaryContainer,
                    child: Text('#$id'),
                  ),
                  title: Text(
                    'Lat: ${lat.toStringAsFixed(5)}, Lng: ${lng.toStringAsFixed(5)}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    'Alt: ${alt.toStringAsFixed(1)} m | Precisión: ±${acc.toStringAsFixed(1)} m\nFecha: $timestamp',
                  ),
                  isThreeLine: true,
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.grey),
                    tooltip: 'Eliminar registro #$id',
                    onPressed: () => _deleteLocation(id),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  /// Cuadro de diálogo de confirmación para eliminar todo el historial en SQLite.
  void _confirmClearAll(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Eliminar todos los registros?'),
        content: const Text(
          'Esta acción borrará permanentemente todos los datos de ubicación guardados en la tabla SQLite.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              Navigator.of(ctx).pop();
              _clearAllLocations();
            },
            child: const Text('Eliminar Todo'),
          ),
        ],
      ),
    );
  }

  /// Fila reutilizable para visualización clara de parámetros de ubicación.
  Widget _buildDataRow({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.grey.shade600),
          const SizedBox(width: 8),
          Text(
            '$label: ',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }
}
