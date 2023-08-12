#!/bin/bash

#####################################################################
# Audio Transcoding Script
#
# This script transcodes audio streams in video files to eac3 format with 640k bitrate.
# Stereo audio streams are transcoded to ac3 format with 224k bitrate.
# It utilizes FFmpeg for audio transcoding and processing.
#
# Usage:
# ./audio_transcode.sh [OPTIONS] [FILE(s)]
#
# Options:
#   -o   Overwrite original files with transcoded audio.
#   -a   Process all files in the current directory.
#   -r   Traverse subdirectories and process their contents.
#
# Examples:
#   ./audio_transcode.sh -o movie.mkv
#   ./audio_transcode.sh -a
#   ./audio_transcode.sh -r
#
# Notes:
# - By default, the script preserves video and subtitle streams.
# - You can customize the audio transcoding settings within the script.
# - Supports Sonarr/Radarr custom scripts for Import/Upgrade events.
#
# Dependencies:
# - FFmpeg and ffprobe must be installed and accessible in your PATH.
#####################################################################

overwrite=false        # -o
all=false              # -a
traverse_subdirs=false # -r

# Parse command line arguments
while :
do
    case "$1" in
        -o)
            overwrite=true
            shift
            ;;
        -a)
            all=true
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
        echo "File $input_file does not exist"
        return
    fi

    input_extension="${input_file##*.}"
    copy_file="${input_file%.*}_copy.$input_extension"

    audio_streams=$(ffprobe -v error -select_streams a -show_entries stream=index -of default=noprint_wrappers=1:nokey=1 "$input_file" | wc -l)

    if [ "$audio_streams" -eq 0 ]; then
        echo "No audio streams found in '$input_file'"
        return
    fi

    for stream_index in $(seq 0 $((audio_streams - 1))); do
        audio_format=$(ffprobe -v error -select_streams a:$stream_index -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$input_file")
        audio_channels=$(ffprobe -v error -select_streams a:$stream_index -show_entries stream=channels -of default=noprint_wrappers=1:nokey=1 "$input_file")
        format_bitrate="eac3 -b:a:$stream_index 640k"

        # Use ac3 with 224k bitrate for stereo audio
        if [ "$audio_channels" -eq 2 ]; then
            format_bitrate="ac3 -b:a:$stream_index 224k"
        fi

        if [ "$audio_format" != "eac3" ] && [ "$audio_format" != "ac3" ]; then
            echo "Transcoding audio stream $stream_index in '$input_file' from $audio_format to eac3"
            # Can't overwrite copy_file in place, therefore use a temp file for now
            if [ -f "$copy_file" ]; then
                temp_file="${input_file%.*}_copy_temp.$input_extension"
                ffmpeg -y -i "$copy_file" -c copy -map 0 -c:a:$stream_index $format_bitrate "$temp_file"
                mv "$temp_file" "$copy_file"
            else
                ffmpeg -i "$input_file" -c copy -map 0 -c:a:$stream_index $format_bitrate "$copy_file"
            fi
        else
            echo "$input_file audio stream $stream_index is already in eac3 or ac3 format"
        fi
    done

    if [ "$overwrite" = true ]; then
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

if [ "$all" = true ]; then
    for input_file in *; do
        process_file "$input_file"
    done
else
    for input_file in "$@"; do
        process_file "$input_file"
    done
fi
