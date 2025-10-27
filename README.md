# PHP WebAssembly Builder

**Project based on:**
- https://github.com/soyuka/php-wasm (original work by soyuka)
- https://github.com/seanmorris/php-wasm (forked from)
- https://github.com/oraoto/pib (original inspiration)

Compiles PHP to WebAssembly for running PHP code in browsers with SQLite and XML support.

## Quick Start

### Build Using Scripts

**Option 1: Docker (Recommended)**
```bash
./build_docker.sh
```

**Option 2: Apptainer/Singularity**
```bash
./build_apptainer.sh [PHP_VERSION] [CORES] [ENVIRONMENT]
# Example:
./build_apptainer.sh PHP-8.4.14 8 web
```

### Run Demo

```bash
# copy built files (.wasm and .mjs) to demo folder
cd demo
php -S 127.0.0.1:8000
```

Open http://127.0.0.1:8000 in your browser.

## Build Methods

### Docker Build
- **Script**: `./build_docker.sh` - Automated Docker build with cache cleanup
- **Manual**: `docker buildx bake` - Uses docker-bake.hcl configuration
- **Output**: `build/php-web.mjs`, `build/php-web.wasm`

### Apptainer/Singularity Build (the tool must be installed first)
- **Script**: `./build_apptainer.sh` - HPC/container environment builds
- **Features**: Native build without Docker, supports custom PHP versions and core counts
- **Output**: Same as Docker build, copied to demo directory

### Build Configuration

Edit `Dockerfile` to customize:

Setting          | Default       | Description
-----------------|---------------|----------------------
PHP_BRANCH       | PHP-8.4.14    | PHP version
LIBXML2_TAG      | v2.9.10       | XML library version
INITIAL_MEMORY   | 128mb         | WASM memory
OPTIMIZE         | -O3           | Optimization level

## Usage

### Basic Example

```javascript
import createPhpModule from './php-web.mjs';

const php = await createPhpModule({
  print: console.log,
  printErr: console.error
});

const { ccall, FS } = php;

// Execute PHP code
const result = ccall('phpw_exec', 'string', ['string'], ['phpversion();']);
console.log(result);

// Use SQLite
ccall('phpw_run', null, ['string'], [`
  $db = new SQLite3('data.db');
  $db->exec("CREATE TABLE test (id INTEGER PRIMARY KEY)");
  echo "Database created";
`]);
```

### API Functions

- `phpw_exec(code)` → Execute PHP and return output string
- `phpw_run(code)` → Execute PHP without return value
- `phpw(file)` → Execute PHP file from filesystem

### Filesystem

```javascript
// Persistent storage with IndexedDB
FS.mkdir('/data');
FS.mount(FS.filesystems.IDBFS, {}, '/data');
await new Promise(r => FS.syncfs(true, r)); // Load from browser storage
// ... use files ...
await new Promise(r => FS.syncfs(false, r)); // Save to browser storage
```

## Demo Features

The demo includes:
- **Performance tests** - Loading and execution timing
- **SQLite operations** - Database creation and queries
- **Persistent storage** - IndexedDB integration
- **Error handling** - Proper exception management

## Troubleshooting

**Build fails?**
- Run `./build_docker.sh` (includes cache cleanup)
- Check Docker memory limits
- Ensure stable internet for git clones

**Runtime issues?**
- Verify web server serves `.wasm` files correctly
- Check browser console for errors
- Ensure working directory is set in PHP code

## Project Structure

```
├── build_docker.sh      # Docker build script
├── build_apptainer.sh   # Apptainer/Singularity script
├── source/phpw.c        # PHP-WASM bridge
├── demo/                # Working demo (pre-built)
├── Dockerfile           # Multi-stage build
└── docker-bake.hcl      # Build configuration
```

## License

Based on original works by soyuka, seanmorris, and oraoto. See [LICENSE](LICENSE) for details.
