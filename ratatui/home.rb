# A file to contain the component renderer for the "home" page of the pipeline:

require 'ratatui_ruby'

module HomeComponents 
  def render_home(frame, tui, area)
    title = tui.paragraph(text: ['', '', '', tui.text(:span, content: 'Video Generation Pipeline (version 1.0)', style: tui.style(fg: :yellow)), '', '', 
                                  'The clinical document note to video generation pipeline originally thought up by Kevin (i.e., a former research officer) ' + 
                                  'and implemented by him also - now on a native TUI application instead of a Colab notebook.', '',
                                  'Do note the controls at the bottom of the terminal - plus the user manual that comes attached with this application for ' + 
                                  'more information!  Also note the Gemfile and remember to `bundle install` before running `main.rb`!', '', '', '', 
                                  '-- Kevin ([former] 3SI lab member)'], alignment: :left,
                          wrap: true,
                          block: tui.block(borders: :all, title: ' Welcome! ', padding: 1))
    frame.render_widget(title, area)
  end
end