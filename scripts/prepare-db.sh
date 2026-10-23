# Shared SQLCipher/C module setup. Source from repository root.
SQLCIPHER_PREFIX="$(/opt/homebrew/bin/brew --prefix sqlcipher)"
TASK_SOURCE_DIR="$(pwd)/Sources/Database"
mkdir -p build/module-cache build/unread-cmodule
xcrun clang -O3 -c "$TASK_SOURCE_DIR/IdentityScan.c" -o build/IdentityScan.o
cat > build/unread-cmodule/module.modulemap <<MODULE
module CSQLCipher [system] {
  header "$SQLCIPHER_PREFIX/include/sqlcipher/sqlite3.h"
  link "sqlcipher"
  export *
}
module IdentityScan {
  header "$TASK_SOURCE_DIR/IdentityScan.h"
  export *
}
MODULE
