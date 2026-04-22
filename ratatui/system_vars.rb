require 'ratatui_ruby'
require_relative '../processes/setup'

module SystemComponents
  def initialize_system_components
    sys_vars, err = Setup::fetch_sys_vars; raise err unless err.nil?

    @system_components = sys_vars
    @system_focused = 0
    @system_editing = false
    @system_explanation = nil

    # Pop-up specific components
    @system_show_popup = false 
  end

  def handle_system_form_event(event)
    return false unless @system_editing

    case event 
    in {type: :key, code: 'enter'}
      return if @system_show_popup

      @system_components.each_value{|v| return if v.strip.empty?}
      err = Setup.save_state_vals(@system_components); raise err unless err.nil?
      @system_show_popup = !@system_show_popup
    in {type: :key, code: c} if %w{down tab}.include?(c.to_s.downcase)
      @system_focused = (@system_focused + 1) % (@system_components.length - 1)
      true 
    in {type: :key, code: c} if c.to_s.downcase == 'up'
      @system_focused = (@system_focused - 1) % (@system_components.length - 1)
      true
    in {type: :key, code: 'esc'}
      if @system_show_popup
        @system_show_popup = !@system_show_popup if @system_show_popup
        return true
      end 
      @system_editing = false 
      true 
    in { type: :key, code: c } if c.is_a?(String) && c.length == 1 && c.match?(/[ -~]/)
      field = @system_components.keys[@system_focused]
      @system_components[field] += c
      true
    in { type: :key, code: "backspace" }
      field = @system_components.keys[@system_focused]
      @system_components[field] = @system_components[field].empty? ? "" : @system_components[field][0...-1]
      true
    else 
      false
    end
  end

  def render_system_form(frame, tui, area)
    fields_area, exp_area = tui.layout_split(
      area, direction: :vertical,
      constraints: [
        tui.constraint_min(0),
        tui.constraint_length(5)
      ]
    )

    # --- Render the Form ---
    form_fields = @system_components.map{|k, v| [k, v]}
    form_lines = form_fields.map.with_index do |(label, value), i|
      default_font = value.strip.empty? ? tui.style(fg: :red, modifiers: [:bold]) : tui.style(fg: :dark_gray)
      cursor = (i == @system_focused && @system_editing) ? "→ " : "  "
      style = (i == @system_focused) ? tui.style(fg: :white, bg: :light_blue) : default_font
      ['', tui.text(:span, content: "#{cursor}  #{label}: #{value}".strip, style: style)]
    end 
    
    frame.render_widget(tui.paragraph(
        text: [
          tui.text(:span, 
            content: 'System Variables', style: tui.style(fg: :green, modifiers: [:bold])
          ), '', 
          "Use the arrow keys to navigate to and edit the variables' values; press 'Enter' to save them.", 
          form_lines
        ].flatten, 
        alignment: :left, wrap: true,
        block: tui.block(borders: :all, padding: 1, title: ' Edit Patient Form ')
      ), 
      fields_area
    )
    # --- END ---

    # --- Render the help area ---
    explanation = Setup::EXPLANATIONS[@system_components.keys[@system_focused].intern]
    frame.render_widget(
      tui.paragraph(
        text: tui.text(:span, content: explanation, style: tui.style(fg: :gray)), 
        alignment: :left,
        block: tui.block(title: ' Variable Explanation ', borders: :all, padding: 1)),
      exp_area
    )
    # --- END ---

    # --- Render the popup if necessary ---
    if @system_show_popup
      popup = tui.center(
        child: tui.paragraph(
          text: "(press 'Esc' to close)!",
          alignment: :center,
          block: tui.block(
            title: " Successfully saved data! ",
            borders: [:all],
            padding: 1
          )
        ),
        width_percent: 50,
        height_percent: 60
      )
      frame.render_widget(tui.clear, frame.area)
      frame.render_widget(popup, frame.area)
    end 
    # --- END ---
  end

  def open_patient_form
    @system_editing = true 
    @system_focused = 0
  end
end