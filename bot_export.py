import os
import csv
import json
import time
import subprocess
from datetime import datetime
import threading

class NominatimCompleteExporter:
    def __init__(self):
        self.db_name = "nominatim"
        self.db_user = "postgres"
        self.public_dir = "/srv/nominatim/public"
        self.csv_file = os.path.join(self.public_dir, "all_places_export.csv")
        self.progress_file = os.path.join(self.public_dir, "export_progress.json")
        self.log_file = os.path.join(self.public_dir, "export_log.txt")
        
        os.makedirs(self.public_dir, exist_ok=True)
        
    def log(self, message):
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        log_message = f"[{timestamp}] {message}\n"
        
        try:
            with open(self.log_file, "a") as f:
                f.write(log_message)
        except:
            pass
        
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
        
        try:
            with open(self.progress_file, "w") as f:
                json.dump(progress_data, f, indent=2)
        except:
            pass
    
    def execute_psql_query(self, query):
        """Ejecutar consulta SQL usando psql"""
        cmd = [
            'sudo', '-u', 'postgres', 'psql', 
            '-d', self.db_name, 
            '-c', query,
            '-t',  # Solo datos, sin headers
            '-A'   # Formato sin alineación
        ]
        
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            return result.stdout.strip()
        except subprocess.CalledProcessError as e:
            self.log(f"Error ejecutando consulta: {e}")
            if e.stderr:
                self.log(f"STDERR: {e.stderr}")
            return None
    
    def get_total_places(self):
        """Obtener total de lugares en la base de datos"""
        query = "SELECT COUNT(*) FROM placex"
        
        result = self.execute_psql_query(query)
        if result and result.strip().isdigit():
            return int(result.strip())
        
        return 0
    
    def export_all_places_direct(self):
        """Exportar todos los lugares usando COPY directo desde PostgreSQL"""
        self.log("Exportando TODOS los lugares de Nominatim (con y sin números de casa)")
        
        # Consulta COPY para exportación completa
        copy_query = f"""
        COPY (
            SELECT 
                COALESCE(housenumber, '') as house_number,
                COALESCE(address->'street', '') as street_name,
                COALESCE(address->'city', '') as city,
                COALESCE(address->'county', '') as county,
                COALESCE(address->'state', '') as state,
                COALESCE(address->'state_code', '') as state_code,
                COALESCE(postcode, '') as zip_code,
                COALESCE(country_code, 'US') as country_code,
                'United States' as country,
                ST_Y(centroid) || ',' || ST_X(centroid) as coordinates,
                class as place_class,
                type as place_type,
                name->'name' as place_name,
                COALESCE(address->'suburb', '') as suburb,
                COALESCE(address->'neighbourhood', '') as neighbourhood,
                importance,
                rank_address,
                rank_search
            FROM placex 
            ORDER BY 
                importance DESC NULLS LAST,
                rank_address,
                country_code,
                address->'state', 
                address->'city', 
                address->'street', 
                housenumber
        ) TO '{self.csv_file}' WITH CSV HEADER
        """
        
        cmd = [
            'sudo', '-u', 'postgres', 'psql', 
            '-d', self.db_name, 
            '-c', copy_query
        ]
        
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            
            # Cambiar permisos del archivo CSV
            os.system(f"sudo chown www-data:www-data {self.csv_file}")
            os.system(f"sudo chmod 644 {self.csv_file}")
            
            return True
            
        except subprocess.CalledProcessError as e:
            self.log(f"Error en exportación directa: {e}")
            if e.stderr:
                self.log(f"STDERR: {e.stderr}")
            return False
    
    def export_places(self):
        """Exportar todos los lugares a CSV"""
        self.log("Iniciando exportación COMPLETA de lugares...")
        
        # Obtener total de registros
        total_places = self.get_total_places()
        self.log(f"Total de lugares a exportar: {total_places:,}")
        
        if total_places == 0:
            self.log("No se encontraron lugares para exportar")
            self.update_progress(0, 0, "error")
            return False
        
        # Inicializar progreso
        self.update_progress(0, total_places, "starting")
        
        # Usar método directo de PostgreSQL
        success = self.export_all_places_direct()
        
        if success:
            self.log("Exportación completada exitosamente")
            self.update_progress(total_places, total_places, "completed")
            return True
        else:
            self.log("La exportación falló")
            self.update_progress(0, total_places, "error")
            return False
    
    def run(self):
        """Ejecutar exportación completa"""
        start_time = time.time()
        
        try:
            success = self.export_places()
            
            end_time = time.time()
            duration = end_time - start_time
            
            if success:
                if os.path.exists(self.csv_file):
                    file_size = os.path.getsize(self.csv_file)
                    self.log(f"Archivo CSV generado: {self.csv_file}")
                    self.log(f"Tamaño del archivo: {file_size / (1024*1024):.2f} MB")
                    self.log(f"Tiempo total: {duration/60:.2f} minutos")
                    
                    # Contar líneas del archivo final
                    try:
                        with open(self.csv_file, 'r') as f:
                            total_lines = sum(1 for _ in f) - 1  # -1 para header
                        self.log(f"Total de lugares exportados: {total_lines:,}")
                    except:
                        self.log("Archivo CSV generado (no se pudo contar líneas)")
                    
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
    exporter = NominatimCompleteExporter()
    exporter.run()
