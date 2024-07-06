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
# - Only audio streams with languages specified in the `desired_languages` array are included in the output.
# - You can customize the audio transcoding settings within the script.
# - Supports Sonarr/Radarr custom scripts for Import/Upgrade events.
#
# Dependencies:
# - FFmpeg and ffprobe must be installed and accessible in your PATH.
#####################################################################

desired_audio_formats=("eac3" "ac3")        # Audio formats to just copy (no transcoding)
desired_languages=("eng" "ger" "spa" "jpn") # Any other lang is skipped
main_language="ger"                         # Main language for audio track selection (default)

overwrite=false        # -o
traverse_subdirs=false # -r

# Parse command line arguments
while :; do
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

	local base_ffmpeg_cmd="ffmpeg -i \"$input_file\" -c copy -map 0:v -map 0:s "
	local main_lang_map=""      # Used to make sure that main language is the first audio stream
	local other_lang_maps=""    # Used for all other audio streams
	local main_stream_set=false # Flag to check if main audio stream is set already
	local need_transcode=false  # Flag to check if any audio streams need to be transcoded (only if true ffmpeg will be executed)

	# Check if main language exists in the audio streams
	local main_lang_exists=false
	for stream_index in $(seq 0 $((audio_streams - 1))); do
		local lang=$(ffprobe -v error -select_streams a:$stream_index -show_entries stream_tags=language -of default=noprint_wrappers=1:nokey=1 "$input_file")
		if [ "$lang" = "$main_language" ]; then
			main_lang_exists=true
			break
		fi
	done

	for stream_index in $(seq 0 $((audio_streams - 1))); do
		local lang=$(ffprobe -v error -select_streams a:$stream_index -show_entries stream_tags=language -of default=noprint_wrappers=1:nokey=1 "$input_file")
		local audio_format=$(ffprobe -v error -select_streams a:$stream_index -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$input_file")
		local channels=$(ffprobe -v error -select_streams a:$stream_index -show_entries stream=channels -of default=noprint_wrappers=1:nokey=1 "$input_file")

		if [[ " ${desired_languages[@]} " =~ " ${lang} " ]]; then
			if [ "$lang" = "$main_language" ] && [ "$main_stream_set" = false ]; then
				main_lang_map="-map 0:a:$stream_index "
				if [[ ! " ${desired_audio_formats[@]} " =~ " ${audio_format} " ]]; then
					need_transcode=true
					# Using 0 since we're setting the main audio stream and it always will be the first
					if [ "$channels" -eq 2 ]; then
						main_lang_map+="-c:a:0 ac3 -b:a:0 224k -metadata:s:a:0 title=\"$lang AC3 2.0 @ 224k\" "
					else
						main_lang_map+="-c:a:0 ac3 -b:a:0 640k -metadata:s:a:0 title=\"$lang AC3 5.1 @ 640k\" "
					fi
				else
					main_lang_map+="-c:a:$stream_index copy "
				fi
				main_stream_set=true
			else
				other_lang_maps+="-map 0:a:$stream_index "

				local offsetted_index=$stream_index
				if [ "$main_lang_exists" = true ]; then
					offsetted_index=$((stream_index + 1)) # Increment by 1 if main language exists since that will be audio stream 0
				fi
				if [ $offsetted_index -gt $((audio_streams - 1)) ]; then
					offsetted_index=$((audio_streams - 1)) # Ensure that the offsetted index is not out of bounds
				fi

				if [[ ! " ${desired_audio_formats[@]} " =~ " ${audio_format} " ]]; then
					need_transcode=true
					if [ "$channels" -eq 2 ]; then
						other_lang_maps+="-c:a:$offsetted_index ac3 -b:a:$offsetted_index 224k -metadata:s:a:$offsetted_index title=\"$lang AC3 2.0 @ 224k\" "
					else
						other_lang_maps+="-c:a:$offsetted_index ac3 -b:a:$offsetted_index 640k -metadata:s:a:$offsetted_index title=\"$lang AC3 5.1 @ 640k\" "
					fi
				else
					other_lang_maps+="-c:a:$offsetted_index copy "
				fi
				other_lang_maps+="-disposition:a:$offsetted_index 0 " # Ensure non-main audio streams are not default
			fi
		else
			echo "Skipping audio stream $stream_index in '$input_file' with language '$lang'"
		fi
	done

	if [[ "$need_transcode" = true ]]; then
		local ffmpeg_cmd="$base_ffmpeg_cmd$main_lang_map$other_lang_maps-disposition:a:0 default \"$copy_file\""
		echo "Running: $ffmpeg_cmd"
		eval $ffmpeg_cmd
	fi

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
