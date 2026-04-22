# A module to contain anything and everything that has to do with Gemini's REST API.
# Shame that Gemini doesn't exactly have a Ruby version of its official API, but whatever.
# We'll just make our own.

require 'uri'
require 'net/http'
require 'json'

module Gemini
  # Given a message, a prompt to send over to Gemini, an array of API tokens, and the 
  # number of tries to try fetching responses for, fetch Gemini's response for the said 
  # message and prompt for a total of `num_tries` tries.  
  def self.chat(msg, prompt, api_tokens, num_tries = 5)
    return [nil, 'No API tokens to work with.'] if api_tokens.empty?
    uri = URI.parse(CHAT_URL) 
    post_body = format_chat_input(msg, prompt)

    begin 
      api_tokens.each_index do |i|
        post_header = generate_header(api_tokens[i])
        1.upto(num_tries).each do |j|
          req = Net::HTTP.post(uri, post_body, post_header)
          payload = JSON.parse(req.body)
          if req.is_a?(Net::HTTPSuccess)
            msg = payload.dig('candidates', 0, 'content', 'parts', 0, 'text')
            return [msg, nil]
          end 

          case payload.dig('error', 'code').to_i
          when 429
            puts "Token ##{i + 1} exhausted - trying the next one" if i < api_tokens.length - 1
            break 
          when 503
            return [nil, 'Gemini is too busy now - try again later.'] if j == num_tries
            puts "Error 503 reached; backing off before trying again (attempt ##{j} out of #{num_tries})..."
            sleep(BASE_DELAY**j + (rand * BASE_DELAY))
            next 
          else 
            return [nil, "Unexpected error from Gemini - #{payload.dig('error', 'message')}"]
          end 
        end 
      end
      [nil, 'All tokens have been exhausted.']
    rescue JSON::ParserError => e
      [nil, "Could not parse JSON payload because #{e.message}"]
    rescue StandardError => e 
      [nil, "Could not fetch Gemini's response because #{e.message}"]
    end 
  end 

  # Generates content embeddings using Gemini's `gemini-embedding-2-preview` model;
  # this function also returns the embedding in an (embedding, error) format that
  # Gemini.chat() does too.
  #
  # Note that the embedding size is to be referenced from Gemini's documentation.
  # As per their words - it's recommended to pick a vector size of 768, 1536, or 
  # 3072.
  def self.generate_embedding(content, vector_size, api_keys, num_tries = 5)
    return [nil, 'No API keys to work with.'] if api_tokens.empty?
    uri = URI.parse(EMBED_URL)
    embed_body = {'content': {'parts': [{'text': content}]}, 'taskType': EMBED_TYPE, 
                  'output_dimensionality': vector_size}.to_json

    begin 
      api_keys.each_index do |i|
        post_header = generate_header(api_keys[i])
        1.upto(num_tries + 1).each do |j| 
          return [nil, 'Gemini is too busy now - try again later.'] if j > num_tries
          req = Net::HTTP.post(uri, embed_body, post_header)
          res = JSON.parse(req.body)
          return [res.dig('embedding', 'values'), nil] if req.is_a?(Net::HTTPSuccess)

          case res.dig('error', 'code').to_i 
          when 429
            puts "Token ##{i + 1} is exhausted; switching to the next one..." if i < api_keys.length - 1
            break
          when 503
            return [nil, "Gemini's currently swamped.  Try again later."] if j == num_tries
            puts "Error 503 encountered; backing off now (attempt ##{j} out of #{num_tries})..."
            sleep(BASE_DELAY**j + (rand * BASE_DELAY))
          else 
            return [nil, "could not fetch embeddings from Gemini's API because #{res.dig('error', 'message')}"]
          end 
        end 
      end 
      [nil, 'All tokens have been exhausted.']
    rescue JSON::ParserError => e 
      return [nil, "could not parse the incoming JSON payload because #{e.message}"]
    rescue StandardError => e 
      return [nil, "could not fetch embeddings because #{e.message}"]
    end 
  end

  private 
  EMBED_URL = 'https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-2-preview:embedContent'
  EMBED_TYPE = 'RETRIEVAL_DOCUMENT'
  CHAT_URL = 'https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent'
  BASE_DELAY = 2

  # Formats all incoming messages in the way Gemini's API expects.
  private_class_method def self.format_chat_input(msg, prompt = '') 
    to_return = {'contents': {'parts': [{'text': msg}]}}
    to_return.update({'system_instruction': {'parts': [{'text': prompt}]}}) if !prompt.strip.empty? || !prompt.nil?
    to_return.to_json
  end 

  # Generates the request header to be sent to Google's Gemini text generation 
  # API - the only thing that's going to change is the 'x-goog-api-key' field.
  private_class_method def self.generate_header(api_key)
    {'Content-Type': 'application/json', 'x-goog-api-key': api_key}
  end 
end 