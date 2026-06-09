# 🎥 Video Generation Pipeline

This is a repository created to house the source code for the lab's generative AI video generation project - the one that given a clinical note from a patient,
aims to transform it into an eighth-grade reading level (on the Flesch-Kincaid reading scale) for patients to understand.  The generated video will cover 
the following topics in the following order:

1. The patient's diagnosis
2. The patient's planned surgery
3. Risks and benefits that come with the patient's planned surgery
4. The patient's follow-up and recovery thereafter

More information on this pipeline (including how to run it) will be included in the below sub-sections!


## 💻 Technologies and Gems Used

This pipeline relies upon several techniques and gems to do what it does, so do ensure that you have a rough understanding of the below
before operating the pipeline - namely

1. Retrieval Augmented Generation (i.e., RAG)
2. Prompt engineering
3. Video editing with `ffmpeg`
4. Filesystem manipulation (e.g., Ruby's `File`, `Dir`, and `FileUtils` module).

Do open the `Gemfile` to see what other gems are involved in the current workflow (rest assured - it's nothing *too* exhaustive)!


## ▶️ Running the Pipeline

### 📲 File Dependencies

Before you create your first video, ensure that you have the following items in the project's `resources` folder:

1. **`images`**: a collection of images to be used to generate the video's visuals.
2. **`med_sources`**: a collection of text files (i.e., pulled straight from the internet) containing content that have to do with 
[CRS-HIPEC](https://share.upmc.com/2020/12/crs-hipec/) surgeries to be embedded in the RAG vector database store.
3. **`api_tokens.txt`**: a text file containing multiple Gemini tokens (i.e., one per line) - for bypassing error 429s.
4. **`image_prompts.csv`**: a `.csv` file created by Kevin to describe each image in `images`.  These descriptions will also be embedded in the RAG
vector database.

### 🐀 Running the Ratatui Application

This project also leans on a RatatuiRuby (i.e., the Ruby port of the Rust-based TUI library [i.e., crate] Ratatui) interface for a UI.  Granted, you 
can also choose to write your own `.rb` files, `require_relative` the necessary helper methods and constants, and go from there - but run the following 
command to start the TUI application up:

```
bundle install              # Installs the necessary gems for this project.
bundle exec ruby main.rb    # Runs the application.
```

Just ensure that you have `bundler` installed on your machine first!  If you don't, then install it with `gem install bundler` (or else the above command will not work)!

### 📃 Running Order

The application also expects the operator to perform actions in a certain order - namely:

1. **Initializing the system database**: the application will initialize a new SQL database to store runtime variables that will be accessed during video creation.  Edit these first; you will not be able to continue unless these variables have been set.
2. **Initializing the RAG database**: this step initializes the vector database that the RAG system relies on.  This stage of the process also calls Gemini's embedding models via
their REST API for generating vector embeddings (for texts).
3. **Generating the video**: this is the part that will take the longest - generating the video itself.  Rest assured - all you gotta do is to just sit back and wait for 
Ruby (and Gemini) to be done doing its thing!

Otherwise, use the up / down arrow keys,  the "Enter" key, and the "Esc" key to interact with the TUI application!