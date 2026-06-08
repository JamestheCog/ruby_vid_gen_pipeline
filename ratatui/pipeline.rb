require 'ratatui_ruby'
require 'fileutils'

require_relative '../processes/setup'
require_relative '../processes/pipeline'

module PipelineComponents
  def initialize_pipeline_components()
    @pipeline_components = nil
    @pipeline_focused = 0
    @pipeline_editing = false
    @pipeline_setup_error = nil
    @pipeline_process_error = nil
    @pipeline_process_error_msg = ''
    @pipeline_process_running = false
    @pipeline_process_success = false
    @pipeline_frame_count = 0
    @pipeline_img_counts = {'your_diagnosis': '', 'planned_surgery': '', 'risks_and_benefits': '', 'recovery': ''}
    @pipeline_inputs = {'clinical_note': '', 'avatar_videos': ''}
  end

  def handle_pipeline_form_event(event)
    return false unless @pipeline_editing

    case event
    in {type: :key, code: 'enter'}
      return true if @pipeline_process_running
      @pipeline_process_success = false
      @pipeline_process_error = nil
      @pipeline_process_running = true
      @pipeline_frame_count = 0

      # Note: indices '4' and '5' refer to the first and final stages of the pipeline.
      Thread.new do
        begin
          case @pipeline_focused
          when 0...4 
            raise "Navigate to the bottom to run the pipeline!"
          when 4
            @pipeline_img_counts.each{|k, v| raise "#{k} must be non-zero." if v.to_i.zero?} 
            sys_vars, err = Setup::fetch_sys_vars
            raise "Cannot fetch sys_vars because #{err}" unless err.nil?
            raise "Clinical note doesn't exist." if !File.exist?(@pipeline_inputs[:clinical_note])

            output = @pipeline_inputs[:clinical_note].downcase.strip.gsub(/\s+/, '_').gsub(/[^0-9a-zA-Z._-]/, '')
            @pipeline_img_counts.each_pair{|k, v| @pipeline_img_counts[k] = v.to_i}
            err = Pipeline::create_components(@pipeline_inputs[:clinical_note], @pipeline_img_counts, output)
            raise "Err from pip: #{err}" unless err.nil?
          when 5
            backdrop_folder = Dir.glob('output/*/backdrops'); raise "Cannot find backdrops" if backdrop_folder.empty?
            backdrop_folder = backdrop_folder.first
            err = Pipeline::assemble_videos(backdrop_folder, @pipeline_inputs['avatar_videos'])
            raise err unless err.nil?
          else
            raise "Unknown index #{@pipeline_focused}."
          end
          @pipeline_process_success = true
        rescue StandardError => e
          @pipeline_process_error_msg = e
          @pipeline_process_error = true
          @pipeline_process_success = false
        ensure
          @pipeline_process_running = false
        end
      end
      true
    in {type: :key, code: 'esc'}
      @pipeline_editing = false
      @pipeline_process_error = nil
      @pipeline_process_running = false
      @pipeline_process_success = false
      true
    in {type: :key, code: c}   
      if %w{up down}.include?(c.to_s.downcase)
        if c.to_s.downcase == 'down'
          @pipeline_focused = (@pipeline_focused + 1) % NUM_OPTIONS
        else
          @pipeline_focused = (@pipeline_focused - 1) % NUM_OPTIONS
        end
        true
      elsif c.is_a?(String) && c.match?(/[ -~]/) && c.length == 1 && c.match?(/[ -~]/)
        if (0...4).include?(@pipeline_focused)
          key = @pipeline_img_counts.keys[@pipeline_focused % @pipeline_img_counts.length]
          @pipeline_img_counts[key] += c 
        else 
          key = @pipeline_inputs.keys[@pipeline_focused % @pipeline_inputs.length]
          @pipeline_inputs[key] += c
        end
        true
      elsif c == 'backspace' 
        if (0...4).include?(@pipeline_focused)
          key = @pipeline_img_counts.keys[@pipeline_focused % @pipeline_img_counts.length]
          @pipeline_img_counts[key] = @pipeline_img_counts[key].empty? ? "" : @pipeline_img_counts[key][0...-1]
        else 
          key = @pipeline_inputs.keys[@pipeline_focused % @pipeline_inputs.length]
          @pipeline_inputs[key] = @pipeline_inputs[key].empty? ? "" : @pipeline_inputs[key][0...-1]
        end
        true
      else
        false
      end
    else
      false
    end
  end

  def render_pipeline_form(frame, tui, area)
    fields_area, status_area = tui.layout_split(
      area, direction: :vertical,
      constraints: [
        tui.constraint_min(0),
        tui.constraint_length(5)
      ]
    )
    # --- END ---

    # --- Render the Form's options -- 
    num_images = ['Your Diagnosis', 'Planned Surgery', 'Risks and Benefits', 'Recovery'].map.with_index do |topic, i|
      cursor = (i == @pipeline_focused && @pipeline_editing) ? "→ " : "  "
      value = @pipeline_img_counts[@pipeline_img_counts.keys[i]]
      style = (i == @pipeline_focused) ? tui.style(fg: :white, bg: :light_blue) : tui.style(fg: :dark_gray)
      ['', tui.text(:span, content: "#{cursor}  #{topic}: #{value}".strip, style: style)]
    end

    form_actions = ['Clinical note path', 'Avatar clip path'].map.with_index do |label, i|
      cursor = ((i + num_images.length) == @pipeline_focused && @pipeline_editing) ? "→ " : "  "
      value = @pipeline_inputs[@pipeline_inputs.keys[i]]
      style = ((i + num_images.length) == @pipeline_focused) ? tui.style(fg: :white, bg: :light_blue) : tui.style(fg: :dark_gray)
      ['', tui.text(:span, content: "#{cursor}  #{label}: #{value}".strip, style: style)]
    end 

    frame.render_widget(
      tui.paragraph(
        text: [
          tui.text(:span, 
            content: 'Run pipeline', style: tui.style(fg: :green, modifiers: [:bold])
          ), '', 
          "A pane to run the pipeline initially thought of by Kevin.  Press 'enter' to run it. " + 
          "", '', 'Number of Images', num_images, '', 'Actions:', form_actions
        ].flatten, 
        alignment: :left, wrap: true,
        block: tui.block(borders: :all, padding: 1, title: ' Pipeline ')
      ), 
      fields_area
    )
    # --- END ---

    # --- Render the status area ---
    if @pipeline_process_running
      @pipeline_frame_count += 1
      content = "Running process now"
      content += '.' * ((@pipeline_frame_count % NUM_DOTS) + 1)
      style = tui.style(fg: :yellow)
    elsif @pipeline_process_error
      content = @pipeline_process_error_msg
      style = tui.style(fg: :red)
    elsif @pipeline_process_success
      content = 'Process successful!'
      style = tui.style(fg: :green)
    else
      content, style = '', nil
    end

    frame.render_widget(
      tui.paragraph(
        text: tui.text(:span, content: content, style: style),
        alignment: :left, wrap: true, 
        block: tui.block(title: ' Status ', borders: :all, padding: 1)
      ),
    status_area)
  end

  def open_pipeline_form
    @pipeline_editing = true 
  end

  private 
  NUM_OPTIONS = 6
  NUM_DOTS = 3
end