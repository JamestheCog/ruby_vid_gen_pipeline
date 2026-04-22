# A module to house the Controls pane (at the bottom of the terminal) for the TUI app's controls:

module Controls
  def controls(frame, tui, area)
    title = tui.paragraph(text: ['Q -> quit      Arrow keys -> navigate      Enter -> select / execute      Esc -> break out of form'], alignment: :left,
                          wrap: true,
                          block: tui.block(borders: :all, title: ' Controls ', padding: 1))
    frame.render_widget(title, area)
  end
end