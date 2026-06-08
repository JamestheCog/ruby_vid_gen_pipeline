require 'ratatui_ruby'

require_relative 'processes/setup'
require_relative 'processes/rag'
require_relative 'processes/pipeline'

# Ratatui components:
require_relative 'ratatui/home'
require_relative 'ratatui/controls'
require_relative 'ratatui/system_vars'
require_relative 'ratatui/rag_config'
require_relative 'ratatui/pipeline'

class MainApp
  include Setup
  include HomeComponents
  include Controls 
  include SystemComponents
  include RAGComponents
  include PipelineComponents

  def initialize
    init_system_db!

    @should_quit = false
    @chosen_index = 0
    @items = ['Home', 'System Variables', 'Sources', 'Pipeline']

    initialize_system_components
    initialize_rag_components
    initialize_pipeline_components
  end

  def run
    RatatuiRuby.run do |tui|
      loop do
        event = tui.poll_event(timeout: 0.1) 
        system_handled = @system_editing ? handle_system_form_event(event) : false
        rag_handled = @rag_editing ? handle_rag_form_event(event) : false
        pipeline_handled = @pipeline_editing ? handle_pipeline_form_event(event) : false
        
        unless system_handled || rag_handled || pipeline_handled
          case event
          in { type: :key, code: code } if %w[q Q].include?(code)
            break
          in {type: :key, code: 'enter'}
            case @chosen_index
            when 1
              @system_editing = true 
            when 2 
              next unless @rag_setup_error.nil?
              @rag_editing = true 
            when 3 
              next unless @pipeline_setup_error.nil?
              @pipeline_editing = true
            end
          in { type: :key, code: c } if %w{down tab}.include?(c.to_s.downcase)
            @chosen_index = (@chosen_index + 1) % @items.length
          in { type: :key, code: c } if c.to_s.downcase == 'up'
            @chosen_index = (@chosen_index - 1) % @items.length
          else
          end
        end

        tui.draw do |frame|
          render(frame, tui) 
        end
      end
    end
  end

  private
  def render(frame, tui)
    main_area, controls = tui.layout_split(
      frame.area, 
      direction: :vertical, 
      constraints: [tui.constraint_min(0), tui.constraint_length(5)]
    )
    sidebar_area, content_area = tui.layout_split(
      main_area,
      direction: :horizontal,
      constraints: [
        tui.constraint_length(20),
        tui.constraint_min(0)
      ]
    )
    controls(frame, tui, controls)

    # === Sidebar area ===
    #
    # We'll build the sidebar in this part of the application's code.
    list_items = @items.map.with_index do |item, i|
      style = i == @chosen_index ? tui.style(fg: "yellow", bg: "blue") : tui.style
      tui.list_item(content: "#{item}\n", style: style)
    end
    sidebar = tui.list(
      items: list_items,
      block: tui.block(title: " Menu ", borders: [:all], padding: 1),
    )
    frame.render_widget(sidebar, sidebar_area)

    # Renders the components in our application - note the following
    # and the number's meaning:
    #
    # 0: Home page (i.e., that display message)
    # 1. The system configuration 
    # 2. The configuration for the RAG system
    # 3. Running the actual pipeline.
    case @chosen_index
    when 0
      render_home(frame, tui, content_area)
    when 1
      if @system_editing
        render_system_form(frame, tui, content_area)
      else 
        frame.render_widget(
          tui.paragraph(
            text: "\n\n\n\n\nSystem Variables Form\n\nPress 'Enter' to begin editing",
            alignment: :center,
            block: tui.block(title: " System DB Editing ", borders: [:all], padding: 6),
            style: tui.style(modifiers: [:bold], fg: :gray)
          ),
          content_area
        )
      end 
    when 2
      sys_vars, err = Setup::fetch_sys_vars
      sys_vars = sys_vars.slice('rag_db', 'image_prompt_path', 'content_path', 'api_token_path')
      if err.nil?
        sys_vars.each do |k, v|
          err = "Key `#{k}` has no value" if v.strip.empty?
          break unless err.nil?
        end
        err = "expecting four variables in system DB; only had #{sys_vars.size}." if sys_vars.size != RAG_EXP_AMTS
      end
      @rag_setup_error = err
      @rag_components = sys_vars if !@rag_editing
      
      if @rag_editing && @rag_setup_error.nil?
        render_rag_form(frame, tui, content_area)
      else
        msg = err.nil? ? "Press 'Enter' to begin editing" : "Cannot edit database because #{err}"
        frame.render_widget(
          tui.paragraph(
            text: "\n\n\n\n\nRAG DB Setup\n\n" + msg,
            alignment: :center,
            block: tui.block(title: " RAG DB Editing ", borders: :all, padding: 6),
            style: tui.style(modifiers: [:bold], fg: err.nil? ? :gray : :red)
          ),
          content_area
        )
      end 
    when 3
      unless @pipeline_setup_error.nil? && !@pipeline_components.nil?
        err = RAGProcesses::validate_rag_db
        sys_vars, err = Setup::fetch_sys_vars
        sys_vars = sys_vars.slice('rag_db', 'image_prompt_path', 'content_path', 'api_token_path')
        if err.nil?
          sys_vars.each do |k, v|
            err = "Key `#{k}` has no value" if v.strip.empty?
            break unless err.nil?
          end
        end
        @pipeline_setup_error = err
        @pipeline_components = sys_vars if !@pipeline_editing
      end
      
      if @pipeline_editing && @pipeline_setup_error.nil?
        render_pipeline_form(frame, tui, content_area)
      else
        msg = err.nil? ? "Press 'Enter' to begin running the pipeline" : "Cannot run pipeline yet because #{err}"
        frame.render_widget(
          tui.paragraph(
            text: "\n\n\n\n\nPipeline\n\n" + msg,
            alignment: :center,
            block: tui.block(title: " Pipeline Execution ", borders: :all, padding: 6),
            style: tui.style(modifiers: [:bold], fg: err.nil? ? :gray : :red)
          ),
          content_area
        )
      end 
    end 
  end

  private 
  RAG_EXP_AMTS = 4
end

MainApp.new.run