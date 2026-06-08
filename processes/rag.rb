# A file to contain processes that have to do with the RAG component of the Ratatui application we're building - mostly 
# validation checks for now.
#
# -- Kevin

require 'sqlite3'
require_relative 'setup'

module RAGProcesses
  def self.validate_rag_db(db_path = Setup::RAG_DB_FILEPATH)
    return "`#{db_path}` doesn't exist." if !File.exist?(db_path)

    begin
      SQLite3::Database.open(db_path) do |db|
        tables = db.execute(TABLE_NAME_QUERY)
        return "#{db_path} has no tables." if tables.empty?
      end
    rescue StandardError => e
      e
    end
  end

  private
  TABLE_NAME_QUERY = "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';"
  SPECIFIC_TABLE = "SELECT COUNT(*) FROM %s;"
end