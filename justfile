set shell := ["/bin/zsh", "-euo", "pipefail", "-c"]
export PATH := "/opt/homebrew/bin:" + env("PATH")

default:
    @just --list

generate:
    xcodegen generate --spec project.yml

test:
    swift test --package-path Packages/MountainCore

lint:
    swift format lint --strict --recursive App Packages/MountainCore/Sources Packages/MountainCore/Tests Packages/MountainCore/Package.swift

format:
    swift format format --in-place --recursive App Packages/MountainCore/Sources Packages/MountainCore/Tests Packages/MountainCore/Package.swift

build: generate
    xcodebuild -project S3Mountain.xcodeproj -scheme S3Mountain -configuration Debug -derivedDataPath build/unsigned CODE_SIGNING_ALLOWED=NO build

build-signed: generate
    xcodebuild -project S3Mountain.xcodeproj -scheme S3Mountain -configuration Debug -derivedDataPath build/signed DEVELOPMENT_TEAM=UGNVGWZMAU build

run: build-signed
    open "build/signed/Build/Products/Debug/S3 Mountain.app"

# Writes disposable synthetic objects only; credentials are read from a private file.
test-r2:
    test "${S3_MOUNTAIN_R2_TEST:-0}" = 1
    python3 scripts/r2_contract_probe.py --account-id "$S3_MOUNTAIN_R2_ACCOUNT_ID" --bucket "$S3_MOUNTAIN_R2_BUCKET" --credentials-file "$S3_MOUNTAIN_R2_CREDENTIALS_FILE" --jurisdiction "${S3_MOUNTAIN_R2_JURISDICTION:-standard}" --allow-test-writes
