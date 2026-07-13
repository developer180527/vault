package com.example.vault

import com.ryanheise.audioservice.AudioServiceActivity

// Extends AudioServiceActivity so just_audio_background can run the media
// foreground service and show lock-screen controls.
class MainActivity : AudioServiceActivity()
