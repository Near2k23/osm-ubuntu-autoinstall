sudo bash -c '
set -e

echo "=== Creando sistema de exportación CSV de Nominatim ==="

# 1. Crear directorio público
echo "Creando directorio público..."
mkdir -p /srv/nominatim/public
chown -R www-data:www-data /srv/nominatim/public

# 2. Crear script de exportación
echo "Creando script de exportación..."
cat > /srv/nominatim/export_addresses.py << '\''EOF'\''
#!/usr/bin/env python3
import os
import csv
import json
import time
import subprocess
from datetime import datetime
import threading

class NominatimAddressExporter:
    def __init__(self):
        self.db_name = "nominatim"
        self.db_user = "postgres"
        self.public_dir = "/srv/nominatim/public"
        self.csv_file = os.path.join(self.public_dir, "addresses_export.csv")
        self.progress_file = os.path.join(self.public_dir, "export_progress.json")
        self.log_file = os.path.join(self.public_dir, "export_log.txt")
        
        os.makedirs(self.public_dir, exist_ok=True)
        
    def log(self, message):
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        log_message = f"[{timestamp}] {message}\n"
        
        with open(self.log_file, "a") as f:
            f.write(log_message)
        
        print(log_message.strip())
    
    def update_progress(self, current, total, status="running"):
        progress_data = {
            "current": current,
            "total": total,
            "percentage": round((current / total) * 100, 2) if total > 0 else 0,
            "status": status,
            "timestamp": datetime.now().isoformat(),
            "csv_file": self.csv_file if status == "completed" else None
        }
        
        with open(self.progress_file, "w") as f:
            json.dump(progress_data, f, indent=2)
    
    def execute_psql_query(self, query):
        cmd = [
            "sudo", "-u", "postgres", "psql", 
            "-d", self.db_name, 
            "-c", query,
            "-t",
            "--csv"
        ]
        
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            return result.stdout.strip()
        except subprocess.CalledProcessError as e:
            self.log(f"Error ejecutando consulta: {e}")
            return None
    
    def get_total_addresses(self):
        query = """
        SELECT COUNT(*) 
        FROM placex 
        WHERE housenumber IS NOT NULL 
        AND housenumber != '\'''\''
        """
        
        result = self.execute_psql_query(query)
        if result:
            return int(result.strip())
        return 0
    
    def export_addresses(self):
        self.log("Iniciando exportación de direcciones...")
        
        total_addresses = self.get_total_addresses()
        self.log(f"Total de direcciones a exportar: {total_addresses:,}")
        
        if total_addresses == 0:
            self.log("No se encontraron direcciones para exportar")
            self.update_progress(0, 0, "error")
            return False
        
        self.update_progress(0, total_addresses, "starting")
        
        query = """
        COPY (
            SELECT 
                COALESCE(housenumber, '\''\'') as house_number,
                COALESCE(address->\''street\'', '\''\'') as street_name,
                COALESCE(address->\''city\'', '\''\'') as city,
                COALESCE(address->\''county\'', '\''\'') as county,
                COALESCE(address->\''state\'', '\''\'') as state,
                COALESCE(address->\''state_code\'', '\''\'') as state_code,
                COALESCE(address->\''postcode\'', '\''\'') as zip_code,
                COALESCE(address->\''country\'', \''United States\'') as country,
                COALESCE(address->\''country_code\'', \''US\'') as country_code,
                CONCAT(lat, \'',\'', lon) as coordinates
            FROM placex 
            WHERE housenumber IS NOT NULL 
            AND housenumber != '\'''\''
            ORDER BY 
                address->\''state\'', 
                address->\''city\'', 
                address->\''street\'', 
                housenumber
        ) TO STDOUT WITH CSV HEADER
        """
        
        try:
            cmd = [
                "sudo", "-u", "postgres", "psql", 
                "-d", self.db_name, 
                "-c", query
            ]
            
            self.log("Ejecutando exportación directa a CSV...")
            
            with open(self.csv_file, "w") as f:
                process = subprocess.Popen(
                    cmd, 
                    stdout=f, 
                    stderr=subprocess.PIPE,
                    text=True
                )
                
                def monitor_progress():
                    while process.poll() is None:
                        try:
                            if os.path.exists(self.csv_file):
                                with open(self.csv_file, "r") as temp_f:
                                    current_lines = sum(1 for _ in temp_f) - 1
                                    if current_lines > 0:
                                        self.update_progress(current_lines, total_addresses, "running")
                        except:
                            pass
                        time.sleep(5)
                
                progress_thread = threading.Thread(target=monitor_progress)
                progress_thread.daemon = True
                progress_thread.start()
                
                stderr_output = process.communicate()[1]
                
                if process.returncode == 0:
                    self.log("Exportación completada exitosamente")
                    self.update_progress(total_addresses, total_addresses, "completed")
                    return True
                else:
                    self.log(f"Error en exportación: {stderr_output}")
                    self.update_progress(0, total_addresses, "error")
                    return False
        
        except Exception as e:
            self.log(f"Error durante la exportación: {str(e)}")
            self.update_progress(0, total_addresses, "error")
            return False
    
    def run(self):
        start_time = time.time()
        
        try:
            success = self.export_addresses()
            
            end_time = time.time()
            duration = end_time - start_time
            
            if success:
                if os.path.exists(self.csv_file):
                    file_size = os.path.getsize(self.csv_file)
                    self.log(f"Archivo CSV generado: {self.csv_file}")
                    self.log(f"Tamaño del archivo: {file_size / (1024*1024):.2f} MB")
                    self.log(f"Tiempo total: {duration/60:.2f} minutos")
                    
                    with open(self.csv_file, "r") as f:
                        total_lines = sum(1 for _ in f) - 1
                    
                    self.log(f"Total de direcciones exportadas: {total_lines:,}")
                    return True
                else:
                    self.log("Error: No se pudo generar el archivo CSV")
                    return False
            else:
                self.log("La exportación falló")
                return False
                
        except Exception as e:
            self.log(f"Error crítico: {str(e)}")
            self.update_progress(0, 0, "error")
            return False

if __name__ == "__main__":
    exporter = NominatimAddressExporter()
    exporter.run()
EOF

# 3. Hacer ejecutable el script
chmod +x /srv/nominatim/export_addresses.py

# 4. Crear página web de progreso
cat > /srv/nominatim/public/index.html << '\''EOF'\''
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Exportación CSV - Nominatim</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            max-width: 800px;
            margin: 0 auto;
            padding: 20px;
            background-color: #f5f5f5;
        }
        .container {
            background: white;
            padding: 30px;
            border-radius: 10px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        }
        h1 {
            color: #333;
            text-align: center;
        }
        .progress-container {
            margin: 20px 0;
        }
        .progress-bar {
            width: 100%;
            height: 30px;
            background-color: #e0e0e0;
            border-radius: 15px;
            overflow: hidden;
        }
        .progress-fill {
            height: 100%;
            background: linear-gradient(90deg, #4CAF50, #8BC34A);
            transition: width 0.3s ease;
            border-radius: 15px;
        }
        .progress-text {
            text-align: center;
            margin: 10px 0;
            font-size: 18px;
            font-weight: bold;
        }
        .status {
            padding: 10px;
            margin: 10px 0;
            border-radius: 5px;
            text-align: center;
        }
        .status.running { background-color: #e3f2fd; color: #1976d2; }
        .status.completed { background-color: #e8f5e8; color: #4caf50; }
        .status.error { background-color: #ffebee; color: #f44336; }
        .status.starting { background-color: #fff3e0; color: #ff9800; }
        .info-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin: 20px 0;
        }
        .info-card {
            background: #f8f9fa;
            padding: 15px;
            border-radius: 8px;
            border-left: 4px solid #2196F3;
        }
        .info-card h3 {
            margin: 0 0 10px 0;
            color: #333;
        }
        .info-card p {
            margin: 0;
            font-size: 24px;
            font-weight: bold;
            color: #2196F3;
        }
        .buttons {
            text-align: center;
            margin: 20px 0;
        }
        button {
            padding: 12px 24px;
            margin: 0 10px;
            border: none;
            border-radius: 5px;
            cursor: pointer;
            font-size: 16px;
            transition: background-color 0.3s;
        }
        .btn-primary {
            background-color: #2196F3;
            color: white;
        }
        .btn-primary:hover {
            background-color: #1976D2;
        }
        .btn-success {
            background-color: #4CAF50;
            color: white;
        }
        .btn-success:hover {
            background-color: #45a049;
        }
        .log-container {
            background: #f8f9fa;
            border: 1px solid #e9ecef;
            border-radius: 5px;
            padding: 15px;
            margin: 20px 0;
            max-height: 300px;
            overflow-y: auto;
        }
        .log-header {
            font-weight: bold;
            margin-bottom: 10px;
        }
        .log-content {
            font-family: monospace;
            font-size: 12px;
            line-height: 1.4;
            white-space: pre-wrap;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Exportación CSV de Direcciones</h1>
        <p style="text-align: center; color: #666;">
            Sistema de exportación de direcciones de Nominatim a formato CSV
        </p>
        
        <div class="progress-container">
            <div class="progress-bar">
                <div class="progress-fill" id="progressFill" style="width: 0%"></div>
            </div>
            <div class="progress-text" id="progressText">0%</div>
        </div>
        
        <div class="status" id="statusDiv">
            Esperando datos...
        </div>
        
        <div class="info-grid">
            <div class="info-card">
                <h3>Procesadas</h3>
                <p id="currentCount">0</p>
            </div>
            <div class="info-card">
                <h3>Total</h3>
                <p id="totalCount">0</p>
            </div>
            <div class="info-card">
                <h3>Progreso</h3>
                <p id="percentageText">0%</p>
            </div>
            <div class="info-card">
                <h3>Última actualización</h3>
                <p id="lastUpdate">-</p>
            </div>
        </div>
        
        <div class="buttons">
            <button class="btn-primary" onclick="startExport()">Iniciar Exportación</button>
            <button class="btn-success" onclick="downloadCSV()" id="downloadBtn" style="display: none;">Descargar CSV</button>
        </div>
        
        <div class="log-container">
            <div class="log-header">Logs de Exportación:</div>
            <div class="log-content" id="logContent">
                Esperando inicio de exportación...
            </div>
        </div>
    </div>

    <script>
        let updateInterval;
        
        function updateProgress() {
            fetch('\''export_progress.json?'\'' + new Date().getTime())
                .then(response => response.json())
                .then(data => {
                    document.getElementById('\''progressFill\'').style.width = data.percentage + '\''%\'';
                    document.getElementById('\''progressText\'').textContent = data.percentage + '\''%\'';
                    document.getElementById('\''currentCount\'').textContent = data.current.toLocaleString();
                    document.getElementById('\''totalCount\'').textContent = data.total.toLocaleString();
                    document.getElementById('\''percentageText\'').textContent = data.percentage + '\''%\'';
                    document.getElementById('\''lastUpdate\'').textContent = new Date(data.timestamp).toLocaleTimeString();
                    
                    const statusDiv = document.getElementById('\''statusDiv\'');
                    statusDiv.className = '\''status '\'' + data.status;
                    
                    switch(data.status) {
                        case '\''starting\'':
                            statusDiv.textContent = '\''Iniciando exportación...\'';
                            break;
                        case '\''running\'':
                            statusDiv.textContent = '\''Exportando direcciones...\'';
                            break;
                        case '\''completed\'':
                            statusDiv.textContent = '\''Exportación completada exitosamente\'';
                            document.getElementById('\''downloadBtn\'').style.display = '\''inline-block\'';
                            clearInterval(updateInterval);
                            break;
                        case '\''error\'':
                            statusDiv.textContent = '\''Error durante la exportación\'';
                            clearInterval(updateInterval);
                            break;
                    }
                })
                .catch(error => {
                    console.error('\''Error actualizando progreso:\'', error);
                });
        }
        
        function updateLogs() {
            fetch('\''export_log.txt?'\'' + new Date().getTime())
                .then(response => response.text())
                .then(data => {
                    document.getElementById('\''logContent\'').textContent = data;
                })
                .catch(error => {
                    console.error('\''Error actualizando logs:\'', error);
                });
        }
        
        function startExport() {
            fetch('\''/start_export'\'', {method: '\''POST'\''})
                .then(response => response.json())
                .then(data => {
                    if (data.success) {
                        updateInterval = setInterval(() => {
                            updateProgress();
                            updateLogs();
                        }, 2000);
                    } else {
                        alert('\''Error iniciando exportación: '\'' + data.message);
                    }
                })
                .catch(error => {
                    console.error('\''Error iniciando exportación:\'', error);
                    alert('\''Error iniciando exportación\'');
                });
        }
        
        function downloadCSV() {
            window.location.href = '\''addresses_export.csv\'';
        }
        
        // Iniciar actualización automática al cargar la página
        window.onload = function() {
            updateProgress();
            updateLogs();
            updateInterval = setInterval(() => {
                updateProgress();
                updateLogs();
            }, 3000);
        };
    </script>
</body>
</html>
EOF

# 5. Crear API endpoint para iniciar exportación
cat > /srv/nominatim/public/start_export.php << '\''EOF'\''
<?php
header('\''Content-Type: application/json'\'');
header('\''Access-Control-Allow-Origin: *'\'');
header('\''Access-Control-Allow-Methods: POST'\'');
header('\''Access-Control-Allow-Headers: Content-Type'\'');

if ($_SERVER['\''REQUEST_METHOD'\''] === '\''POST'\'') {
    $output = [];
    $return_var = 0;
    
    // Ejecutar exportación en segundo plano
    $command = '\''nohup /usr/bin/python3 /srv/nominatim/export_addresses.py > /dev/null 2>&1 &'\'';
    exec($command, $output, $return_var);
    
    if ($return_var === 0) {
        echo json_encode([
            '\''success'\'' => true,
            '\''message'\'' => '\''Exportación iniciada exitosamente'\''
        ]);
    } else {
        echo json_encode([
            '\''success'\'' => false,
            '\''message'\'' => '\''Error iniciando exportación'\''
        ]);
    }
} else {
    echo json_encode([
        '\''success'\'' => false,
        '\''message'\'' => '\''Método no permitido'\''
    ]);
}
?>
EOF

# 6. Configurar Apache para directorio público
cat > /etc/apache2/sites-available/nominatim-public.conf << '\''EOF'\''
<VirtualHost *:8080>
    ServerName 20.120.240.158
    DocumentRoot /srv/nominatim/public
    
    <Directory "/srv/nominatim/public">
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
        
        # Habilitar CORS
        Header always set Access-Control-Allow-Origin "*"
        Header always set Access-Control-Allow-Methods "GET, POST, OPTIONS"
        Header always set Access-Control-Allow-Headers "Content-Type"
        
        # Configurar PHP
        DirectoryIndex index.html index.php
        
        # Rewrite rules para la API
        RewriteEngine On
        RewriteRule ^start_export$ start_export.php [L]
    </Directory>
    
    # Tipos MIME
    AddType application/json .json
    AddType text/plain .txt
    AddType text/csv .csv
    
    ErrorLog ${APACHE_LOG_DIR}/nominatim-public_error.log
    CustomLog ${APACHE_LOG_DIR}/nominatim-public_access.log combined
</VirtualHost>
EOF

# 7. Habilitar sitio y módulos
a2enmod headers
a2enmod rewrite
a2ensite nominatim-public
systemctl reload apache2

# 8. Crear comando de inicio rápido
cat > /usr/local/bin/export-nominatim-csv << '\''EOF'\''
#!/bin/bash
echo "Iniciando exportación CSV de Nominatim..."
/usr/bin/python3 /srv/nominatim/export_addresses.py
EOF

chmod +x /usr/local/bin/export-nominatim-csv

# 9. Configurar permisos
chown -R www-data:www-data /srv/nominatim/public
chmod 755 /srv/nominatim/export_addresses.py

echo "=== INSTALACIÓN COMPLETADA ==="
echo ""
echo "Sistema de exportación CSV creado exitosamente:"
echo ""
echo "• Interfaz web: http://20.120.240.158:8080"
echo "• Script de exportación: /srv/nominatim/export_addresses.py"
echo "• Directorio público: /srv/nominatim/public"
echo "• Comando rápido: export-nominatim-csv"
echo ""
echo "Para iniciar la exportación:"
echo "1. Accede a http://20.120.240.158:8080"
echo "2. Haz clic en '\''Iniciar Exportación'\''"
echo "3. Monitorea el progreso en tiempo real"
echo ""
echo "El archivo CSV se guardará en: /srv/nominatim/public/addresses_export.csv"
echo "URL de descarga: http://20.120.240.158:8080/addresses_export.csv"
'

echo "=== SISTEMA CREADO EXITOSAMENTE ==="
echo ""
echo "Tu sistema de exportación CSV está listo:"
echo ""
echo "🌐 Interfaz web: http://20.120.240.158:8080"
echo "📁 Directorio público: /srv/nominatim/public"
echo "🚀 Comando rápido: export-nominatim-csv"
echo ""
echo "Para usar:"
echo "1. Accede a http://20.120.240.158:8080"
echo "2. Haz clic en 'Iniciar Exportación'"
echo "3. Monitorea el progreso en tiempo real"
echo "4. Descarga el CSV cuando termine"
