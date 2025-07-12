#!/bin/bash

# Script de instalación automatizada de Nominatim en Ubuntu
# Versión corregida que soluciona problemas de Python y entornos virtuales
# Autor: Configuración personalizada para geocodificación privada
# Fecha: 2025-07-12

set -e  # Salir si hay algún error

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Función para logging
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

info() {
    echo -e "${BLUE}[INFO] $1${NC}"
}

# Configuración inicial
NOMINATIM_USER="nominatim"
NOMINATIM_HOME="/srv/nominatim"
PROJECT_DIR="/srv/nominatim/project"
POSTGRES_VERSION="16"
APACHE_SITE="nominatim"

# Configuración de datos a importar
PBF_REGION=""
PBF_URL=""
REPLICATION_URL=""
IMPORT_STYLE="address"
THREADS=$(nproc)

# Función para verificar recursos del sistema
check_system_resources() {
    log "Verificando recursos del sistema..."
    
    local required_ram_gb=4
    local required_disk_gb=30
    
    # Verificar RAM
    local total_ram=$(free -g | awk '/^Mem:/{print $2}')
    if [ "$total_ram" -lt "$required_ram_gb" ]; then
        warning "RAM insuficiente: ${total_ram}GB disponible, ${required_ram_gb}GB recomendado"
        read -p "¿Continuar de todas formas? (y/N): " continue_anyway
        [[ ! $continue_anyway =~ ^[Yy]$ ]] && error "Instalación cancelada"
    fi
    
    # Verificar espacio en disco
    local available_disk=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    if [ "$available_disk" -lt "$required_disk_gb" ]; then
        error "Espacio insuficiente: ${available_disk}GB disponible, ${required_disk_gb}GB requerido"
    fi
    
    log "Recursos del sistema verificados correctamente"
}

# Función para mostrar menú de selección de región
select_region() {
    echo -e "${BLUE}Selecciona la región a importar:${NC}"
    echo "1) Estados Unidos completo (~12GB, 8-12 horas)"
    echo "2) New York (~500MB, 2-3 horas)"
    echo "3) California (~2GB, 3-4 horas)"
    echo "4) Texas (~1.5GB, 2-3 horas)"
    echo "5) Florida (~800MB, 1-2 horas)"
    echo "6) Personalizado (ingresa URLs manualmente)"
    
    read -p "Ingresa tu opción (1-6): " region_choice
    
    case $region_choice in
        1)
            PBF_REGION="us"
            PBF_URL="https://download.geofabrik.de/north-america/us-latest.osm.pbf"
            REPLICATION_URL="https://download.geofabrik.de/north-america/us-updates/"
            ;;
        2)
            PBF_REGION="new-york"
            PBF_URL="https://download.geofabrik.de/north-america/us/new-york-latest.osm.pbf"
            REPLICATION_URL="https://download.geofabrik.de/north-america/us/new-york-updates/"
            ;;
        3)
            PBF_REGION="california"
            PBF_URL="https://download.geofabrik.de/north-america/us/california-latest.osm.pbf"
            REPLICATION_URL="https://download.geofabrik.de/north-america/us/california-updates/"
            ;;
        4)
            PBF_REGION="texas"
            PBF_URL="https://download.geofabrik.de/north-america/us/texas-latest.osm.pbf"
            REPLICATION_URL="https://download.geofabrik.de/north-america/us/texas-updates/"
            ;;
        5)
            PBF_REGION="florida"
            PBF_URL="https://download.geofabrik.de/north-america/us/florida-latest.osm.pbf"
            REPLICATION_URL="https://download.geofabrik.de/north-america/us/florida-updates/"
            ;;
        6)
            read -p "Ingresa la URL del archivo PBF: " PBF_URL
            read -p "Ingresa la URL de replicación: " REPLICATION_URL
            PBF_REGION="custom"
            ;;
        *)
            error "Opción inválida"
            ;;
    esac
}

# Función para verificar si el script se ejecuta como root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        error "Este script no debe ejecutarse como root. Usa un usuario con sudo."
    fi
}

# Función para actualizar el sistema
update_system() {
    log "Actualizando el sistema..."
    sudo apt update && sudo apt upgrade -y
    log "Sistema actualizado correctamente"
}

# Función para instalar dependencias
install_dependencies() {
    log "Instalando dependencias..."
    
    sudo apt install -y \
        build-essential \
        cmake \
        g++ \
        libboost-dev \
        libboost-system-dev \
        libboost-filesystem-dev \
        libexpat1-dev \
        zlib1g-dev \
        libbz2-dev \
        libpq-dev \
        libproj-dev \
        postgresql \
        postgresql-contrib \
        postgresql-server-dev-$POSTGRES_VERSION \
        php \
        php-pgsql \
        php-intl \
        apache2 \
        libapache2-mod-php \
        wget \
        curl \
        git \
        python3 \
        python3-pip \
        python3-dev \
        python3-psycopg2 \
        python3-full \
        python3.12-venv \
        python3-venv \
        htop \
        unzip \
        osmium-tool \
        software-properties-common
    
    log "Dependencias instaladas correctamente"
}

# Función para configurar PostgreSQL
configure_postgresql() {
    log "Configurando PostgreSQL..."
    
    # Crear usuario nominatim
    sudo -u postgres createuser -s $NOMINATIM_USER 2>/dev/null || true
    sudo -u postgres createuser www-data 2>/dev/null || true
    
    # Configurar PostgreSQL para mejor rendimiento
    sudo tee /etc/postgresql/$POSTGRES_VERSION/main/conf.d/nominatim.conf > /dev/null <<EOF
# Configuración optimizada para Nominatim
shared_buffers = 2GB
maintenance_work_mem = 4GB
autovacuum_work_mem = 2GB
work_mem = 50MB
effective_cache_size = 8GB
synchronous_commit = off
max_wal_size = 1GB
checkpoint_timeout = 10min
checkpoint_completion_target = 0.9
random_page_cost = 1.1
EOF
    
    # Reiniciar PostgreSQL
    sudo systemctl restart postgresql
    sudo systemctl enable postgresql
    
    log "PostgreSQL configurado correctamente"
}

# Función para crear usuario nominatim
create_nominatim_user() {
    log "Creando usuario nominatim..."
    
    if ! id "$NOMINATIM_USER" &>/dev/null; then
        sudo useradd -d $NOMINATIM_HOME -s /bin/bash -m $NOMINATIM_USER
        sudo usermod -aG www-data $NOMINATIM_USER
    fi
    
    # Crear directorios necesarios
    sudo mkdir -p $NOMINATIM_HOME
    sudo mkdir -p $PROJECT_DIR
    sudo chown -R $NOMINATIM_USER:$NOMINATIM_USER $NOMINATIM_HOME
    
    log "Usuario nominatim creado correctamente"
}

# Función para instalar Nominatim (versión corregida)
install_nominatim() {
    log "Instalando Nominatim..."
    
    # Método 1: Intentar instalación desde repositorio oficial
    if sudo add-apt-repository -y ppa:nominatim/ppa 2>/dev/null && sudo apt update 2>/dev/null; then
        log "Instalando desde repositorio oficial..."
        if sudo apt install -y nominatim 2>/dev/null; then
            sudo -u $NOMINATIM_USER bash <<EOF
mkdir -p $PROJECT_DIR
cd $PROJECT_DIR
nominatim config --project-dir $PROJECT_DIR
EOF
            log "Nominatim instalado desde repositorio oficial"
            return 0
        fi
    fi
    
    # Método 2: Instalación con entorno virtual (fallback)
    log "Instalando en entorno virtual..."
    
    sudo -u $NOMINATIM_USER bash <<'EOF'
cd $NOMINATIM_HOME

# Crear entorno virtual
python3 -m venv nominatim-venv
source nominatim-venv/bin/activate

# Actualizar pip
pip install --upgrade pip

# Instalar Nominatim
pip install nominatim-db nominatim-api

# Crear wrapper script
mkdir -p ~/.local/bin
cat > ~/.local/bin/nominatim << 'WRAPPER'
#!/bin/bash
source /srv/nominatim/nominatim-venv/bin/activate
exec /srv/nominatim/nominatim-venv/bin/nominatim "$@"
WRAPPER

chmod +x ~/.local/bin/nominatim

# Agregar al PATH
echo 'export PATH=$PATH:$HOME/.local/bin' >> ~/.bashrc

# Configurar proyecto
mkdir -p /srv/nominatim/project
cd /srv/nominatim/project
~/.local/bin/nominatim config --project-dir /srv/nominatim/project
EOF
    
    log "Nominatim instalado correctamente en entorno virtual"
}

# Función para descargar datos OSM
download_osm_data() {
    log "Descargando datos OSM para $PBF_REGION..."
    
    local pbf_file="$PROJECT_DIR/$(basename $PBF_URL)"
    
    sudo -u $NOMINATIM_USER bash <<EOF
cd $PROJECT_DIR
wget -c "$PBF_URL" -O "$pbf_file"
EOF
    
    log "Datos OSM descargados correctamente"
}

# Función para importar datos
import_data() {
    log "Iniciando importación de datos (esto puede tomar varias horas)..."
    
    local pbf_file="$PROJECT_DIR/$(basename $PBF_URL)"
    
    sudo -u $NOMINATIM_USER bash <<EOF
cd $PROJECT_DIR
export PATH=\$PATH:\$HOME/.local/bin

# Verificar si nominatim está disponible
if command -v nominatim >/dev/null 2>&1; then
    NOMINATIM_CMD="nominatim"
else
    NOMINATIM_CMD="\$HOME/.local/bin/nominatim"
fi

\$NOMINATIM_CMD import --osm-file "$pbf_file" \
    --threads $THREADS \
    --project-dir $PROJECT_DIR \
    --import-style $IMPORT_STYLE

# Configurar replicación
\$NOMINATIM_CMD replication --init --project-dir $PROJECT_DIR
EOF
    
    log "Importación de datos completada"
}

# Función para configurar Apache
configure_apache() {
    log "Configurando Apache..."
    
    # Crear configuración del sitio
    sudo tee /etc/apache2/sites-available/$APACHE_SITE.conf > /dev/null <<EOF
<VirtualHost *:80>
    ServerName $(hostname -f)
    DocumentRoot $PROJECT_DIR/website
    
    <Directory "$PROJECT_DIR/website">
        Options FollowSymLinks MultiViews
        AddType application/json .php
        DirectoryIndex search.php
        Require all granted
    </Directory>
    
    Alias /nominatim $PROJECT_DIR/website
    
    ErrorLog \${APACHE_LOG_DIR}/nominatim_error.log
    CustomLog \${APACHE_LOG_DIR}/nominatim_access.log combined
</VirtualHost>
EOF
    
    # Habilitar módulos y sitio
    sudo a2enmod rewrite
    # Esta línea busca la versión de PHP, ajusta si tu versión es diferente
    sudo a2enmod php8.1 2>/dev/null || sudo a2enmod php8.2 2>/dev/null || sudo a2enmod php 2>/dev/null || true
    sudo a2ensite $APACHE_SITE
    sudo a2dissite 000-default 2>/dev/null || true
    
    # Reiniciar Apache
    sudo systemctl restart apache2
    sudo systemctl enable apache2
    
    log "Apache configurado correctamente"
}

# Función para configurar firewall
configure_firewall() {
    log "Configurando firewall..."
    
    sudo ufw allow ssh
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp
    sudo ufw --force enable
    
    log "Firewall configurado correctamente"
}

# Función para crear scripts de mantenimiento
create_maintenance_scripts() {
    log "Creando scripts de mantenimiento..."
    
    # Script de actualización
    sudo tee /usr/local/bin/nominatim-update > /dev/null <<EOF
#!/bin/bash
cd $PROJECT_DIR
export PATH=\$PATH:/srv/nominatim/.local/bin
sudo -u $NOMINATIM_USER bash -c "source ~/.bashrc && nominatim replication --project-dir $PROJECT_DIR"
EOF
    
    sudo chmod +x /usr/local/bin/nominatim-update
    
    # Script de backup
    sudo tee /usr/local/bin/nominatim-backup > /dev/null <<EOF
#!/bin/bash
BACKUP_DIR="/backup/nominatim"
mkdir -p \$BACKUP_DIR
sudo -u postgres pg_dump nominatim > "\$BACKUP_DIR/nominatim_backup_\$(date +%Y%m%d_%H%M%S).sql"
find \$BACKUP_DIR -name "*.sql" -mtime +7 -delete 2>/dev/null || true
EOF
    
    sudo chmod +x /usr/local/bin/nominatim-backup
    
    # Configurar cron jobs
    # Se usa NOMINATIM_USER para el crontab para evitar problemas de permisos
    sudo -u $NOMINATIM_USER bash <<EOF
(crontab -l 2>/dev/null; echo "0 2 * * * /usr/local/bin/nominatim-update") | crontab -
(crontab -l 2>/dev/null; echo "0 3 * * 0 /usr/local/bin/nominatim-backup") | crontab -
EOF
    
    log "Scripts de mantenimiento creados"
}

# Función para verificar instalación
verify_installation() {
    log "Verificando instalación..."
    
    # Verificar servicios
    if ! systemctl is-active --quiet apache2; then
        error "Apache no está funcionando"
    fi
    
    if ! systemctl is-active --quiet postgresql; then
        error "PostgreSQL no está funcionando"
    fi
    
    # Esperar un momento para que los servicios estén listos
    sleep 5
    
    # Verificar API
    local test_url="http://localhost/search?q=test&format=json"
    local response=$(curl -s -o /dev/null -w "%{http_code}" "$test_url" 2>/dev/null || echo "000")
    
    if [ "$response" = "200" ]; then
        log "✅ API funcionando correctamente"
    else
        warning "⚠️ API no responde correctamente (código: $response)"
        warning "Esto puede ser normal si la importación aún no ha terminado"
    fi
    
    log "Verificación completada"
}

# Función para mostrar información final
show_final_info() {
    local server_ip=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    
    echo -e "${GREEN}================================${NC}"
    echo -e "${GREEN}  INSTALACIÓN COMPLETADA  ${NC}"
    echo -e "${GREEN}================================${NC}"
    echo ""
    echo -e "${BLUE}Tu API de Nominatim está disponible en:${NC}"
    echo -e "  • URL: http://$server_ip/search"
    echo -e "  • Ejemplo: http://$server_ip/search?q=New York&format=json"
    echo -e "  • Reversa: http://$server_ip/reverse?lat=40.7589&lon=-73.9851&format=json"
    echo ""
    echo -e "${BLUE}Comandos útiles:${NC}"
    echo -e "  • Actualizar datos: sudo /usr/local/bin/nominatim-update"
    echo -e "  • Crear backup: sudo /usr/local/bin/nominatim-backup"
    echo -e "  • Ver logs: sudo tail -f /var/log/apache2/nominatim_error.log"
    echo -e "  • Estado servicios: sudo systemctl status apache2 postgresql"
    echo ""
    echo -e "${BLUE}Archivos importantes:${NC}"
    echo -e "  • Proyecto: $PROJECT_DIR"
    echo -e "  • Configuración Apache: /etc/apache2/sites-available/$APACHE_SITE.conf"
    echo -e "  • Logs: /var/log/apache2/"
    echo ""
    echo -e "${YELLOW}Nota: Si la importación aún está en progreso, la API estará disponible una vez completada.${NC}"
}

# Función de limpieza en caso de error
cleanup_on_error() {
    log "Limpiando instalación fallida..."
    sudo systemctl stop apache2 2>/dev/null || true
    sudo systemctl stop postgresql 2>/dev/null || true
    # Solo eliminar usuario y directorio si fue creado por el script
    if id "$NOMINATIM_USER" &>/dev/null; then
        sudo userdel -r $NOMINATIM_USER 2>/dev/null || true
    fi
    if [ -d "$NOMINATIM_HOME" ]; then
        sudo rm -rf $NOMINATIM_HOME 2>/dev/null || true
    fi
    log "Limpieza completada."
}

# Función principal
main() {
    log "Iniciando instalación automatizada de Nominatim..."
    
    # Configurar trap para limpieza automática en caso de error
    trap cleanup_on_error ERR
    
    check_root
    check_system_resources
    select_region
    
    log "Configuración seleccionada:"
    info "Región: $PBF_REGION"
    info "URL PBF: $PBF_URL"
    info "Threads: $THREADS"
    
    read -p "¿Continuar con la instalación? (y/N): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        error "Instalación cancelada por el usuario"
    fi
    
    update_system
    install_dependencies
    configure_postgresql
    create_nominatim_user
    install_nominatim
    download_osm_data
    import_data
    configure_apache
    configure_firewall
    create_maintenance_scripts
    verify_installation
    show_final_info
    
    log "¡Instalación completada exitosamente!"
}

# Ejecutar función principal
main "$@"
