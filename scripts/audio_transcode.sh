#!/bin/bash

# This script transcodes audio from video files to eac3 format
# Requires ffmpeg and ffprobe to be installed and in your PATH
#
# I personally prefer to direct play my media, therefore I transcode all my audio to eac3

# Passing -o as an argument will set this to true and overwrite the original file with the transcoded one
overwrite=false
# Passing -a as an argument will set this to true and go through all files in the current directory
all=false

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
        echo "Skipping directory $input_file"
        return
    fi

    if [ ! -f "$input_file" ]; then
        echo "File $input_file does not exist"
        return
    fi

    input_extension="${input_file##*.}"
    copy_file="${input_file%.*}_copy.$input_extension"

    audio_format=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$input_file")

    if [ "$audio_format" != "eac3" ] || [ "$audio_format" != "ac3" ]; then
        echo "Transcoding audio in '$input_file' from $audio_format to eac3"
        ffmpeg -i "$input_file" -map 0 -c:v copy -c:a eac3 -b:a 640k -c:s copy "$copy_file"
        if [ "$overwrite" = true ]; then
            mv "$copy_file" "$input_file"
        fi
        echo "Done"
    else
        echo "$input_file audio is already in eac3 or ac3 format"
    fi
}

if [ "$all" = true ]; then
    for input_file in *; do
        process_file "$input_file"
    done
else
    for input_file in "$@"; do
        process_file "$input_file"
    done
fi
