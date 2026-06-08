# A module to contain parts of the pipeline - essentially a Rubified version of the original pipeline.  It's now been modularized
# and refactored to have Go-style error handling.

require 'rb_edge_tts'
require 'fileutils'
require_relative '../utils/gemini'
require_relative '../utils/RAG'
require_relative '../utils/reader'
require_relative '../utils/pipeline'
require_relative 'setup'

module Pipeline 
  # The first part of the pipeline - generating video components to be uploaded onto
  # shotstack later.  We'll be creating / fetching the following here namely:
  # 
  # 1) Simplified text summaries for script generation
  # 2) The scripts themselves
  # 3) The images description themselves to perform RAG with.
  # 4) The audio outputs
  def self.create_components(clin_note_path, num_imgs, user_output)
    # Step 0.25 -> Load in the system variables, the prompts, and the 
    #              messages.
    sys_vars, err = Setup.fetch_sys_vars; raise "sys_vars: #{err}" unless err.nil?
    raise 'RAG DB not initialized' unless File.exist?(sys_vars['rag_db'])
    prompts, err = Setup.fetch_files(sys_vars['prompt_folder_path']); raise "prompts: #{err}" unless err.nil?
    msgs, err = Setup.fetch_files(sys_vars['message_folder_path']); raise "msgs: #{err}" unless err.nil?
    api_tokens = File.readlines(sys_vars['api_token_path']).map(&:strip); 
    
    # Step 0.5 -> Create the directory and the PStore database to track
    #             state:
    Dir.mkdir(OUTPUT_PATH) unless Dir.exist?(OUTPUT_PATH)
    output_path = File.join(OUTPUT_PATH, user_output).gsub(/\/+/, '/')
    Dir.mkdir(output_path) unless Dir.exist?(output_path)
    state_path = File.join(output_path, Setup::SETUP_DB_NAME).gsub(/\/+/, '/')
    err = Setup.init_state_db!(state_path); raise err unless err.nil?

    # Step 0.75 -> Update the main state dictionary for the system to keep track of 
    #              this specific user_output file:
    system_state_db = PStore.new(sys_vars['state_db_path'])
    system_state_db.transaction do |state|
      state['user_states'] ||= []
      state['user_states'] << state_path 
    end
    
    # Step 1 -> Read in the clinical note.
    clin_note, err = Reader.text(clin_note_path); raise err unless err.nil?

    # Step 2 and onwards -> creating the video's components so that we can throw something together 
    #                       ffmpeg at a later time:
    checkpoints = nil
    PStore.new(state_path).transaction do |pstore| 
      pstore['output'] ||= {}
      checkpoints = pstore['checkpoints'] || {}
    end

    # Begin our processes here:
    Setup::PIPELINE_PHASES.each do |phase|
      next if checkpoints[phase]
      case phase
      when 'sum_gen' then sum_gen(msgs, prompts, clin_note, api_tokens, state_path)
      when 'image_descs' then image_desc_gen(msgs, prompts, num_imgs, api_tokens, state_path)
      when 'image_fetch' 
        img_path = File.join(output_path, IMG_OUTPUT_FOLDER).gsub(/\/+/, '/')
        image_fetch(img_path, sys_vars, state_path, api_tokens)
      when 'script_gen' then script_gen(msgs, prompts, api_tokens, state_path)
      when 'simplify' 
        script_output_path = File.join(output_path, SCRIPT_OUTPUT_FOLDER).gsub(/\/+/, '/')
        simplify(msgs, prompts, script_output_path, api_tokens, state_path)
      when 'audio'
        audio_output_path = File.join(output_path, AUDIO_OUTPUT_FOLDER).gsub(/\/+/, '/')
        make_audio(audio_output_path, state_path)
      when 'duration_calc' then calculate_duration(msgs, prompts, output_path, api_tokens, state_path)
      when 'backdrop' then make_backdrops(output_path, state_path)
      end
      checkpoints[phase] = true
    end
    PStore.new(state_path).transaction{|pstore| pstore['checkpoints'] = checkpoints}
    nil
  end

  # To be run post-SadTalker: for final video assembly with the talking avatar in the bottom left 
  # corner of the screen:
  def self.assemble_videos(final_name, backdrop_folder, avatar_folder, transitions_folder)
    [backdrop_folder, avatar_folder, transitions_folder].each do |i|
      raise "path `#{i}` does not exist" unless Dir.exist? i
    end
  
    backdrops = Dir.glob("#{backdrop_folder}/*").filter{|x| x.end_with? '.mp4'}.map{|x| [x.split('/').last.gsub(/.mp4/, '').intern, x]}.to_h
    avatars = Dir.glob("#{avatar_folder}/*").map{|x| [x.split('/').last.gsub(/.mp4/, '').intern, x]}.to_h
    transitions = Dir.glob("#{transitions_folder}/*").map{|x| [x.split('/').last.gsub(/.mp4/, '').intern, x]}.to_h
    backdrops.each_pair do |k, v| 
      next if k.end_with? 'overlayed'
      # PipelineHelpers.overlay_avatar(avatars[k], v)
      backdrops[k] = "#{v.split('.mp4').first.strip}_overlayed.mp4"
    end

    to_stitch = TOPIC_ORDER.map{|x| [transitions[x.intern], backdrops[x.gsub('_overlayed', '').intern]]}.flatten

    input_flags, filter_nodes = to_stitch.map{|x| "-i \"#{x}\""}.join(" "), []

    to_stitch.each_with_index do |clip, i|
      if clip.include?("transition")
        filter_nodes << "[#{i}:v]null[v#{i}];"
        filter_nodes << "anullsrc=channel_layout=stereo:sample_rate=44100[a#{i}];"
      else
        filter_nodes << "[#{i}:v]null[v#{i}];[#{i}:a]anull[a#{i}];"
      end
    end

    final_name = final_name.end_with?('.mp4') ? final_name : "#{final_name.strip}.mp4"
    concat_inputs = (0...to_stitch.length).map {|i| "[v#{i}][a#{i}]"}.join('')
    filter_nodes << "#{concat_inputs}concat=n=#{to_stitch.length}:v=1:a=1[outv][outa]"
    # We swapped libx264 for h264_nvenc and added the queue size limit
    cmd = "ffmpeg #{input_flags} -filter_complex \"#{filter_nodes.join('')}\" " \
          "-map \"[outv]\" -map \"[outa]\" " \
          "-c:v h264_nvenc -preset medium -pix_fmt yuv420p " \
          "-c:a aac -max_muxing_queue_size 4096 -y \"#{final_name}\""
    system(cmd)
    nil
  end


  # --- Private variables and / or functions ---
  private   
  SUMMARY_SEP = '<sep>'
  SCRIPT_OUTPUT_FOLDER = 'scripts'
  IMG_OUTPUT_FOLDER = 'img'
  AUDIO_OUTPUT_FOLDER = 'audio'
  BACKDROP_FOLDER = 'backdrops'
  OUTPUT_PATH = 'output'
  TOPIC_ORDER = ['your_diagnosis', 'planned_surgery', 
                  'risks_and_benefits', 
                  'recovery']

  # Process for summary generation phase:
  def self.sum_gen(msg_hash, prompt_hash, clin_note, api_tokens, pstore_path)
    PStore.new(pstore_path).transaction do |pstore|
      pstore.ultra_safe = true
      raw_outputs = pstore['outputs'] || {}
      outputs = Marshal.load(Marshal.dump(raw_outputs))

      msg, prompt = msg_hash['sum_gen'], prompt_hash['sum_gen']
      res, err = Gemini.chat(msg % clin_note, prompt, api_tokens)
      raise err unless err.nil?
      outputs['sum_gen'] = res.split(/\n\n/).map{|x| x.split(SUMMARY_SEP).map(&:strip)}.to_h
      pstore['outputs'] = outputs
    end
  end

  # Ditto, but for the image generation phase:
  def self.image_desc_gen(msg_hash, prompt_hash, num_imgs, api_tokens, pstore_path)
    PStore.new(pstore_path).transaction do |pstore|
      pstore.ultra_safe = true
      raw_outputs = pstore['outputs'] || {}
      outputs = Marshal.load(Marshal.dump(raw_outputs))
      outputs['image_desc'] = {}

      msg, prompt = msg_hash['image_desc'], prompt_hash['image_desc']
      outputs['sum_gen'].each_pair do |sec, sum|
        to_send = msg % [num_imgs[sec.intern], sum]
        res, err = Gemini.chat(to_send, prompt, api_tokens)
        raise err unless err.nil?
        outputs['image_desc'][sec] = res.split(/\n\n/).map(&:strip)
      end
      pstore['outputs'] = outputs
    end
  end

  # Ditto, but for image fetching part:
  def self.image_fetch(img_folder, sys_vars, pstore_path, api_tokens)
    Dir.mkdir(img_folder) unless Dir.exist? img_folder
    PStore.new(pstore_path).transaction do |pstore|
      pstore.ultra_safe = true
      raw_outputs = pstore['outputs'] || {}
      outputs = Marshal.load(Marshal.dump(raw_outputs))

      outputs['image_desc'].each_pair do |k, v|
        sec_img_folder, cur_img = File.join(img_folder, k).gsub(/\/+/, '/'), 1
        Dir.mkdir sec_img_folder unless Dir.exist? sec_img_folder
        v.each do |desc|
          search_params = {'desc': desc.slice(0, [desc.length, RAG::MAX_SEARCH_SIZE].min), 'topic_mapping': RAG::TOPIC_MAPPINGS[k.intern]}
          imgs, err = RAG.find_closest_match(search_params, Setup::RAG_DB_FILEPATH, Setup::RAG_DB_TABLES.first,
                                            api_tokens)
          raise err unless err.nil?
          imgs.each_with_index do |img, i|
            FileUtils.cp(File.join(sys_vars['images_path'], "#{img}.png").gsub(/\/+/, '/'), 
                        File.join(sec_img_folder, "#{cur_img}_#{imgs.first}.png"))
            cur_img += 1
          end
        end
      end
      pstore['outputs'] = outputs
    end
  end

  # Ditto, but for script generation:
  def self.script_gen(msg_hash, prompt_hash, api_tokens, pstore_path)
    PStore.new(pstore_path).transaction do |pstore|
      pstore.ultra_safe = true
      raw_outputs = pstore['outputs'] || {} 
      outputs = Marshal.load(Marshal.dump(raw_outputs))
      outputs['script_gen'] = {}

      outputs['sum_gen'].each_pair do |k, v|
        source, err = RAG.find_closest_match(v, Setup::RAG_DB_FILEPATH, Setup::RAG_DB_TABLES.last, api_tokens)
        raise err unless err.nil?
        source = File.read(source)

        msg = msg_hash['script_gen'] % [v, outputs['image_desc'][k].join("\n\n")] + "\n\n -- Source to use to build content -- \n\n#{source}"
        res, err = Gemini.chat(msg, prompt_hash['script_gen'], api_tokens)
        raise err unless err.nil?
        outputs['script_gen'][k] = res
      end
      pstore['outputs'] = outputs
    end
  end

  # Ditto, but for simplification
  def self.simplify(msg_hash, prompt_hash, script_output_path, api_tokens, pstore_path)
    Dir.mkdir(script_output_path) if !File.exist?(script_output_path)
    msg, prompt = msg_hash['simplify'], prompt_hash['simplify']

    PStore.new(pstore_path).transaction do |pstore|
      pstore.ultra_safe = true
      raw_outputs = pstore['outputs'] || {}
      outputs = Marshal.load(Marshal.dump(raw_outputs))
      outputs['simplify'], scripts = {}, outputs['script_gen']

      TOPIC_ORDER.each_with_index do |topic, i|
        prior = TOPIC_ORDER[0, i].empty? ? '' : TOPIC_ORDER[0, i].map{|x| scripts[x]}.join("\n\n")
        to_send = msg % [prior, scripts[topic]]
        resp, err = Gemini.chat(to_send, prompt, api_tokens)
        raise "Cannot simplify script because #{err}" unless err.nil?

        puts "This is the simplified script for the topic #{topic}: #{resp}\n\n"

        outputs['simplify'][topic] = resp
        File.write(File.join(script_output_path, topic + '.txt'), resp)
      end 
      pstore['outputs'] = outputs
    end
  end

  # Create the audio files after script simplification:
  def self.make_audio(audio_output_path, pstore_path)
    Dir.mkdir audio_output_path unless Dir.exist? audio_output_path
    PStore.new(pstore_path).transaction do |pstore|
      pstore['outputs']['simplify'].each_pair do |k, v|
        audio = RbEdgeTTS::Communicate.new(v)
        audio.save(File.join(audio_output_path, k + '.mp3'))
      end
    end
  end

  # Calculates the duration of the audio file in the previous method:
  def self.calculate_duration(msg_hash, prompt_hash, output_path, api_tokens, pstore_path)
    msg, prompt = msg_hash['script_splitting'], prompt_hash['script_splitting']
    backdrop = {}

    PStore.new(pstore_path).transaction do |pstore|
      pstore.ultra_safe = true
      raw_outputs = pstore['outputs'] || {}
      outputs = Marshal.load(Marshal.dump(raw_outputs))

      outputs['simplify'].each_key do |k|
        imgs = File.join(output_path, IMG_OUTPUT_FOLDER, k).gsub(/\/+/, '/') + '/*'
        script = File.read(File.join(output_path, SCRIPT_OUTPUT_FOLDER, k).gsub(/\/+/, '/').strip + '.txt')
        all_imgs = Dir.glob(imgs)
        duration, err = PipelineHelpers.calculate_vid_length(
          all_imgs,
          File.join(output_path, AUDIO_OUTPUT_FOLDER, k).gsub(/\/+/, '/') + '.mp3',
          script, msg % [all_imgs.length - 1, script], prompt, api_tokens 
        )
        raise err unless err.nil?
        backdrop[k] = duration
      end
      outputs['section_durations'] = backdrop
      pstore['outputs'] = outputs
    end
  end

  # Ditto, but for making backdrops:
  #
  # NOTE (Monday, 22nd December, 2025): I've decided that this function will also create the transition scenes too.
  def self.make_backdrops(output_path, pstore_path)
    backdrop_folder = File.join(output_path, BACKDROP_FOLDER).gsub(/\/+/, '/')
    imgs, img_store = File.join(output_path, IMG_OUTPUT_FOLDER).gsub(/\/+/, '/'), {}
    Dir.mkdir(backdrop_folder) unless Dir.exist?(backdrop_folder)

    durations = nil
    PStore.new(pstore_path).transaction do |pstore| 
      durations = pstore['outputs']['section_durations']
    end

    Dir.children(imgs).each do |section|
      indiv_imgs = Dir.children(File.join(imgs, section)).map{|img| File.join(imgs, section, img)}
      img_store[section] = indiv_imgs
    end
    PipelineHelpers.make_backdrops(img_store, durations, backdrop_folder) 
  end

  private_class_method :sum_gen, :image_desc_gen, :image_fetch, :script_gen, :simplify,
  :make_audio, :calculate_duration, :make_backdrops
end 