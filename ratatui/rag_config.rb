require 'ratatui_ruby'
require 'fileutils'

require_relative '../processes/setup'

module RAGComponents
  def initialize_rag_components()
    @rag_components = nil
    @rag_focused = 0
    @rag_editing = false
    @rag_setup_error = nil
    @rag_process_error = nil
    @rag_process_error_msg = ''
    @rag_process_running = false
    @rag_process_success = false
    @rag_frame_count = 0
  end

  def handle_rag_form_event(event)
    return false unless @rag_editing

    case event 
    in {type: :key, code: 'enter'}
      return true if @rag_process_running
      @rag_process_success = false
      @rag_process_error = nil 
      @rag_process_running = true
      @rag_frame_count = 0

      begin
        case @rag_focused
        when 0
          api_tokens = File.read(@rag_components['api_token_path']).split('\n').map(&:strip)
          err = Setup.init_rag_db!(@rag_components, api_tokens)
          @rag_process_error = err unless err.nil?
        when 1
          raise "DB doesn't currently exist." if !File.exist?(@rag_components['api_token_path'])
          FileUtils.rm_rf(Setup::RAG_DB_FILEPATH)
        else  
          raise 'unknown index found.'
        end
        @rag_process_success = true
      rescue StandardError => e 
        @rag_process_error_msg = e.message
        @rag_process_error = true
        @rag_process_success = false
      ensure 
        @rag_process_running = false
      end 
      true
    in {type: :key, code: 'esc'}
      @rag_editing = false 
      @rag_process_error = nil 
      @rag_process_running = false 
      @rag_process_success = false
      true 
    in {type: :key, code: c} if %w{up down}.include?(c.to_s.downcase) 
      if c.to_s.downcase == 'down'
        @rag_focused = (@rag_focused + 1) % NUM_RAG_OPTIONS
      else 
        @rag_focused = (@rag_focused - 1) % NUM_RAG_OPTIONS
      end 
      true 
    else 
      false
    end
  end

  def render_rag_form(frame, tui, area)
    fields_area, status_area = tui.layout_split(
      area, direction: :vertical,
      constraints: [
        tui.constraint_min(0),
        tui.constraint_length(5)
      ]
    )

    # --- Render the state variables --- 
    current_state = ['Current variables of interest: '] + @rag_components.map do |k, v| 
      ['', tui.text(:span, content: "#{k}: #{v}", style: tui.style(fg: :dark_gray))]
    end
    # --- END ---

    # --- Render the Form's options -- 
    options = ['Initialize database', 'Clear database'].map.with_index do |label, i|
      cursor = (i == @rag_focused && @rag_editing) ? "→ " : "  "
      style = (i == @rag_focused) ? tui.style(fg: :white, bg: :light_blue) : tui.style(fg: :dark_gray)
      ['', tui.text(:span, content: "#{cursor}  #{label}".strip, style: style)]
    end 
    
    frame.render_widget(
      tui.paragraph(
        text: [
          tui.text(:span, 
            content: 'Initialize RAG Database', style: tui.style(fg: :green, modifiers: [:bold])
          ), '', 
          "A pane to initialize the RAG system to be used during the pipeline's content creation phase.  " + 
          "", '', current_state, '', 'Actions:',
          options
        ].flatten, 
        alignment: :left, wrap: true,
        block: tui.block(borders: :all, padding: 1, title: ' Edit RAG Database ')
      ), 
      fields_area
    )
    # --- END ---

    # --- Render the status area ---
    # content, style = nil, nil
    if @rag_process_running
      @rag_frame_count += 1
      content = "Running process now"
      content += '.' * ((@rag_frame_count % NUM_DOTS) + 1)
      style = tui.style(fg: :yellow)
    elsif @rag_process_error
      content = "An error happened with the process: #{@rag_process_error_msg}"
      style = tui.style(fg: :red)
    elsif @rag_process_success
      content = 'Process successful!'
      style = tui.style(fg: :green)
    else
      content, style = '', nil
    end

    frame.render_widget(tui.paragraph(
        text: tui.text(:span, content: content, style: style),
        alignment: :left, wrap: true, 
        block: tui.block(title: ' Status ', borders: :all, padding: 1)
      ), status_area)
    # --- END ---
    
  end

  def open_rag_form
    @rag_editing = true 
  end

  private 
  NUM_RAG_OPTIONS = 2
  NUM_DOTS = 3
end