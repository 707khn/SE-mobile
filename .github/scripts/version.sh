#!/bin/bash
# Номер версии ставит сборка, а не автор PR.
#
# Раньше номер правили руками в двух местах (pubspec.yaml и app_version.dart)
# в каждом PR приложения — и почти каждый висящий PR конфликтовал с main по
# строке version, а сверять два места приходилось отдельной проверкой.
#
# Теперь: старшие цифры (1.32) — из pubspec.yaml, их меняют редко и руками;
# номер сборки — число коммитов в main по первой линии (git rev-list
# --count --first-parent). Он растёт с каждым слиянием, одинаков у APK,
# веб-версии и Windows из одного коммита и не повторяется. Третья цифра
# версии равна номеру сборки: 1.32.263+263.
#
# Нужна полная история: actions/checkout с fetch-depth: 0.
#
# Пишет в $GITHUB_ENV (или печатает): APP_NAME, APP_BUILD, PUB, FLUTTER_VERSION_ARGS.
set -euo pipefail

base=$(sed -n 's/^version: *//p' pubspec.yaml | tr -d '\r' | cut -d+ -f1)
majmin=$(echo "$base" | cut -d. -f1,2)
if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
    echo "::error::Нужна полная история: actions/checkout с fetch-depth: 0" >&2
    exit 1
fi
build=$(git rev-list --count --first-parent HEAD)
name="$majmin.$build"
args="--build-name=$name --build-number=$build --dart-define=APP_VERSION=$name --dart-define=APP_BUILD=$build"

out=${GITHUB_ENV:-/dev/stdout}
{
    echo "APP_NAME=$name"
    echo "APP_BUILD=$build"
    echo "PUB=$name+$build"
    echo "FLUTTER_VERSION_ARGS=$args"
} >> "$out"
echo "Версия $name+$build" >&2
