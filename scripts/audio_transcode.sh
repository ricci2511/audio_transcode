#!/bin/bash

# This script transcodes audio from video files to eac3 format
# Requires ffmpeg and ffprobe to be installed and in your PATH
#
# I personally prefer to direct play my media, therefore I transcode all my audio to eac3

# Passing -o as an argument will set this to true and overwrite the original file with the transcoded one
overwrite=false
# Passing -a as an argument will set this to true and go through all files in the current directory
all=false
# Passing -r as an argument will set this to true and go through files in all subdirectories from the current directory
traverse_subdirs=false

# Parse command line arguments: -o and -a
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
        if [ "$audio_format" != "eac3" ] && [ "$audio_format" != "ac3" ]; then
            echo "Transcoding audio stream $stream_index in '$input_file' from $audio_format to eac3"
            # Can't overwrite copy_file in place, therefore use a temp file for now
            if [ -f "$copy_file" ]; then
                temp_file="${input_file%.*}_copy_temp.$input_extension"
                ffmpeg -y -i "$copy_file" -c copy -map 0 -c:a:$stream_index eac3 -b:a:$stream_index 640k "$temp_file"
                mv "$temp_file" "$copy_file"
            else
                ffmpeg -i "$input_file" -c copy -map 0 -c:a:$stream_index eac3 -b:a:$stream_index 640k "$copy_file"
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
# They pass the file paths as environment variables, sonarr_episodefile_path and radarr_moviefile_path
if [ -n "$sonarr_episodefile_path" ]; then
    process_file "$sonarr_episodefile_path"
    exit 0
elif [ -n "$radarr_moviefile_path" ]; then
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
