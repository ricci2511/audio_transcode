#!/bin/bash

#####################################################################
# Audio Transcoding Script
#
# This script aims to transcode audio streams in video files to ac3 format with 640k bitrate.
# Stereo audio streams are transcoded to ac3 format with 224k bitrate.
# 3-4 channel audio streams are transcoded to ac3 format with 448k bitrate.
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

process_file() {
  local input_file="$1"

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

  if [ ! -f "$input_file" ]; then
    echo "Skipping non-file $input_file"
    return
  fi

  # Grab all relevant audio streams info (index, codec, channels, language)
  local ffprobe_output
  ffprobe_output=$(ffprobe -v error -select_streams a -show_entries stream=index,codec_name,channels:stream_tags=language -of csv=p=0 "$input_file")

  if [ "$(echo "$ffprobe_output" | wc -l)" -eq 0 ]; then
    return # Empty output means no audio streams found
  fi

  local input_extension="${input_file##*.}"
  local output_file="${input_file%.*}_transcoded.$input_extension"

  local ffmpeg_cmd="ffmpeg -loglevel warning -stats -i \"$input_file\" -c copy -map 0:v -map 0:s "
  local main_lang_map=""       # Used to make sure that main language is the first audio stream
  local other_lang_maps=""     # Used for all other audio streams
  local main_lang_exists=false # Flag to check if main language exists within the audio streams
  local main_stream_set=false  # Flag to check if main audio stream is set already
  local need_transcode=false   # Flag to check if any audio streams need to be transcoded (only if true ffmpeg will be executed)

  # Check if main language exists within the audio streams
  if echo "$ffprobe_output" | grep -q "$main_language"; then
    main_lang_exists=true
  fi

  while IFS=, read -r index codec_name channels language; do
    local stream_index=$((index - 1)) # FFmpeg stream index starts from 0

    if [[ " ${desired_languages[*]} " == *" $language "* ]]; then
      local stream_map="-map 0:a:$stream_index "
      local transcode_options=""

      if [[ "$language" == "$main_language" && $main_stream_set == false ]]; then
        main_lang_map="$stream_map"
        transcode_options=$(get_transcode_options "$codec_name" "$channels" 0)
        main_lang_map+="$transcode_options"
        main_stream_set=true
      else
        local mapped_index=$stream_index
        if $main_lang_exists && [ "$stream_index" -eq 0 ]; then
          mapped_index=1 # 0 index is reserved for the main audio stream
        fi
        other_lang_maps+="$stream_map"
        transcode_options=$(get_transcode_options "$codec_name" "$channels" "$mapped_index")
        other_lang_maps+="$transcode_options -disposition:a:$mapped_index 0 " # Ensure non-main audio streams are not default
      fi

      if [[ "$transcode_options" != *"copy"* ]]; then
        need_transcode=true
      fi
    else
      echo "Skipping audio stream $index in '$input_file' with language '$language'"
    fi
    stream_index=$((stream_index + 1))
  done <<<"$ffprobe_output"

  if $need_transcode; then
    ffmpeg_cmd+="$main_lang_map $other_lang_maps -disposition:a:0 default \"$output_file\""
    echo "Running: $ffmpeg_cmd"
    eval "$ffmpeg_cmd"
  fi

  if [ -f "$output_file" ] && $overwrite; then
    mv "$output_file" "$input_file"
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
