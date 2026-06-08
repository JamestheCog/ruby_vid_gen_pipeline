require 'sqlite3'
require 'pstore'
require_relative '../utils/RAG'
require_relative '../utils/reader'

module Setup
  # Given a file path, initialize the database that we're gonna be basing downstream processes off of 
  # (i.e., their values').  This function will return a nil on successful creation - otherwise, 
  # it's going to raise a string if it can't do its job for whatever reason
  #
  # This method need only be called once during the application's runtime - before anything else is 
  # done - and all will be well!
  def init_system_db!(file_path = SYSTEM_DB_FILEPATH)
    return if File.exist?(file_path)
    begin 
      SQLite3::Database.new(file_path) do |db|
        db.execute(CREATE_TABLE)
        VARS_TO_INSERT.each{|k, v| db.execute(INSERT, [k.to_s, v])}
      end 
      nil
    rescue StandardError => e 
      "could not initialize system database because #{e}"
    end
  end

  # Given a file path, initialize the RAG store for the sources used for script generation and 
  # image matching.  Note the following inputs:
  #
  # 1) system_vars --> a Hash containing the variables in db/system.db
  # 2) api_tokens  --> an Array of Gemini-approved API tokens
  # 3) file_path   --> a String 
  def self.init_rag_db!(system_vars, api_tokens, file_path = RAG_DB_FILEPATH)
    begin 
      err = RAG.init_db!(file_path, RAG_DB_TABLES); raise err unless err.nil?
      RAG_DB_TABLES.each do |table|
        fetched_items = case table 
                        when 'images' then Reader.image_descs(system_vars['image_prompt_path'])
                        when 'content' then Reader.sources(system_vars['content_path'])
                        else raise "unknown table type found: #{table}."
                        end
        raise fetched_items.last.to_s unless fetched_items.last.nil?
        err = RAG.embed_in_db!(fetched_items.first, table, RAG_DB_FILEPATH, api_tokens)
        raise err unless err.nil?
      end 
      nil
    rescue StandardError => e 
      "RAG DB init. failed: #{e}"
    end
  end

  # Given a file path, and a name that we want all outputs for a clinical note to be under the outputs
  # folder, create a NoSQL database to keep track of pipeline state.
  def self.init_state_db!(file_path)
    return if File.exist?(file_path)
    begin 
      store = PStore.new(file_path)
      store.transaction do
        store['checkpoints'] = PIPELINE_PHASES.zip(Array.new(PIPELINE_PHASES.length, false)).to_h
      end 
      nil
    rescue StandardError => e 
      "Could not initialize pipeline state db because #{e.message}"
    end
  end

  
  # --- Related to the state DB ---
  #
  # Given a dictionary, save the values into the database:
  def self.save_state_vals(values, db_path = SYSTEM_DB_FILEPATH)
    begin
      SQLite3::Database.open(db_path) do |db|
        values.each{|k, v| db.execute(UPDATE, [v, k])}
      end
      nil
    rescue StandardError => e 
      "Could not save values because: #{e.message}"
    end
  end

  # Given the file path to the system database, the keys and the values in a hash so that we can 
  # pass it to downstream processes:
  def self.fetch_sys_vars(system_db_path = SYSTEM_DB_FILEPATH)
    begin 
      raise "file path `#{system_db_path}` does not exist." if !File.exist?(system_db_path)
      to_return = {}
      SQLite3::Database.open(system_db_path) do |db|
        db.execute "SELECT variable, value FROM variables;" do |i|
          next if to_return.has_key?(i[0])
          to_return[i[0]] = i[1]
        end 
      end
      [to_return, nil]
    rescue StandardError => e
      [nil, e]
    end
  end

  # Given a folder path, return the items inside in the form of a Hash - where each key 
  # is the item's name (minus their extension) and the corresponding value the file's 
  # value:
  def self.fetch_files(file_path)
    begin
      path, to_return = file_path.end_with?('/') ? file_path : "#{file_path}/", {}
      Dir.glob("#{path}*").each do |i|
        txt, err = Reader.text(i); raise err unless err.nil?
        key = i.split('/').last
        to_return[key[0, key.rindex('.')]] = txt
      end 
      [to_return, nil]
    rescue StandardError => e 
      [nil, e]
    end
  end  


  # The different states of our dictionary - also meant to be exportable to the Pipeline module 
  # in this same directory (i.e., defines a hard order for our pipeline to follow):
  PIPELINE_PHASES = ['sum_gen', 'image_descs', 'image_fetch', 'script_gen', 'simplify', 'audio',
                    'duration_calc', 'backdrop']
  SETUP_DB_NAME = 'state.pstore'
  
  VARS_TO_INSERT = {'rag_db': 'db/rag.db', 
                    'state_db_path': 'db/state.pstore',
                    'api_token_path': '', 
                    'images_path': 'resources/images',
                    'prompt_folder_path': 'resources/prompts',
                    'message_folder_path': 'resources/messages',
                    'image_prompt_path': 'resources/image_prompts.csv',
                    'content_path': 'resources/med_sources',
                    'outputs_path': 'output'}
  EXPLANATIONS = {'rag_db': 'The path to the database containing embedded documents.',
                  'state_db_path': "The path to the system's state database.",
                  'api_token_path': 'The path to a text file containing Gemini API tokens (one token per line).',
                  'images_path': 'The path of interest to the base images',
                  'prompt_folder_path': 'The path to the folder containing behavior-defining prompts to be used on Gemini.',
                  'message_folder_path': "The path to the folder containing message templates to be used with the pipeline's assistants.",
                  'image_prompt_path': 'The path to the folder containing the images used during content creation.',
                  'content_path': 'The path to the medical sources used for RAG.',
                  'outputs_path': 'The folder that you want all outputs to appear in.'}
  RAG_DB_FILEPATH = 'db/rag.db'
  RAG_DB_TABLES = ['images', 'content']
  SYSTEM_DB_FILEPATH = 'db/system.db'

  private
  CREATE_TABLE = <<-STATEMENT
    CREATE TABLE variables (
      variable TEXT,
      value    TEXT
    );
  STATEMENT
  SELECT_VARS = <<-STATEMENT
    SELECT * FROM variables;
  STATEMENT
  INSERT = <<-STATEMENT
    INSERT INTO variables VALUES (?, ?);
  STATEMENT
  UPDATE = <<-UPDATE
    UPDATE variables SET value = ? WHERE variable = ?; 
  UPDATE
end 