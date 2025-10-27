#!/usr/bin/env bash
set -euo pipefail

# -----------------------
# Parámetros de build
# -----------------------
PHP_VERSION="${1:-PHP-8.4.14}"
CORES="${2:-16}"
WASM_ENVIRONMENT="${3:-web}"
# Variables de la imagen Docker que usaremos para el linkado final
OPTIMIZE="-O3"
EXPORT_NAME="createPhpModule"
JAVASCRIPT_EXTENSION="mjs"
INITIAL_MEMORY="128mb"

echo "PHP-WASM Build"
echo "PHP Version: $PHP_VERSION"
echo "Núcleos: $CORES"
echo "Entorno: $WASM_ENVIRONMENT"

# -----------------------
# Directorios locales
# -----------------------
BASE_DIR="$(pwd)"
BUILD_DIR="$BASE_DIR/apptainer_tool/build"
DEMO_DIR="$BASE_DIR/demo"
SOURCE_DIR="$BASE_DIR/source"

# Limpiar solo build/
echo "Limpiando build previo..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
mkdir -p "$DEMO_DIR"

# -----------------------
# Ejecutar build dentro del SIF
# -----------------------
echo "Ejecutando build dentro del SIF..."
# NOTA: Ahora usamos /mnt/source para el código del usuario y /build para
# almacenar todo el proceso de compilación, como en el Dockerfile.
apptainer exec \
  --bind "$BUILD_DIR:/build" \
  --bind "$SOURCE_DIR:/mnt/source" \
  ./apptainer_tool/phpwasm-builder.sif bash -c "
set -euo pipefail
export LC_ALL=C
export LANG=C

# Directorio de trabajo principal dentro del contenedor
# CORRECCIÓN: Cambiar a /build, que es el directorio montado con permisos de escritura.
ROOT_SRC=/build
cd \$ROOT_SRC

# -----------------------
# 1. libxml2
# -----------------------
echo 'Compilando libxml2...'
LIBXML2_TAG=v2.9.10
rm -rf libxml2
git clone https://gitlab.gnome.org/GNOME/libxml2.git libxml2 --branch \$LIBXML2_TAG --single-branch --depth 1
cd libxml2
./autogen.sh
# NOTA: Creamos el destino de instalación en \$ROOT_SRC/usr, replicando el COPY del Dockerfile.
emconfigure ./configure --prefix=\$ROOT_SRC/usr --enable-static --disable-shared --with-python=no --with-threads=no
emmake make -j$CORES
emmake make install
cd \$ROOT_SRC

# -----------------------
# 2. SQLite
# -----------------------
echo 'Compilando SQLite...'
wget https://sqlite.org/2020/sqlite-amalgamation-3330000.zip
unzip sqlite-amalgamation-3330000.zip
rm sqlite-amalgamation-3330000.zip
mv sqlite-amalgamation-3330000 sqlite
cd sqlite
# Ajuste: Creamos el directorio de includes para que PHP lo encuentre
mkdir -p \$ROOT_SRC/usr/include/sqlite3
cp sqlite3.h \$ROOT_SRC/usr/include/sqlite3/
emcc $OPTIMIZE \
  -DSQLITE_OMIT_LOAD_EXTENSION \
  -DSQLITE_DISABLE_LFS \
  -DSQLITE_ENABLE_FTS3 \
  -DSQLITE_ENABLE_FTS3_PARENTHESIS \
  -DSQLITE_THREADSAFE=0 \
  -DSQLITE_ENABLE_NORMALIZE \
  -DSQLITE_DISABLE_MMAP \
  -c sqlite3.c -o sqlite3.o
# Ajuste: Movemos el objeto compilado a /src/usr/lib para el linkado
mv sqlite3.o \$ROOT_SRC/usr/lib/
cd \$ROOT_SRC

# -----------------------
# 3. PHP Source
# -----------------------
echo 'Clonando PHP $PHP_VERSION...'
rm -rf php-src
git clone https://github.com/php/php-src.git php-src --branch $PHP_VERSION --single-branch --depth 1
cd php-src
./buildconf --force

# -----------------------
# 4. Configuración PHP (Usando ENV para dependencias)
# -----------------------
echo 'Configuracion PHP...'
# CRÍTICO: Establecer ENV vars para que configure encuentre las dependencias
# Ahora apuntan a /build/usr/
export CFLAGS="-DHAVE_REALLOCARRAY=1"
export LIBXML_LIBS="-L\$ROOT_SRC/usr/lib"
export LIBXML_CFLAGS="-I\$ROOT_SRC/usr/include/libxml2"
export SQLITE_CFLAGS="-I\$ROOT_SRC/usr/include/sqlite3"
export SQLITE_LIBS="-L\$ROOT_SRC/usr/lib"

emconfigure ./configure \
  --enable-embed=static \
  --with-layout=GNU \
  --disable-cgi \
  --disable-cli \
  --disable-fiber-asm \
  --disable-rpath \
  --disable-phpdbg \
  --without-pear \
  --with-valgrind=no \
  --without-pcre-jit \
  --disable-phar \
  --disable-opcache-jit \
  --disable-mmap \
  --disable-opcache \
  --with-config-file-scan-dir=/src/php \
  --disable-all \
  --with-libxml \
  --enable-xml \
  --with-sqlite3 \
  --enable-session \
  --enable-filter \
  --enable-calendar \
  --enable-dom \
  --enable-bcmath \
  --enable-json \
  --enable-ctype \
  --enable-mbstring \
  --disable-mbregex \
  --enable-tokenizer \
  --enable-simplexml \
  --enable-pdo \
  --with-pdo-sqlite

# -----------------------
# 5. Compilación PHP
# -----------------------
echo 'Compilando PHP...'
emmake make -j$CORES

# CRÍTICO: Ajuste de nombre de librería (como en el Dockerfile)
# Necesario para cuando PHP compila con libphpX.a
bash -c '[[ -f .libs/libphp7.la ]] && mv .libs/libphp7.la .libs/libphp.la && mv .libs/libphp7.a .libs/libphp.a || true'
bash -c '[[ -f .libs/libphp8.la ]] && mv .libs/libphp8.la .libs/libphp.a && mv .libs/libphp8.a .libs/libphp.a || true'

cd \$ROOT_SRC
# -----------------------
# 6. Compilar phpw.c a WASM
# -----------------------
echo 'Compilando phpw.c a WASM...'
# Copiamos el source del host (/mnt/source)
cp /mnt/source/phpw.c \$ROOT_SRC/phpw.c

# Compilación a objeto
cd php-src
emcc $OPTIMIZE \
  -I . \
  -I Zend \
  -I main \
  -I TSRM \
  -I sapi/embed \
  -c \$ROOT_SRC/phpw.c -o \$ROOT_SRC/phpw.o \
  -s ERROR_ON_UNDEFINED_SYMBOLS=0 \
  -s WASM_BIGINT=1

# Link final a WASM
echo 'Enlazando WASM...'
mkdir -p /build # El directorio de salida final (ya es \$ROOT_SRC, pero lo mantenemos por seguridad)
emcc $OPTIMIZE \
  -o /build/php-$WASM_ENVIRONMENT.$JAVASCRIPT_EXTENSION \
  --llvm-lto 2 \
  -s EXPORTED_FUNCTIONS='[\"_phpw\", \"_phpw_flush\", \"_phpw_exec\", \"_phpw_run\", \"_chdir\", \"_setenv\", \"_php_embed_init\", \"_php_embed_shutdown\", \"_zend_eval_string\"]' \
  -s EXTRA_EXPORTED_RUNTIME_METHODS='[\"ccall\", \"UTF8ToString\", \"lengthBytesUTF8\", \"FS\"]' \
  -s ENVIRONMENT=$WASM_ENVIRONMENT \
  -s FORCE_FILESYSTEM=1 \
  -s MAXIMUM_MEMORY=2gb \
  -s INITIAL_MEMORY=$INITIAL_MEMORY \
  -s ALLOW_MEMORY_GROWTH=1 \
  -s ASSERTIONS=0 \
  -s ERROR_ON_UNDEFINED_SYMBOLS=0 \
  -s MODULARIZE=1 \
  -s INVOKE_RUN=0 \
  -s LZ4=1 \
  -s EXPORT_ES6=1 \
  -s EXPORT_NAME=$EXPORT_NAME \
  -lidbfs.js \
  \$ROOT_SRC/phpw.o .libs/libphp.a \$ROOT_SRC/usr/lib/sqlite3.o \$ROOT_SRC/usr/lib/libxml2.a

echo 'Build completado'
"

# -----------------------
# Copiar resultados a demo
# -----------------------
echo "Actualizando archivos en $DEMO_DIR..."
cp -v "$BUILD_DIR/php-$WASM_ENVIRONMENT.$JAVASCRIPT_EXTENSION" "$DEMO_DIR/php-web.mjs"
cp -v "$BUILD_DIR/php-$WASM_ENVIRONMENT.wasm" "$DEMO_DIR/php-web.wasm" || true

echo "Archivos sobrescritos en $DEMO_DIR"

