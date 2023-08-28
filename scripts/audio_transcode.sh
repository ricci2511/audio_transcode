#!/bin/bash

#####################################################################
# Audio Transcoding Script
#
# This script transcodes audio streams in video files to ac3 format with 640k bitrate.
# Stereo audio streams are transcoded to ac3 format with 224k bitrate.
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
# - If no arguments are passed, all files in the current directory are processed.
# - By default, the script preserves video and subtitle streams.
# - You can customize the audio transcoding settings within the script.
# - Supports Sonarr/Radarr custom scripts for Import/Upgrade events.
#
# Dependencies:
# - FFmpeg and ffprobe must be installed and accessible in your PATH.
#####################################################################

overwrite=false        # -o
traverse_subdirs=false # -r

# Parse command line arguments
while :
do
    case "$1" in
        -o)
            overwrite=true
            shift
            ;;
        -r)
            traverse_subdirs=true
            shift
            ;;
        -*)
            echo "Unknown option: $1"
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

if [ $overwrite = true ]; then
    echo "WARNING: passed -o argument, original files will be overwritten"
fi

transcode_audio() {
    local input_file="$1"
    local copy_file="$2"
    local stream_index="$3"

    local channels=$(ffprobe -v error -select_streams a:$stream_index -show_entries stream=channels -of default=noprint_wrappers=1:nokey=1 "$input_file")
    local lang=$(ffprobe -v error -select_streams a:$stream_index -show_entries stream_tags=language -of default=noprint_wrappers=1:nokey=1 "$input_file")

    local bitrate_channels="640k -ac 6"
    local stream_title="title=$lang AC3 5.1 @ 640k" # New title metadata for the transcoded audio stream

    # Use ac3 with 224k bitrate_channels for stereo audio
    if [ "$channels" -eq 2 ]; then
        bitrate_channels="224k -ac 2"
        stream_title="title=$lang AC3 2.0 @ 224k"
    fi

    if [ -f "$copy_file" ]; then
        if [ "$overwrite" = false ]; then
            # Can't overwrite copy_file in place, therefore use a temp file
            local temp_file="${input_file%.*}_copy_temp.$input_extension"
            ffmpeg -y -i "$copy_file" -c copy -map 0 -c:a:$stream_index ac3 -b:a:$stream_index $bitrate_channels -metadata:s:a:$stream_index "$stream_title" "$temp_file"
            mv "$temp_file" "$copy_file"
            return
        fi

        # Overwrite enabled, so replace the original with the copy, so it can be used as input to create the new copy below
        mv "$copy_file" "$input_file"
    fi

    ffmpeg -i "$input_file" -c copy -map 0 -c:a:$stream_index ac3 -b:a:$stream_index $bitrate_channels -metadata:s:a:$stream_index "$stream_title" "$copy_file"
}

process_file() {
    local input_file="$1"

    if [ -d "$input_file" ]; then
        if [ "$traverse_subdirs" = true ]; then
            echo "Traversing directory $input_file"
            cd "$input_file"
            for sub_file in *; do
                process_file "$sub_file"
            done
            cd ..
        else
            echo "Skipping directory $input_file"
        fi
        return
    fi

    if [ ! -f "$input_file" ]; then
        echo "Skipping non-file $input_file"
        return
    fi

    # Redirect invalid input file errors to /dev/null. In that case the streams count will be 0 and the file will be skipped.
    local audio_streams=$(ffprobe -v error -select_streams a -show_entries stream=index -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null | wc -l)
    if [ "$audio_streams" -eq 0 ]; then
        return
    fi

    local input_extension="${input_file##*.}"
    local copy_file="${input_file%.*}_copy.$input_extension"

    for stream_index in $(seq 0 $((audio_streams - 1))); do
        local audio_format=$(ffprobe -v error -select_streams a:$stream_index -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$input_file")

        if [ "$audio_format" != "eac3" ] && [ "$audio_format" != "ac3" ]; then
            echo "Transcoding audio stream $stream_index in '$input_file' from $audio_format to eac3"
            transcode_audio "$input_file" "$copy_file" "$stream_index"
        else
            echo "$input_file audio stream $stream_index is already in $audio_format format"
        fi
    done

    if [ -f "$copy_file" ] && [ "$overwrite" = true ]; then
        mv "$copy_file" "$input_file"
    fi
}

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
    for input_file in *; do
        process_file "$input_file"
    done
fi
