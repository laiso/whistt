#!/bin/sh
set -eu

previous_tag=${1:?usage: generate-release-body.sh PREVIOUS_TAG ARTIFACT REPOSITORY SUMMARY OUTPUT}
artifact=${2:?usage: generate-release-body.sh PREVIOUS_TAG ARTIFACT REPOSITORY SUMMARY OUTPUT}
repository=${3:?usage: generate-release-body.sh PREVIOUS_TAG ARTIFACT REPOSITORY SUMMARY OUTPUT}
summary_file=${4:?usage: generate-release-body.sh PREVIOUS_TAG ARTIFACT REPOSITORY SUMMARY OUTPUT}
output_file=${5:?usage: generate-release-body.sh PREVIOUS_TAG ARTIFACT REPOSITORY SUMMARY OUTPUT}

{
  if [ -s "$summary_file" ]; then
    printf '%s\n\n' '## Release summary'
    sed '/^[[:space:]]*$/N;/^\n$/D' "$summary_file"
    printf '\n\n'
  else
    printf '%s\n\n' '## Changes'
    if [ "$previous_tag" = v0.0.0 ]; then
      git log --first-parent --pretty='- %s (`%h`)' HEAD
    else
      git log --first-parent --pretty='- %s (`%h`)' "$previous_tag"..HEAD
    fi
    printf '\n\n'
  fi

  printf '%s\n\n' '## Install'
  printf '%s\n\n' '> ⚠️ Whistt is distributed **unsigned**. Double-clicking the .app will show *"Apple could not verify Whistt is free of malware"*. Use one of the bypass steps below.'
  printf '1. Download `%s` and unzip.\n' "$artifact"
  printf '%s\n' '2. Move `Whistt.app` to `/Applications/`.'
  printf '%s\n' '3. Bypass Gatekeeper — pick one:'
  printf '%s\n' '   - **Terminal**: `xattr -dr com.apple.quarantine /Applications/Whistt.app`'
  printf '%s\n' '   - **GUI**: System Settings → Privacy & Security → scroll to the "Whistt was blocked" row → **Open Anyway**'
  printf '%s\n' '4. Launch Whistt, paste your OpenAI API key (issue one at https://platform.openai.com/api-keys), and grant **Microphone** + **Accessibility** permissions in System Settings.'
  printf '%s\n\n' '5. Hold ⌥+Space, speak, release — text appears at your cursor.'
  printf 'See the [README](https://github.com/%s/blob/main/README.md) for full usage.\n' "$repository"
} > "$output_file"
