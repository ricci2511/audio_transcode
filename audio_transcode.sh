#!/bin/bash

#####################################################################
# Audio Transcoding Script
#
# This script transcodes audio streams in video files to AC3 format using optimal
# bitrates based on the number of channels:
#   - Mono (1.0):     AC3 @ 128k
#   - Stereo (2.0):   AC3 @ 224k
#   - 3.0 channels:   AC3 @ 320k
#   - 4.0 channels:   AC3 @ 448k
#   - 5.1 channels:   AC3 @ 640k
#
# Existing AC3 and E-AC3 streams are preserved (copied).
# It utilizes FFmpeg for audio transcoding and processing.
#
# Usage:
# ./audio_transcode.sh [OPTIONS] [FILE(s)]
#
# Options:
#   -o   Overwrite original files with transcoded audio.
#   -r   Traverse subdirectories and process their contents.
#
# Examples:
#   ./audio_transcode.sh -o movie.mkv
#   ./audio_transcode.sh -r /path/to/movies
#
# Notes:
# - If no arguments are passed, only mkv or mp4 files in the current directory are processed.
# - By default, the script preserves video and subtitle streams.
# - ASS/SSA subtitles are automatically converted to text/SRT format.
# - Only audio streams with languages specified in the `desired_languages` array are included in the output.
# - Supports SABnzbd post-processing scripts for completed downloads.
# - Supports Sonarr/Radarr custom scripts for Import/Upgrade events.
# - You can customize the audio transcoding settings within the script.
#
# Dependencies:
# - ffmpeg and ffprobe must be accessible in your PATH.
#####################################################################

desired_audio_formats=("eac3" "ac3")        # Audio formats to just copy (no transcoding)
desired_languages=("eng" "ger" "spa" "jpn") # Any other lang is skipped
main_language="ger"                         # Main language for audio track selection (default)

overwrite=false        # -o
traverse_subdirs=false # -r

# Parse command line arguments
while (($# > 0)); do
  case "$1" in
  -o) overwrite=true ;;
  -r) traverse_subdirs=true ;;
  -*) echo "Unknown option: $1" && exit 1 ;;
  *) break ;;
  esac
  shift
done

if [ $overwrite = true ]; then
  echo "WARNING: passed -o argument, original files will be overwritten"
fi

# Function to determine the transcode options based on channels and index
get_transcode_options() {
  local codec_name="$1"
  local channels="$2"
  local index="$3"
  local options=""

  if [[ ! " ${desired_audio_formats[*]} " == *"$codec_name"* ]]; then
    case "$channels" in
    1) options="-c:a:$index ac3 -ac 1 -b:a:$index 128k -metadata:s:a:$index title=\"$language AC3 1.0 @ 128k\"" ;;
    2) options="-c:a:$index ac3 -ac 2 -b:a:$index 224k -metadata:s:a:$index title=\"$language AC3 2.0 @ 224k\"" ;;
    3) options="-c:a:$index ac3 -ac 3 -b:a:$index 320k -metadata:s:a:$index title=\"$language AC3 3.0 @ 320k\"" ;;
    4) options="-c:a:$index ac3 -ac 4 -b:a:$index 448k -metadata:s:a:$index title=\"$language AC3 4.0 @ 448k\"" ;;
    *) options="-c:a:$index ac3 -ac 6 -b:a:$index 640k -metadata:s:a:$index title=\"$language AC3 5.1 @ 640k\"" ;;
    esac
  else
    options="-c:a:$index copy"
  fi

  echo "$options"
}

process_subtitles() {
  local subtitle_info="$1"
  local maps=""
  local need_transcode=false
  local sub_relative_index=0

  while IFS=, read -r sub_index codec_name; do
    if [[ "$codec_name" == "ass" ]]; then
      maps+="-map 0:$sub_index? -c:s:$sub_relative_index text "
      need_transcode=true
    else
      maps+="-map 0:$sub_index? -c:s:$sub_relative_index copy "
    fi
    sub_relative_index=$((sub_relative_index + 1))
  done <<<"$subtitle_info"

  echo "$maps|$need_transcode"
}

process_audio() {
  local audio_info="$1"
  local maps=""
  local need_transcode=false
  local audio_relative_index=0
  local main_stream_set=false

  while IFS=, read -r index codec_name channels language; do
    if [[ " ${desired_languages[*]} " == *" $language "* ]]; then
      local transcode_options=""

      if [[ "$language" == "$main_language" && $main_stream_set == false ]]; then
        transcode_options=$(get_transcode_options "$codec_name" "$channels" "$audio_relative_index")
        maps+="-map 0:$index $transcode_options -disposition:a:$audio_relative_index default "
        main_stream_set=true
      else
        transcode_options=$(get_transcode_options "$codec_name" "$channels" "$audio_relative_index")
        maps+="-map 0:$index $transcode_options -disposition:a:$audio_relative_index 0 "
      fi
      audio_relative_index=$((audio_relative_index + 1))

      if [[ "$transcode_options" != *"copy"* ]]; then
        need_transcode=true
      fi
    fi
  done <<<"$audio_info"

  echo "$maps|$need_transcode"
}

process_file() {
  local input_file="$1"

  # Handle directory traversal
  if [ -d "$input_file" ]; then
    if $traverse_subdirs; then
      echo "Traversing directory: $input_file"
      for sub_file in "$input_file"/*; do
        process_file "$sub_file"
      done
    else
      echo "Skipping directory: $input_file"
    fi
    return
  fi

  # Check if file exists
  if [ ! -f "$input_file" ]; then
    echo "Skipping non-file $input_file"
    return
  fi

  # Get stream information
  local subtitle_info
  subtitle_info=$(ffprobe -v error -select_streams s -show_entries stream=index,codec_name -of csv=p=0 "$input_file")

  local audio_info
  audio_info=$(ffprobe -v error -select_streams a -show_entries stream=index,codec_name,channels:stream_tags=language -of csv=p=0 "$input_file")

  if [ "$(echo "$audio_info" | wc -l)" -eq 0 ]; then
    return # No audio streams found
  fi

  # Process streams
  local subtitle_results
  subtitle_results=$(process_subtitles "$subtitle_info")
  IFS='|' read -r subtitle_maps sub_needs_transcode <<<"$subtitle_results"

  local audio_results
  audio_results=$(process_audio "$audio_info")
  IFS='|' read -r audio_maps audio_needs_transcode <<<"$audio_results"

  # Build and execute ffmpeg command if needed
  if [ "$sub_needs_transcode" = "true" ] || [ "$audio_needs_transcode" = "true" ]; then
    local input_extension="${input_file##*.}"
    local output_file="${input_file%.*}_transcoded.$input_extension"

    local ffmpeg_cmd="ffmpeg -loglevel warning -stats -i \"$input_file\" -c copy -map 0:v "
    ffmpeg_cmd+="$subtitle_maps $audio_maps \"$output_file\""
    
    echo "Running: $ffmpeg_cmd"
    eval "$ffmpeg_cmd"

    if [ -f "$output_file" ] && $overwrite; then
      mv "$output_file" "$input_file"
    fi
  fi
}

# Support SABnzbd post processing scripts
# SAB_COMPLETE_DIR is set by SABnzbd and contains the abs path to the completed download directory
if [ -n "$SAB_COMPLETE_DIR" ]; then
  cd "$SAB_COMPLETE_DIR" || exit 1

  # Make ffmpeg/ffprobe available for more shell environments (sabnzbd scripts PATH scope is limited)
  export PATH=$PATH:/opt/homebrew/bin:/lsiopy/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

  traverse_subdirs=true # In case release contains video files in subdirs
  overwrite=true        # Remove this if you want to keep the original

  for input_file in *.mkv *.mp4; do
    process_file "$input_file"
  done

  exit 0
fi

# Support Sonarr/Radarr post processing scripts
# File paths are passed as environment variables (sonarr_episodefile_path and radarr_moviefile_path)
# shellcheck disable=SC2154
if [ -f "$sonarr_episodefile_path" ]; then
  echo "Processing file from Sonarr: $sonarr_episodefile_path"
  overwrite=true # Remove this if you want to keep the original file
  process_file "$sonarr_episodefile_path"
  exit 0
elif [ -f "$radarr_moviefile_path" ]; then
  echo "Processing file from Radarr: $radarr_moviefile_path"
  overwrite=true # Remove this if you want to keep the original file
  process_file "$radarr_moviefile_path"
  exit 0
fi

# Arguments take precedence, if none are passed, process all files in the current dir
if [ $# -gt 0 ]; then
  for input_file in "$@"; do
    process_file "$input_file"
  done
else
  for input_file in *.mkv *.mp4; do
    process_file "$input_file"
  done
fi
