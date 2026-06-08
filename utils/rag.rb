# A module to contain helper functions that have to do with ChromaDB

require 'sqlite3'
require 'sqlite_vec'

require_relative 'gemini'
require_relative '../processes/setup'

module RAG
  # A helper function - that - given a database path and a table name, initializes
  # a new SQLite vector database with the HEREDOC string in the method body.
  #
  # Caution: this function will overwrite old databases if `db_path` already exists!
  def self.init_db!(db_path = Setup::RAG_DB_FILEPATH, db_table_names = Setup::RAG_DB_TABLES)    
    begin   
      SQLite3::Database.new(db_path) do |db|
        db.enable_load_extension(true)
        SqliteVec.load(db)
        db.enable_load_extension(false)

        db_table_names.each do |table|
          db.execute <<-COMMAND
            CREATE VIRTUAL TABLE IF NOT EXISTS #{table} USING vec0 (
              embedding float[#{EMBED_SIZE}],
              +content  TEXT
            );
          COMMAND
        end
      end 
      nil
    rescue StandardError => e 
      e
    end
  end 

  # Given an array containing strings (i.e., the content to be embedded), the path 
  # to the database, and the database's table name, use Gemini.generate_embedding
  # to insert the embedding into the database.
  #
  # This function will return a nil on successful embedding and insertion into 
  # db_path (under db_table_name).  Otherwise, a string will be returned.
  #
  # -- NOTE (Saturday, 11th April, 2026) --
  # This function will now expect `contents` to be an array of dictionaries - with each 
  # dictionary having two separate keys:
  #      
  # 1) `key`     -> the content to be returned during distance calculation
  # 2) `content` -> the content to be embedded.
  def self.embed_in_db!(contents, db_table_name, db_path, api_tokens)
    begin 
      raise 'no content to embed.' if contents.empty?
      raise 'no API tokens to work with.' if api_tokens.empty?
      raise "`#{db_path}` does not exist." if !File.exist?(db_path)
      
      SQLite3::Database.open(db_path) do |db|
        db.enable_load_extension(true)
        SqliteVec.load(db)
        db.enable_load_extension(false)
        
        db.transaction do
          contents.each do |i|
            embedding, err = Gemini.generate_embedding(i[:content], EMBED_SIZE, api_tokens) 
            raise err unless err.nil?
            db.execute("INSERT INTO #{db_table_name}(embedding, content) VALUES (?, ?)",
                      [embedding.pack('f*'), i[:key]])
          end
        end 
      end 
      nil
    rescue StandardError => e 
      e
    end
  end

  # === RAG-related methods ===

  # Given the content to match, the database path, and the table name to fetch files from,
  # return the 'n' closest matches in the said database table.
  #
  # NOTE (Saturday, 11th April, 2026) --
  # This function will expect a dictionary in the case of image searching.
  #
  # NOTE (Monday, 4th May, 2026) --
  # I've decided that this method's gonna return a list for the results if all goes according to plan.  
  def self.find_closest_match(item, db_path, db_table_name, api_tokens, n = 1)
    begin 
      raise "`#{db_path}` does not exist" unless File.exist?(db_path)
      embedding = err = nil
      if item.is_a?(Hash)
        embedding, err = Gemini.generate_embedding(item[:desc], EMBED_SIZE, api_tokens)
      else 
        embedding, err = Gemini.generate_embedding(item, EMBED_SIZE, api_tokens)
      end
      raise err unless err.nil?
      embedding = embedding.pack('f*')

      SQLite3::Database.open(db_path) do |db|
        db.enable_load_extension(true)
        SqliteVec.load(db)
        db.enable_load_extension(false)
        
        query_vals, query = nil, nil
        case db_table_name 
        when 'content'
          query, query_vals = CONTENT_QUERY, [embedding, n]
        when 'images'
          query, query_vals = IMAGE_QUERY, [embedding, n * CANDIDATE_BUFFER]
        else 
          raise 'unknown table found.'
        end 
        res = db.execute(query.strip, query_vals)
        res = db_table_name == 'images' ? res.filter{|x| x.first.start_with?(item[:topic_mapping])} : res
        to_return = [res.map{|x| x[0]}.first(n), nil]
        db_table_name == 'images' ? to_return : to_return.flatten
      end 
    rescue StandardError => e
      [nil, e]
    end
  end 

  TOPIC_MAPPINGS = {'your_diagnosis': 'topic_1', 'planned_surgery': 'topic_2',
                    'risks_and_benefits': 'topic_3',
                    'recovery': 'topic_4'}
  private 
  CANDIDATE_BUFFER = 20
  EMBED_SIZE = 784
  MAX_SEARCH_SIZE = 4096
  CONTENT_QUERY = <<-SQL
    SELECT content 
    FROM content 
    WHERE embedding MATCH ? and k = ?
  SQL
  IMAGE_QUERY = <<-SQL
    SELECT content 
    FROM images 
    WHERE embedding MATCH ? AND k = ?
  SQL
end 