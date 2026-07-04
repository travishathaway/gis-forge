#!/usr/bin/env bash
set -euo pipefail

cd "${SRC_DIR}"

# Large multi-module Maven build needs extra heap
export MAVEN_OPTS="-Xmx2g"
mvn clean package -PbuildFatJar -DskipTests -DskipITs

# Install JAR
mkdir -p "${PREFIX}/share/openrouteservice"
cp ors-api/target/ors.jar "${PREFIX}/share/openrouteservice/ors.jar"

# Write wrapper scripts so `ors` works from the command line.
# Both use paths relative to the script location so the package works
# on any platform without prefix substitution.
mkdir -p "${PREFIX}/bin"

# Unix wrapper (Linux / macOS)
cat > "${PREFIX}/bin/ors" << 'EOF'
#!/bin/sh
exec java "$@" -jar "$(dirname "$0")/../share/openrouteservice/ors.jar"
EOF
chmod +x "${PREFIX}/bin/ors"

# Windows wrapper — written during the Linux build, installed on Windows.
# %~dp0 expands to the batch file's own directory (with trailing \).
cat > "${PREFIX}/bin/ors.bat" << 'EOF'
@echo off
java %* -jar "%~dp0..\share\openrouteservice\ors.jar"
EOF
