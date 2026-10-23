# PoC: Geolocalización y Persistencia de Datos

Este documento describe la interacción y el flujo técnico de la Prueba de Concepto (PoC) para la captura de geolocalización y persistencia en base de datos relacional SQLite mediante los siguientes dos diagramas.

---

## 1. Diagrama de Flujo: Uso e Interacción entre Botones y Controles

```mermaid
flowchart TD
    Start([Inicio de la Aplicación]) --> InitState[Verificar Permisos de Ubicación]
    InitState --> HasPerm{¿Permiso concedido?}
    
    HasPerm -- No --> RequestPerm[Solicitar Permisos al Usuario]
    RequestPerm --> PermGranted{¿Aceptó?}
    PermGranted -- No --> ShowError[Mostrar mensaje de error / denegado]
    PermGranted -- Yes --> FetchDefault[Obtener última ubicación conocida o actual]
    
    HasPerm -- Yes --> FetchDefault
    FetchDefault --> LoadDB[Cargar registros existentes desde SQLite]
    LoadDB --> ReadyUI[Interfaz Lista con Ubicación y Lista de Guardados]

    ReadyUI --> UserAction{Acción del Usuario}

    %% Conmutador Tiempo Real
    UserAction -- Conmutar Switch 'Modo Tiempo Real' --> ToggleRealtime{¿Activar o Desactivar?}
    ToggleRealtime -- Activar --> StartStream[Suscribir a Geolocator.getPositionStream]
    StartStream --> StreamLoop[Recibir actualizaciones continuas de coordenadas]
    StreamLoop --> UpdateUI[Actualizar coordenadas en pantalla en tiempo real]
    ToggleRealtime -- Desactivar --> StopStream[Cancelar suscripción al Stream]
    StopStream --> Standby[Pausar consumo de GPS / Modo reposo]

    %% Botón Actualizar
    UserAction -- Presionar Botón 'Actualizar' --> ManualFetch[Consultar posición actual mediante GPS]
    ManualFetch --> UpdateUI

    %% Botón Guardar
    UserAction -- Presionar Botón 'Guardar' --> CheckPos{¿Existe ubicación actual?}
    CheckPos -- No --> AlertNoPos[Mostrar alerta: Sin ubicación disponible]
    CheckPos -- Yes --> PrepareData[Mapear latitud, longitud, altitud, precisión, velocidad y timestamp]
    PrepareData --> InsertSQLite[Ejecutar INSERT en tabla 'locations' de SQLite]
    InsertSQLite --> RefreshList[Recargar lista de ubicaciones desde SQLite]
    RefreshList --> ShowSuccess[Mostrar SnackBar de confirmación con ID de registro]

    %% Botón Eliminar / Limpiar
    UserAction -- Presionar 'Eliminar' o 'Limpiar' --> DeleteRecord[Ejecutar DELETE en SQLite]
    DeleteRecord --> RefreshList
```

---

## 2. Diagrama de Secuencia: Captura y Almacenamiento de Ubicación

```mermaid
sequenceDiagram
    autonumber
    actor Usuario as Usuario
    participant UI as Interfaz (GeolocationPage)
    participant Geo as Geolocator (Plugin)
    participant GPS as Sensor GPS / SO
    participant DB as DatabaseHelper
    participant SQLite as Base de Datos SQLite (sqflite)

    %% Fase 1: Captura de Ubicación
    rect rgb(240, 248, 255)
        Note over Usuario, GPS: Fase de Captura de Ubicación
        Usuario->>UI: Presiona "Actualizar" o activa "Modo Tiempo Real"
        UI->>Geo: isLocationServiceEnabled() & checkPermission()
        Geo-->>UI: Servicio activo & Permiso concedido
        alt Modo Tiempo Real Activado
            UI->>Geo: getPositionStream(locationSettings)
            loop Cada cambio de posición (distancia >= 2m)
                Geo->>GPS: Solicitar coordenadas periódicas
                GPS-->>Geo: Datos brutos de GPS
                Geo-->>UI: emit(Position)
                UI->>UI: setState(_currentPosition)
            end
        else Actualización Puntual
            UI->>Geo: getCurrentPosition(accuracy: high)
            Geo->>GPS: Obtener fijación satelital / red
            GPS-->>Geo: Coordenadas actuales
            Geo-->>UI: Retorna Position
            UI->>UI: setState(_currentPosition)
        end
        UI-->>Usuario: Muestra coordenadas en pantalla (Lat, Lng, Alt, Precisión)
    end

    %% Fase 2: Almacenamiento Persistente
    rect rgb(245, 255, 245)
        Note over Usuario, SQLite: Fase de Almacenamiento de Datos
        Usuario->>UI: Presiona botón "Guardar"
        UI->>UI: Valida _currentPosition != null
        UI->>UI: Construye Map con lat, lng, alt, accuracy, speed, timestamp
        UI->>DB: insertLocation(locationMap)
        DB->>SQLite: INSERT INTO locations (latitude, longitude, altitude, accuracy, speed, timestamp) VALUES (...)
        SQLite-->>DB: Retorna rowId generado
        DB-->>UI: Retorna id del nuevo registro
        
        %% Actualización del listado
        UI->>DB: getLocations()
        DB->>SQLite: SELECT * FROM locations ORDER BY id DESC
        SQLite-->>DB: Retorna List<Map<String, dynamic>>
        DB-->>UI: Retorna lista actualizada
        UI->>UI: setState(_savedLocations)
        UI-->>Usuario: Muestra SnackBar de éxito y actualiza la lista visual
    end
```
