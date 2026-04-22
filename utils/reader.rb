require 'csv'
require 'docx'

module Reader
  def self.image_descs(desc_path)
    begin
      to_return = []
      CSV.foreach(desc_path, headers: true) do |row|
        to_return << {'key': row['image_name'], 'content': row['prompt']}
      end
      [to_return, nil]
    rescue StandardError => e
      [nil, e.message]
    end
  end

  def self.sources(source_path)
    begin 
      to_return = []
      path = source_path.end_with?('/') ? "#{source_path}/" : source_path
      Dir.glob("#{path}*").each do |x|
        content = text(x)
        to_return << {'key': x, 'content': content}
      end 
      [to_return, nil]
    rescue StandardError => e 
      [nil, e.message]
    end
  end
  
  def self.api_tokens(api_token_path)
    begin
      tokens, err = text(api_token_path)
      raise err unless err.nil?
      tokens = tokens.split('\n').map(&strip).select{|x| x.length > 0}
      [tokens, nil]
    rescue StandardError => e 
      [nil, e.message]
    end
  end

  # The daddy of all functions above - reads in the file directly as a long-ass string 
  # before the above helper functions do the downstream processing.
  def self.text(item_path)
    begin
      extension = item_path[item_path.rindex('.'), item_path.length]
      content = case extension
                when '.docx'
                  Docx::Document.open(item_path).text
                when '.txt'
                  File.read(item_path)
                else
                  raise 'unknown extension for `item_path`; please check file.'
                end
      [content, nil]
    rescue StandardError => e 
      [nil, e.message]
    end
  end
end