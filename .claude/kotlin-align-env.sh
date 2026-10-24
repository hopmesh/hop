#!/usr/bin/env bash
# Env wrapper for the kotlin-align work. Source or call with a command.
export PATH="$HOME/.cargo/bin:/opt/homebrew/opt/openjdk@17/bin:/opt/homebrew/bin:$PATH"
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
export ANDROID_SDK_ROOT="$ANDROID_HOME"
exec "$@"
