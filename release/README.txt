ECHO - Voice to Text for macOS
================================


INSTALLING
----------

1. Double-click "Install Echo.command"
   (If macOS says it cannot be opened because it is from an unidentified
   developer: right-click the file -> Open -> Open in the warning dialog.
   This only needs to happen once.)

2. Terminal opens briefly and copies Echo into /Applications.

3. Echo launches automatically. Look for the microphone icon in your
   menubar (top-right of the screen).


FIRST RUN
---------

Echo will walk you through:

  - Microphone access (required to record your voice)
  - Accessibility access (required for the hotkey and to insert text)
  - OpenAI API key (Echo uses Whisper for transcription)

Get an OpenAI API key at:
  https://platform.openai.com/api-keys

You only pay for what you use - around $0.003 per minute of speech.


USING ECHO
----------

  - Double-tap the Fn / Globe key in any text field to start recording.
  - Tap Fn once to stop. The transcribed text is pasted at your cursor.
  - Echo learns your custom words over time. If you correct a word within
    8 seconds, Echo asks if you want to remember the correction.

Click the microphone icon in the menubar to open the full Echo window
where you can manage your dictionary, view history, change settings,
and more.


REQUIREMENTS
------------

  - macOS 13 (Ventura) or later
  - Apple Silicon or Intel
  - Internet (Whisper API)


SUPPORT
-------

This is a private build. Reach out to Mathias if it crashes or behaves
strangely.
