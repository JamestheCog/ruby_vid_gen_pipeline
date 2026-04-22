# A module to contain parts of the pipeline - essentially a Rubified version of the original pipeline.  It's now been modularized
# and refactored to have Go-style error handling.
#
# NOTE (Wednesday, 15th April, 2026): we'll essentially be 

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
    begin
      # Step 0.25 -> Load in the system variables, the prompts, and the 
      #              messages.
      raise 'RAG DB not initialized' if !File.exist?(sys_vars['rag_db'])
      sys_vars, err = Setup.fetch_sys_vars; raise err if !err.nil?
      prompts, err = Setup.fetch_files(sys_vars['prompt_folder_path']); raise err if !err.nil?
      msgs, err = Setup.fetch_files(sys_vars['message_folder_path']); raise err if !err.nil?
      api_tokens, err = Reader.api_tokens(sys_vars['api_token_path']); raise err if !err.nil?
      
      # Step 0.5 -> Create the directory and the PStore database to track
      #             state:
      Dir.mkdir(sys_vars['outputs_path']) if !Dir.exist?(sys_vars['outputs_path'])
      output_path = File.join(sys_vars['outputs_path'], user_output).gsub(/\/+/, '/')
      state_path = File.join(output_path, Setup::SETUP_DB_NAME).gsub(/\/+/, '/')
      err = Setup.init_state_db(state_path); raise err unless err.nil?

      # Step 0.75 -> Update the main state dictionary for the system to keep track of 
      #              this specific user_output file:
      system_state_db = PStore.new(sys_vars['state_db_path'])
      system_state_db.transaction do |state|
        state['user_states'] ||= []
        state['user_states'] << state_path 
      end
      
      # Step 1 -> Read in the clinical note.
      clin_note, err = Reader.text_file(clin_note_path); raise err unless err.nil?

      # Step 2 and onwards -> creating the video's components to be uploaded 
      # onto shotstack afterwards:
      state = PStore.new(state_path)
      Setup::PIPELINE_PHASES.each do |phase|
        state.transaction do |pstore|
          next if pstore['checkpoints'][phase]
          pstore['outputs'] ||= {}
          msg, prompt = nil, nil

          case phase
          when 'sum_gen' 
            msg, prompt = msgs['sum_gen'], prompts['sum_gen']
            res, err = Gemini.chat(msg % clin_note, prompt, api_tokens)
            raise "Cannot generate summary because #{err}" unless err.nil?
            pstore['outputs']['sum_gen'] = res
          when 'image_descs'
            msg, prompt = msgs['image_desc'], prompts['image_desc']
            pstore['outputs']['image_desc'] = temp = {}
            pstore['outputs']['sum_gen'].split('\n').map(&:strip).each do |i|
              part, summary = i.split(SUMMARY_SEP).map(&:strip)
              temp[part], msg = summary, msg % [num_imgs[i], summary]
              resp, err = Gemini.chat(msg, summary, api_tokens)
              raise "Error generating image descriptions from summaries because #{err}" unless err.nil?
              pstore['outputs']['image_desc'][part] = resp.split('\n').map(&:strip)
            end
            pstore['outputs']['sum_gen'] = temp
          when 'image_fetch'
            img_folder = File.join(output_path, IMG_OUTPUT_FOLDER).replace(/\/+/, '/')
            Dir.mkdir(img_folder) if !File.exist(img_folder)
            pstore.dig('outputs', 'image_desc').each do |k, v|
              sec_imgs = File.join(img_folder, k); Dir.mkdir(sec_imgs) if !File.exist(sec_imgs)
              v.each_index do |i|
                search_params = {'desc': v[i], 'topic_mapping': RAG::TOPIC_MAPPINGS[k]}
                img, err = RAG.find_closest_match(search_params, RAG_DB_FILEPATH, Setup::RAG_DB_TABLES[0])
                raise err unless err.nil?
                FileUtils.cp(File.join(sys_vars['images_path'], img).gsub(/\/+/, '/'), 
                            File.join(sec_imgs, "#{i + 1}_#{img}.txt"))
              end
            end
          when 'script_gen'
            msg, prompt = msgs['script_gen'], prompts['script_gen']
            pstore['outputs']['script_gen'] = {}

            pstore['outputs']['sum_gen'].each do |k, v|
              msg = msgs['script_gen'] % [v, pstore['outputs']['image_desc'][k]]
              resp, err = Gemini.chat(msg, prompt, api_tokens)
              raise "Cannot generate script because #{err}" unless err.nil?
              pstore['outputs']['script_gen'][k] = resp
            end
          when 'simplify'
            script_output_path = File.join(output_path, SCRIPT_OUTPUT_FOLDER)
            Dir.mkdir(script_output_path) if !File.exist(script_output_path)
            msg, prompt, pstore['outputs']['simplify'] = msgs['simplify'], prompts['simplify'], {}
            scripts = pstore.dig('outputs', 'script_gen')

            TOPIC_ORDER.each_index do |i|
              prior = TOPIC_ORDER[0, i].empty? ? '', TOPIC_ORDER[0, i].map{|x| scripts[TOPIC_ORDER[x]]}.join('\n\n')
              msg = msg % [prior, pstore.dig('outputs', 'script_gen', TOPIC_ORDER[i])]
              resp, err = Gemini.chat(msg, prompt, api_tokens)
              raise "Cannot simplify script because #{err}" unless err.nil?
              pstore['outputs']['simplify'][TOPIC_ORDER[i]] = resp
              File.Write(Flie.join(script_output_path, TOPIC_ORDER[i] + '.txt'), resp)
            end 
          when 'audio'
            audio_output_path = File.join(output_path, AUDIO_OUTPUT_FOLDER).gsub(/\/+/, '/')
            pstore.dig('outputs', 'simplify').each do |k, v|
              audio = RbEdgeTTS::Communicate.new(v)
              audio.save(File.join(audio_output_path, k + '.mp3'))
            end
          when 'duration_calc'
            msg, prompt = msgs['script_splitting'], prompts['script_splitting']
            backdrop = {}

            pstore.dig('outputs', 'simplify').each_key do |k|
              imgs = File.join(output_path, IMG_OUTPUT_FOLDER, k).gsub(/\/+/, '/')
              script = File.read(Dir.glob(File.join(output_path, SCRIPT_OUTPUT_FOLDER, k).gsub(/\/+/, '/')).first)
              num_imgs = Dir.glob("#{imgs}/*")

              duration, err = PipelineHelpers.calculate_vid_length(
                File.join(output_path, IMG_OUTPUT_FOLDER, k).gsub(/\/+/, '/'),
                Dir.glob(File.join(output_path, AUDIO_OUTPUT_FOLDER, k).gsub(/\/+/, '/')).first,
                script, msg % [num_imgs - 1, script], prompt, api_tokens 
              )
              raise err unless err.nil?
              backdrop[k] = duration
            end 
            pstore['outputs']['section_durations'] = backdrop
          when 'backdrop'
            backdrop_folder = File.join(output_path, BACKDROP_FOLDER).gsub(/\/+/, '/')
            Dir.mkdir(backdrop_folder) if !File.exist(backdrop_folder)

            imgs, img_store = File.join(output_path, IMG_OUTPUT_FOLDER).replace(/\/+/, '/'), {}
            Dir.glob("#{imgs}/*").each do |k| 
              img_paths = Dir.children(File.join(imgs, k)).map{|img| File.join(imgs, k, img)}
              img_store[k] = img_paths
            end
            PipelineHelpers.make_backdrops(img_store, pstore.dig('outputs', 'section_durations'),
                                          backdrop_folder)
          else 
            raise "Unknown phase `#{phase}` found."
          end
        end
        pstore['checkpoints'][phase] = true 
      end
    rescue StandardError => e
      e.message
    end
  end

  # To be run post-SadTalker: for final video assembly with the talking avatar in the bottom left 
  # corner of the screen:
  def self.assemble_videos(backdrop_folder, avatar_folder)
    Dir.children(backdrop_folder).each do |clip|
      clip_name = clip.split('.').first.strip
      backdrop, avatar = File.join(backdrop_folder, clip), File.join(avatar_folder, clip)
      PipelineHelpers.overlay_avatar(backdrop, avatar, "int_#{clip_name}_1_stitched.mp4")
      PipelineHelpers.make_transition(clip_name, "int_#{clip_name}_2_transition.mp4")
    end

    int_files = Dir.glob("#{output_path}/int_*.mp4")
    final_name = user_output.downcase.strip.gsub(/\s+/, '_')
    PipelineHelpers.stitch_videos(int_files, "final_result_#{final_name}.mp4")
  end
  # --- Private variables and / or functions ---
  private   
  SUMMARY_SEP = '<sep>'
  SCRIPT_OUTPUT_FOLDER = 'scripts'
  IMG_OUTPUT_FOLDER = 'img'
  AUDIO_OUTPUT_FOLDER = 'audio'
  BACKDROP_FOLDER = 'backdrops'
  TOPIC_ORDER = ['Your Diagnosis', 'Planned Surgery', 
                  'Risks and Benefits of the Planned Surgery', 
                  'Recovery and Follow-Up']
end 