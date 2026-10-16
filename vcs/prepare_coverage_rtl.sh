#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
filter="$project_root/vcs/exclude_nonsynth_coverage.awk"
source_dir=${1:-}
output_dir=${2:-}

if [[ -z "$source_dir" || -z "$output_dir" ]]; then
  echo "usage: $0 SOURCE_RTL_DIR OUTPUT_RTL_DIR" >&2
  exit 2
fi
if [[ ! -f "$source_dir/TestTop.sv" || ! -f "$source_dir/filelist.f" ]]; then
  echo "error: generated RTL is missing from $source_dir" >&2
  exit 2
fi
if [[ ! -f "$filter" ]]; then
  echo "error: non-synthesis coverage filter is missing: $filter" >&2
  exit 2
fi

source_dir=$(cd "$source_dir" && pwd)
mkdir -p "$(dirname "$output_dir")"
output_parent=$(cd "$(dirname "$output_dir")" && pwd)
output_dir="$output_parent/$(basename "$output_dir")"
if [[ "$source_dir" == "$output_dir" ]]; then
  echo "error: coverage RTL output must differ from the generated RTL source" >&2
  exit 2
fi

count_nonsynth_blocks() {
  find "$1" -maxdepth 1 -type f \( -name '*.sv' -o -name '*.v' \) -print0 |
    xargs -0 awk '/^[[:space:]]*`ifndef[[:space:]]+SYNTHESIS([[:space:]]|$)/ { ++count }
                   END { print count + 0 }'
}

count_pragma() {
  local pragma=$1
  local directory=$2
  find "$directory" -maxdepth 1 -type f \( -name '*.sv' -o -name '*.v' \) -print0 |
    xargs -0 awk -v pragma="$pragma" \
      '$0 ~ "^[[:space:]]*//VCS coverage " pragma "[[:space:]]*$" { ++count }
       END { print count + 0 }'
}

source_nonsynth_blocks=$(count_nonsynth_blocks "$source_dir")
if [[ "$source_nonsynth_blocks" -eq 0 ]]; then
  echo "error: no firtool-emitted non-synthesis blocks found in $source_dir" >&2
  exit 2
fi

cmake -E remove_directory "$output_dir"
cmake -E copy_directory "$source_dir" "$output_dir"

while IFS= read -r -d '' rtl_file; do
  filtered_file=$(mktemp "$rtl_file.filtered.XXXXXX")
  if ! awk -f "$filter" "$rtl_file" >"$filtered_file"; then
    cmake -E remove -f "$filtered_file"
    exit 1
  fi
  mv "$filtered_file" "$rtl_file"
done < <(find "$output_dir" -maxdepth 1 -type f \
  \( -name '*.sv' -o -name '*.v' \) -print0 | sort -z)

coverage_off_blocks=$(count_pragma off "$output_dir")
coverage_on_blocks=$(count_pragma on "$output_dir")
if [[ "$coverage_off_blocks" -eq 0 || "$coverage_off_blocks" -ne "$coverage_on_blocks" ]]; then
  echo "error: non-synthesis coverage pragmas are missing or unbalanced" >&2
  exit 1
fi

echo "Prepared coverage RTL: excluded $coverage_off_blocks non-synthesis blocks from code coverage."
