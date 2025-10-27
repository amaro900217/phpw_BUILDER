FROM emscripten/emsdk:3.1.35 AS build_tool

RUN apt-get update && \
  apt-get --no-install-recommends -y install \
  build-essential \
  automake \
  autoconf \
  libtool \
  pkgconf \
  python3 \
  bison \
  flex \
  make \
  re2c \
  gdb \
  git \
  libxml2 \
  libxml2-dev \
  pv \
  re2c

FROM build_tool AS libxml
ARG LIBXML2_TAG=v2.9.10
RUN git clone https://gitlab.gnome.org/GNOME/libxml2.git libxml2 \
  --branch $LIBXML2_TAG \
  --single-branch \
  --depth 1
WORKDIR /src/libxml2
RUN ./autogen.sh
RUN cd /src/php-src && make distclean || true
RUN emconfigure ./configure --prefix=/src/libxml2/build --enable-static --disable-shared --with-python=no --with-threads=no
RUN emmake make -j8
RUN emmake make install

FROM build_tool AS sqlite
RUN wget https://sqlite.org/2020/sqlite-amalgamation-3330000.zip \
  && unzip sqlite-amalgamation-3330000.zip \
  && rm sqlite-amalgamation-3330000.zip \
  && mv sqlite-amalgamation-3330000 sqlite
WORKDIR /src/sqlite
RUN emcc -Oz \
  -DSQLITE_OMIT_LOAD_EXTENSION \
  -DSQLITE_DISABLE_LFS \
  -DSQLITE_ENABLE_FTS3 \
  -DSQLITE_ENABLE_FTS3_PARENTHESIS \
  -DSQLITE_THREADSAFE=0 \
  -DSQLITE_ENABLE_NORMALIZE \
  -DSQLITE_DISABLE_MMAP \
  -c sqlite3.c -o sqlite3.o

FROM build_tool AS php_src
ARG PHP_BRANCH=PHP-8.4.14
RUN git clone https://github.com/php/php-src.git php-src \
  --branch $PHP_BRANCH \
  --single-branch \
  --depth 1

FROM php_src AS php-wasm
ARG WASM_ENVIRONMENT=web
ARG JAVASCRIPT_EXTENSION=mjs
ARG EXPORT_NAME=createPhpModule
ARG MODULARIZE=1
ARG EXPORT_ES6=1
ARG ASSERTIONS=0
ARG OPTIMIZE=-O3
ARG INITIAL_MEMORY=128mb

COPY --from=libxml /src/libxml2/build/ /src/usr
COPY --from=sqlite /src/sqlite/sqlite3.o /src/usr/lib/
COPY --from=sqlite /src/sqlite/sqlite3.h /src/usr/include/sqlite3/

ENV CFLAGS="-DHAVE_REALLOCARRAY=1"
ENV LIBXML_LIBS="-L/src/usr/lib"
ENV LIBXML_CFLAGS="-I/src/usr/include/libxml2"
ENV SQLITE_CFLAGS="-I/src/usr/include/sqlite3"
ENV SQLITE_LIBS="-L/src/usr/lib"

RUN cd /src/php-src && ./buildconf --force \
  && emconfigure ./configure \
  --enable-embed=static \
  --with-layout=GNU \
  --with-libxml \
  --enable-xml \
  --disable-cgi \
  --disable-cli \
  --disable-fiber-asm \
  --disable-all \
  --enable-session \
  --enable-filter \
  --enable-calendar \
  --enable-dom \
  --disable-rpath \
  --disable-phpdbg \
  --without-pear \
  --with-valgrind=no \
  --without-pcre-jit \
  --disable-phar \
  --disable-opcache-jit \
  --disable-mmap \
  --enable-bcmath \
  --enable-json \
  --enable-ctype \
  --enable-mbstring \
  --disable-mbregex \
  --with-config-file-scan-dir=/src/php \
  --enable-tokenizer \
  --enable-simplexml \
  --enable-pdo \
  --with-pdo-sqlite \
  --disable-all \
  --disable-opcache \
  --with-sqlite3

RUN cd /src/php-src && emmake make -j8
RUN cd /src/php-src && bash -c '[[ -f .libs/libphp7.la ]] && mv .libs/libphp7.la .libs/libphp.la && mv .libs/libphp7.a .libs/libphp.a && mv .libs/libphp7.lai .libs/libphp.lai || exit 0'
COPY ./source /src/source
RUN cd /src/php-src && emcc $OPTIMIZE \
  -I . \
  -I Zend \
  -I main \
  -I TSRM/ \
  -c /src/source/phpw.c \
  -o /src/phpw.o \
  -s ERROR_ON_UNDEFINED_SYMBOLS=0 \
  -s WASM_BIGINT=1
RUN mkdir /build && cd /src/php-src && emcc $OPTIMIZE \
  -o /build/php-$WASM_ENVIRONMENT.$JAVASCRIPT_EXTENSION \
  --llvm-lto 2 \
  -s EXPORTED_FUNCTIONS='["_phpw", "_phpw_flush", "_phpw_exec", "_phpw_run", "_chdir", "_setenv", "_php_embed_init", "_php_embed_shutdown", "_zend_eval_string"]' \
  -s EXTRA_EXPORTED_RUNTIME_METHODS='["ccall", "UTF8ToString", "lengthBytesUTF8", "FS"]' \
  -s ENVIRONMENT=$WASM_ENVIRONMENT \
  -s FORCE_FILESYSTEM=1 \
  -s MAXIMUM_MEMORY=2gb \
  -s INITIAL_MEMORY=$INITIAL_MEMORY \
  -s ALLOW_MEMORY_GROWTH=1 \
  -s ASSERTIONS=$ASSERTIONS \
  -s ERROR_ON_UNDEFINED_SYMBOLS=0 \
  -s MODULARIZE=$MODULARIZE \
  -s INVOKE_RUN=0 \
  -s LZ4=1 \
  -s EXPORT_ES6=$EXPORT_ES6 \
  -s EXPORT_NAME=$EXPORT_NAME \
  -lidbfs.js \
  /src/phpw.o /src/usr/lib/sqlite3.o .libs/libphp.a /src/usr/lib/libxml2.a
RUN rm -r /src/*

FROM scratch
COPY --from=php-wasm /build/ .

