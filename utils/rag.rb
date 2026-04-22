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
    return if File.exist(db_path)
    
    begin   
      SQLite3::Database.new(db_path) do |db|
        db.load_extension(true)
        SqliteVec.load()
        db.load_extension(false)
        db_table_names.each do |table|
          db.execute <<-COMMAND
            CREATE VIRTUAL TABLE IF NOT EXISTS #{table} USING vec0 (
              embedding float[#{EMBED_SIZE}],
              +content  TEXT
            );
          COMMAND
        end
      end 
    rescue StandardError => e 
      "could not make the database because #{e.message}"
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
  def self.embed_in_db!(content, db_table_name, db_path, api_tokens)
    begin 
      raise 'no content to embed.' if content.empty?
      raise 'no API tokens to work with.' if api_tokens.empty?
      raise "`#{db_path}` does not exist." if !File.exist?(db_path)
      
      SQLite3::Database.open(db_path) do |db|
        db.load_extension(true)
        SqliteVec.load()
        db.load_extension(false)

        content.each do |i|
          res = Gemini.generate_embedding(i['content'], EMBED_SIZE, api_tokens)
          raise res.last if !res.last.nil?
          db.execute("INSERT INTO #{db_table_name}(embedding, content) VALUES (?, ?)",
                    [res[0].pack('f*'), i['key']])
        end 
      end 
    rescue StandardError => e 
      e
    end
  end

  # === RAG-related methods ===

  # Given the content to match, the database path, and the table name to fetch files from,
  # return the 'n' closest matches in the said database table.
  #
  # -- NOTE (Saturday, 11th April, 2026) --
  # This function will expect a dictionary in the case of image searching.
  def self.find_closest_match(item, db_path, db_table_name, api_tokens, n = 1)
    begin 
      raise "`#{db_path}` does not exist" if File.exist?(db_path)
      embedding = err = nil
      if item.is_a?(Enumerable)
        embedding, err = Gemini.generate_embedding(item['content'], EMBED_SIZE, api_tokens)
      else 
        embedding, err = Gemini.generate_embedding(item, EMBED_SIZE, api_tokens)
      end
      raise err if !err.nil?

      SQLite3::Database.open(db_path) do |db|
        db.load_extension(true)
        SqliteVec.load()
        db.load_extension(false)
        
        query_vals, query = nil, nil
        case db_table_name 
        when 'content'
          query = CONTENT_QUERY
          query_vals = [embedding]
        when 'images'
          query = IMAGE_QUERY
          query_vals = [embedding, item.last.end_with?('%') ? item.last : item.last + '%']
        else 
          raise 'unknown table found.'
        end 
        query = "#{query.strip} LIMIT #{n};"
        res = db.execute(query, query_vals)
        [res.map{|x| x[0]}, nil]
      end 
    rescue StandardError => e
      [nil, "couldn't find closest match because #{e}"]
    end
  end 

  TOPIC_MAPPINGS = {'Your Diagnosis': 'topic_1', 'Planned Surgery': 'topic_2',
                    'Risks and Benefits of the Planned Surgery': 'topic_3',
                    'Recovery and Follow-Up': 'topic_4'}
  private 
  EMBED_SIZE = 784
  CONTENT_QUERY = <<-QUERY
    SELECT content, distance 
    FROM content
    WHERE embedding MATCH ? 
    ORDER BY distance
  QUERY
  IMAGE_QUERY = <<-QUERY
    SELECT content, distance 
    FROM images
    WHERE embedding MATCH ? AND content LIKE ?
    ORDER BY distance
  QUERY
end 