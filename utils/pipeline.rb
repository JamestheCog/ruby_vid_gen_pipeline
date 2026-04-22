# A module to house helper functions that have to do with the pipeline's functioning - but mainly to do with 
# the pipeline's content generation bit:

require 'wahwah'
require 'textstat'
require 'ffmpeg_core'
require 'fileutils'
require_relative 'gemini'

module PipelineHelpers
  # Given a couple of items:
  #
  # 1) An array containing the file paths to the selected images.
  # 2) The path to the audio file.
  # 3) The path to the script for the segment
  # 4) The message to be sent to Gemini
  # 5) The prompt to be sent to Gemini
  # 6) API tokens for video generation
  #
  # Generate the video backdrops to be used in the video:
  def self.calculate_vid_length(img_file_paths, audio_file_path, script, 
                                msg, prompt, api_tokens)
    begin
      duration = WahWah.open(audio_file_path).duration
      to_return = {}

      if img_file_paths.length == 1
        to_return[img_file_paths.first] = duration
      elsif img_file_paths.length > 1 
        speaking_rate = TextStat.syllable_count(script).fdiv(duration)
        msg = msg % [img_file_paths.length - 1, script]
        resp, err = Gemini.chat(msg, prompt, api_tokens)
        raise err unless err.nil?
        
        parts = resp.split(BREAK_DELIMITER).map(&:strip)
        parts.each_index do |i|
          to_return[img_file_paths[i]] = TextStat.syllable_count(parts[i]).fdiv(speaking_rate)
        end
      else
        raise "`#{img_file_paths}` is empty."
      end
      [to_return, nil]
    rescue StandardError => e 
      [nil, e.message]
    end 
  end

  # Creates the videos given:
  #
  # 1) `section_images` -> a folder path to array of full path image names (hash) 
  # 2) `durations` -> a folder to durations (hash)
  # 3) `output_folder` the folder that you want the backdrops to be in.
  def self.make_backdrops(section_images, durations, output_folder)
    section_images.each do |section, images|
      raise "`#{section}` is empty." if images.empty?
      final, movie = File.join(output_folder, section + '.mp4').gsub(/\/+/, '/'), nil
      images.each_with_index do |img, i|
        temp_name = File.join(output_folder, "temp_#{i + 1}_#{img.split('/')[-1].strip}.mp4").gsub(/\/+/, '/')
        movie = FFmpegCore::Movie.new(img)
        movie.transcode(temp_name, {custom: KEN_BURNS})
      end

      temp_clips = Dir.glob("#{output_folder}/temp_*")
      if images.length == 1 
        movie.transcode(final, {
          video_codec: 'libx264', audio_codec: 'aac',
          custom: FADE_TRANSITION
        })
      else 
        FFmpegCore::Movie.new(temp_clips.first).transcode(final, {
          inputs: temp_clips[1..-1], filter_graph: MULTI_FADE_TRANSITION,
          map: ['[v]', '[a]'], video_codec: 'libx264', audio_codec: 'aac',
          pix_fmt: 'yuv420p'
        })
      end 
      FileUtils.rm_rf(temp_clips)
    end
    nil
  end

  def self.make_transition(text, output_name, duration = 3)
    movie = FFmpegCore::Movie.new("-f lavfi -i color=c=black:s=1920x#1080:d=#{duration}:r=30")
    movie.transcode(output_name, {
      video_codec: "libx264",
      audio_codec: "aac",
      pix_fmt: "yuv420p",
      custom: "-vf \"drawtext=font=Arial:text='#{text};fontsize=80:fontcolor=white:x=(w-text_w)/2:" +
              "y=(h-text_h)/2:box=1:boxcolor=black@0.5:boxborderw=20\""
    })
  end

  def self.overlay_avatar(video_path, avatar_path, output_name)
    video = FFmpegCore::Movie.new(video_path)
    video.transcode(output_name, {
      inputs: [avatar_path],
      filter_graph: ["[0:v][1:v]overlay=10:10:enable='between(t,5,15)'[v]"],
      map: ["[v]", "0:a"], video_codec: "libx264", audio_codec: "copy"
    })
  end

  # Stitches videos up
  def self.stitch_videos(videos, final_output_name)
    TEMP_FILE_NAME = 'TEMP_CAT.txt'
    output = final_output_name.end_with?('.mp4') ? final_output_name : final_output_name + '.mp4'

    File.write(TEMP_FILE_NAME, videos.map{|x| "file '#{x}'\n"})
    movie = FFmpegCore::Movie.new(videos.first)
    movie.transcode(output, {custom: "-f concat -safe 0 -i #{TEMP_FILE_NAME} -c copy"})
    File.delete(TEMP_FILE_NAME)
  end

  private 
  BREAK_DELIMITER = '<BREAK>'
  FADE_DURATION, BETWEEN_TRANSITION = 2, 0.5
  KEN_BURNS = "-loop 1 -t 10 -vf " + 
              "scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2," +
              "zoompan=z='zoom+0.0015':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=250:s=1280x720:fps=25 " +
              "-c:v libx264 -pix_fmt yuv420p"
  FADE_TRANSITION = "-vf fade=t=in:st=0:d=2,fade=t=out:st=#{movie.duration - FADE_DURATION}:d=2 " +
                    "-af afade=t=in:st=0:d=2,afade=t=out:st=#{movie.duration - FADE_DURATION}:d=2"
  MULTI_FADE_TRANSITION = ["[0:v][1:v]xfade=transition=fade:duration=1.5:offset=#{BETWEEN_TRANSITION}[v]",
                          "[0:a][1:a]acrossfade=d=1.5[a]"]
end