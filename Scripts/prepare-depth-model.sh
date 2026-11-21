#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
revision=cfef6f6f2a70783dedc0bfae40cecbc2052285d3
name=DepthAnythingV2SmallF16P6
cache="$PWD/.build/DepthModel/$revision"
package="$cache/$name.mlpackage"
compiled="$cache/$name.mlmodelc"
base="https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/$revision/$name.mlpackage"

fetch() {
    local relative="$1" expected="$2" file
    file="$package/$relative"
    mkdir -p "$(dirname "$file")"
    if [[ -f "$file" ]] && [[ "$(shasum -a 256 "$file" | cut -d ' ' -f 1)" == "$expected" ]]; then
        return
    fi
    /usr/bin/curl --fail --location --silent --show-error --retry 2 --connect-timeout 15 --max-time 150 \
        "$base/$relative?download=true" --output "$file.partial"
    if [[ "$(shasum -a 256 "$file.partial" | cut -d ' ' -f 1)" != "$expected" ]]; then
        printf '景深模型校验失败：%s\n' "$relative" >&2
        return 1
    fi
    mv -f "$file.partial" "$file"
}

if [[ ! -r "$compiled/coremldata.bin" || ! -r "$compiled/weights/weight.bin" ]]; then
    fetch 'Manifest.json' '70e469c0359c89851bde4cdc1d89bf13fa06d4fccd8907b9b5f744e548ecaadf'
    fetch 'Data/com.apple.CoreML/model.mlmodel' 'ee53b8f7e1682a66857b5a3d54cf04a97d89a98cf7b5979b5d726aaf9c24ad70'
    fetch 'Data/com.apple.CoreML/weights/weight.bin' '3e9bcccc9e35ae6f9759551f481a3b77226510bd74536e059ee9780dda618381'
    xcrun coremlcompiler compile "$package" "$cache" >&2
fi
printf '%s\n' "$compiled"
