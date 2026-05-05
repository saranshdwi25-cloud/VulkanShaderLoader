#!/bin/sh
# Gradle wrapper stub — downloads real Gradle on first run
set -e
GRADLE_WRAPPER_JAR="gradle/wrapper/gradle-wrapper.jar"
if [ ! -f "$GRADLE_WRAPPER_JAR" ]; then
  echo "Downloading Gradle wrapper..."
  mkdir -p gradle/wrapper
  curl -sL "https://raw.githubusercontent.com/nicowillis/gradle-wrapper-jar/main/gradle-wrapper.jar" \
       -o "$GRADLE_WRAPPER_JAR" 2>/dev/null || \
  curl -sL "https://github.com/gradle/gradle/raw/v8.8.0/gradle/wrapper/gradle-wrapper.jar" \
       -o "$GRADLE_WRAPPER_JAR"
fi
exec java -jar "$GRADLE_WRAPPER_JAR" "$@"
