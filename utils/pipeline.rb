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
  def self.calculate_vid_length(imgs, audio_file_path, script, 
                                msg, prompt, api_tokens)
    begin
      duration = WahWah.open(audio_file_path).duration
      to_return = {}
      
      if imgs.length == 1
        to_return[imgs.first] = duration
      elsif imgs.length > 1 
        speaking_rate = TextStat.syllable_count(script).fdiv(duration)
        resp, err = Gemini.chat(msg, prompt, api_tokens)
        raise err unless err.nil?
        
        parts = resp.split(BREAK_DELIMITER).map(&:strip)
        parts.each_index do |i|
          to_return[imgs[i]] = TextStat.syllable_count(parts[i]).fdiv(speaking_rate)
        end
      else
        raise "`#{imgs}` is empty."
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
  #
  # Note that this function will also create a transitions path "TRANSITIONS_FOLDER" - 
  # whose value is at the bottom of this module - to store our section transition 
  # scenes:
  def self.make_backdrops(section_images, durations, output_folder)
    transitions_path = File.join(output_folder, TRANSITIONS_FOLDER).gsub(/\/+/, '/')
    Dir.mkdir(transitions_path) unless Dir.exist? transitions_path

    section_images.each_pair do |section, images|
      raise "Section #{section} has no images!" if images.empty?
      title, section_durs = map_title(section), durations.filter{|x| x == section}
      raise title if title.is_a? StandardError
      gen_backdrop(section_durs, output_folder)
      gen_title_secs(section, transitions_path)
    end
    nil
  end


  # Given a path to a backdrop and a path to a talking avatar, overlay the latter 
  # ON TOP of the backdrop and in the bottom-left corner.
  def self.overlay_avatar(avatar_clip, backdrop_path)
    raise "#{avatar_clip} doesn't exist!" unless File.exist? avatar_clip
    raise "#{backdrop_path} doesn't exist!" unless File.exist? backdrop_path
    
    output = "#{backdrop_path.split('.mp4').first.strip}_overlayed.mp4"
    complex_filter = [
      "[1:v]scale=320:-1[small_avatar];",
      "[0:v][small_avatar]overlay=x=10:y=main_h-overlay_h-10[outv]"
    ].join('')
    cmd = "ffmpeg -i \"#{backdrop_path}\" -i \"#{avatar_clip}\" " \
          "-filter_complex \"#{complex_filter}\" " \
          "-map \"[outv]\" -map 1:a " \
          "-c:v libx264 -pix_fmt yuv420p -c:a aac -shortest -y \"#{output}\""
    system(cmd)
  end


  # --- Private helper functions ---
  def self.choose_ken_burns_dir
    case rand(1..5)
    when 1 then { x: "iw/2-(iw/zoom/2)", y: "ih/2-(ih/zoom/2)" }
    when 2 then { x: "0", y: "0" }
    when 3 then { x: "iw-(iw/zoom)", y: "0" }
    when 4 then { x: "0", y: "ih-(ih/zoom)" }
    when 5 then { x: "iw-(iw/zoom)", y: "ih-(ih/zoom)"}
    end
  end

  # Given a section, map it to the appropriate title:
  def self.map_title(str)
    case str.downcase
    when 'your_diagnosis' then ['Your Diagnosis', nil]
    when 'planned_surgery' then ['Planned Surgery', nil]
    when 'risks_and_benefits' then ['Risks and Benefits of the Planned Surgery', nil]
    when 'recovery' then ['Recovery and Follow-Up', nil]
    else 
      [nil, "Could not match a title for input `#{str}`"]
    end
  end

  # Given the duration of the images for a section and an output folder, generate the backdrop itself.
  def self.gen_backdrop(img_durs, output_folder)
    sec_name = img_durs.keys.first
    title, err = map_title(sec_name)
    raise err unless err.nil?
    img_durs, num_imgs = img_durs[sec_name], img_durs.length

    if num_imgs == 1
      rand_ken_burns, total_dur = choose_ken_burns_dir, img_durs.values.first
      filters = [
        "scale=1280:720:force_original_aspect_ratio=decrease",
        "pad=1280:720:(ow-iw)/2:(oh-ih)/2",
        "zoompan=z='zoom+0.0015':x='#{rand_ken_burns[:x]}':y='#{rand_ken_burns[:y]}':d=250:s=1280x720:fps=25",
        "fade=t=in:st=0:d=#{FADE_DURATION}",
        "fade=t=out:st=#{total_dur - FADE_DURATION}:d=#{FADE_DURATION}",
        "drawtext=text='#{title}':fontcolor=white:fontsize=24:" \
        "x=(w-text_w)/2:y=20:box=1:boxcolor=black@0.6:boxborderw=10"
      ].join(', ')
      cmd = "ffmpeg -loop 1 -t #{total_dur} -i \"#{img_durs.keys.first}\" " \
            "-vf \"#{filters}\" " \
            "-c:v libx264 -pix_fmt yuv420p -y \"#{File.join(output_folder, sec_name).gsub(/\/+/, '/')}.mp4\""
    else 
      total_dur = img_durs.values.sum
      ken_burns_parts = num_imgs.times.map do |x| 
        dir = choose_ken_burns_dir
        ["[0:v]scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,",
          "zoompan=z='zoom+0.0015':x='#{dir[:x]}':y='#{dir[:y]}':d=250:s=1280x720:fps=25[v1];"]
      end
      filters = [ken_burns_parts, "[v1][v2]xfade=transition=fade:duration=#{FADE_DURATION}:offset=#{img_durs.values.first - FADE_DURATION}[crossed];",
                "[crossed]fade=t=in:st=0:d=#{FADE_DURATION},",
                "fade=t=out:st=#{FADE_DURATION}:d=#{total_dur - FADE_DURATION}[faded];",
                "[crossed]drawtext=text='#{title}':fontcolor=white:fontsize=24:",
                "x=(w-text_w)/2:y=20:box=1:boxcolor=black@0.6:boxborderw=10"].flatten.join(', ')
      loop_parts = img_durs.map{|k, v| "-loop 1 -t #{v} -i \"#{k}\""}.join(' ')
      cmd = "ffmpeg #{loop_parts} " \
          "-filter_complex \"#{filters}\" " \
          "-c:v libx264 -pix_fmt yuv420p -y \"#{File.join(output_folder, sec_name).gsub(/\/+/, '/')}.mp4\""
    end 
    system(cmd)
  end


  # Given a section name, generate the transition like we previously did in that other process and save it in an output folder:
  def self.gen_title_secs(sec, output_folder)
    title, err = map_title(sec)
    raise err unless err.nil?
    Dir.mkdir(output_folder) unless Dir.exist? output_folder

    total_dur, fade_dur = 5, 1
    output_path = File.join(output_folder, "#{sec}.mp4").gsub(/\/+/, '/')
    filters = [
      "drawtext=text='#{title}':fontcolor=white:fontsize=36:",
      "x=(w-text_w)/2:y=(h-text_h)/2,",
      "fade=t=in:st=0:d=#{fade_dur},",
      "fade=t=out:st=#{total_dur - fade_dur}:d=#{fade_dur}"
    ].join('')
    cmd = "ffmpeg -f lavfi -i color=c=black:s=1280x720:r=25 -t #{total_dur} " \
          "-vf \"#{filters}\" " \
          "-c:v libx264 -pix_fmt yuv420p -y \"#{output_path}\""
    system(cmd)
  end

  private 
  BREAK_DELIMITER = '<BREAK>'
  TRANSITIONS_FOLDER = 'transitions'

  FADE_DURATION, BETWEEN_TRANSITION = 2, 1
  
  private_class_method :choose_ken_burns_dir, :map_title
end